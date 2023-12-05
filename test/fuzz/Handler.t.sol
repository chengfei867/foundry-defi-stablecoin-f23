// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin as DSC} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine private dsce;
    DSC private dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timeMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dsce, DSC _dsc) {
        dsce = _dsce;
        dsc = _dsc;
        weth = ERC20Mock(dsce.getCollateralTokens()[0]);
        wbtc = ERC20Mock(dsce.getCollateralTokens()[1]);
        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    /**
     * 假设我们要测试赎回抵押物功能，那么我们必须在此前存入一定数量的抵押物
     * @param collateralSeed 何种抵押物
     * @param amountCollateral 抵押物数量
     */
    function depositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amount,uint256 addressSeed) public {
        if(usersWithCollateralDeposited.length == 0){
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed%usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(sender);
        int256 maxDscToMint = ((int256 (collateralValueInUsd)/2) - int256(totalDscMinted));
        if(maxDscToMint <= 0){
            return;
        }
        amount = bound(amount,0,uint256(maxDscToMint));
        if(amount == 0){
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timeMintIsCalled++;
    }

    /**
     * 赎回抵押物
     * @param collateralSeed 随机生成的抵押物类型
     * @param amountCollateral 随机生成的抵押物数量
     */
    function redeemCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(
            address(collateral),
            msg.sender
        );
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (maxCollateralToRedeem == 0) {
            return;
        }
        // vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        // vm.stopPrank();
    }

    // function updateCollateralprice(uint96 newPrice) public{
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock collateral) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
