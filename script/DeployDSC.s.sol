// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public priceFeeds;
    address[] public tokenAddresses;
    HelperConfig public config;

    function run() external returns (DecentralizedStableCoin, DSCEngine,HelperConfig) {
        config = new HelperConfig();
        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc,
            uint256 deployerKey
        ) = config.activeNetworkConfig();

        priceFeeds = [wethUsdPriceFeed,wbtcUsdPriceFeed];
        tokenAddresses = [weth,wbtc];

        vm.startBroadcast(deployerKey);
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine dscEngine = new DSCEngine(
            tokenAddresses,
            priceFeeds,
            address(dsc)
        );
        dsc.transferOwnership(address(dscEngine));
        vm.stopBroadcast();
        return (dsc, dscEngine,config);
    }
}
