// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {Test,console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from '../../script/DeployDSC.s.sol';
import {DSCEngine} from '../../src/DSCEngine.sol';
import {DecentralizedStableCoin as DSC} from '../../src/DecentralizedStableCoin.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Handler} from './Handler.t.sol';

/**
 * @title 不变性测试
 * @author ffg
 * @notice 什么是我们的不变量？
 *         1、mint出的总DSC价值应始终小于总抵押物的价值
 *         2、Geteer view functions should never revert
 */
contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DSC dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;
    uint256 USER_ACCOUNT = 10 ether;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc,dsce,config) = deployer.run();
        handler = new Handler(dsce,dsc);
        (,,weth,wbtc,) = config.activeNetworkConfig();
        targetContract(address(handler));
    }

    function invariant_protocalMustHaveMoreValueThanSupply() public view {
        //1、获取协议中所有的抵押物价值
        //2、和所有的DSC进行比较
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));
        uint256 totalDepositedValue = dsce.getUsdValue(weth,totalWethDeposited)+dsce.getUsdValue(wbtc,totalWbtcDeposited);
        console.log("weth:",dsce.getUsdValue(weth,totalWethDeposited));
        console.log("wbtc:",dsce.getUsdValue(wbtc,totalWbtcDeposited));
        console.log("totalSupply:",totalSupply);
        console.log("totalDepositedValue:",totalDepositedValue);
        console.log("Times mint called:",handler.timeMintIsCalled());
        assert(totalDepositedValue>=totalSupply);
    }
}
