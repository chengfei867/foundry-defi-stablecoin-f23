// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSC稳定币
 * @author ffg
 * @notice 外部质押 与1美元锚定 使用算法稳定 与DAI代币相似
 *          任何情况下，抵押品的价值都不能低于或等于所有DSC的价值
 * 该合约是DSC稳定币代码的逻辑核心
 * 铸币
 * 赎回
 * 存入抵押品
 * 去除抵押品
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////////
    //      Errors         //
    /////////////////////////
    error DSCEngine_NeedMornThanZero();
    error DSCEngine_NeedAllowedToken();
    error DSCEngine_TokenListLenNotEqPriceFeedLen();
    error DSCEngine_TransferFailed();
    error DSCEngine_NotHealth(uint256 healthFactor);
    error DSCEngine_MintFailed(address user);
    error DSCEngine_CantBeLiquidated();
    error DSCEngine_LiquidatedFailed(string errorMsg);

    /////////////////////////
    //   State Variables   //
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    // 允许的抵押物代币及其价格源
    mapping(address token => address priceFeed) private s_priceFeeds;
    // 用户抵押贷币的列表
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    // 用户总已铸造DSC
    mapping(address user => uint256 dscMinted) private s_dscMinted;
    // 允许的稳定币列表
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    /////////////////////////
    //         Events      //
    /////////////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    /////////////////////////
    //      Modifiers      //
    /////////////////////////
    //需要抵押物金额大于0

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine_NeedMornThanZero();
        }
        _;
    }

    //需要是允许的抵押品
    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine_NeedAllowedToken();
        }
        _;
    }

    /////////////////////////
    //      Functions      //
    /////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeeds,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeeds.length) {
            revert DSCEngine_TokenListLenNotEqPriceFeedLen();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeeds[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // 抵押/铸币函数
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * 质押抵押品
     * @param tokenCollateralAddress 要质押的代币的地址
     * @param amountCollateral 要质押的代币的数量
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // 更新指定用户的抵押物列表
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        // 向该合约转账指定数量的指定代币
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    // 用稳定币兑换回抵押品函数
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * 赎回抵押品，要求用户在赎回抵押品后其健康因子大于1
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        //检查用户的健康因子是否小于1
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * 铸币函数
     * @param amountDscToMint 要铸造的DSC数量
     * @notice 抵押物价值要大于铸造的DSC
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed(msg.sender);
        }
    }

    // 销毁稳定币函数
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateral:要清算的抵押物
     * @param user:要清算的目标用户
     * @param debtToCover:要偿还多少的 debtToCover美元 的债务
     * @notice :可以部分清算一个用户，可以获得所有该用户的抵押物
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        //1.检查用户的健康状况是否可以清算
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_CantBeLiquidated();
        }
        //2.计算这些债务对应的collateral的数量
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        _burnDsc(user, msg.sender, debtToCover);

        // 还债后再次检查用户的健康因子
        uint256 endingUserHealth = _healthFactor(user);
        if (endingUserHealth <= startingUserHealthFactor) {
            revert DSCEngine_LiquidatedFailed("Health factor not improved!");
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 查看健康状况
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     *
     * @param amountDscToBurn 要销毁的dsc数量
     * @param onBehalfOf 被清算人
     * @param decFrom 清算人
     */
    function _burnDsc(
        address onBehalfOf,
        address decFrom,
        uint256 amountDscToBurn
    ) private moreThanZero(amountDscToBurn) nonReentrant {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        // 首先将代币转移到dsc代币地址，dsc继承了ERC20Brunable合约可以内部自己销毁
        bool success = i_dsc.transferFrom(
            decFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    // 赎回函数
    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private moreThanZero(amountCollateral) nonReentrant {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        //先转账，再进行健康因子判断
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function getAccountInformation(
        address user
    )
        public
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(
            user
        );
    }

    // 获取账户信息
    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        totalCollateralValueInUsd = getAccountCollateraValue(user);
    }

    /**
     * 健康因子函数
     * @param user 用户
     * @notice 返回用户距离清算还有多近，如果一个用户的健康因素低于1，则他们将可以被清算
     */
    function _healthFactor(address user) private view returns (uint256) {
        //1.total DSC minted
        //2.total collateral VALUE
        (
            uint256 totalDscMinted,
            uint256 totalCollateralValueInUsd
        ) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1.检查是否用户是否有足够的抵押物
        if (_healthFactor(user) < MIN_HEALTH_FACTOR) {
            //2.如果用户没有足够的抵押物则revert
            revert DSCEngine_NotHealth(_healthFactor(user));
        }
    }

    // 获取用户抵押的代币的总价值
    function getAccountCollateraValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        //循环遍历所有代币，获取用户存入的数量,然后计算每种代币的价格
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        //price of token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    //获取抵押物代币当前价格
    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int price, , , ) = priceFeed.latestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInfomation(
        address user
    ) external view returns (uint256, uint256) {
        return _getAccountInformation(user);
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) public view returns(address){
        return s_priceFeeds[token];
    }
}
