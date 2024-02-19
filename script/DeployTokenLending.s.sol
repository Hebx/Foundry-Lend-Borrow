// SPDX-LICENSE-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {TokenLending} from "../src/TokenLending.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployTokenLending is Script {
    // address[] public tokenAddresses;
    // address[] public priceFeedAddresses;

    function run() external returns (TokenLending, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();
        // priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        // tokenAddresses = [weth, wbtc];
        vm.startBroadcast(deployerKey);
        TokenLending tokenLending = new TokenLending();
        // tokenLending.transferOwnership(address(this));

        tokenLending.setAllowedToken(weth, wethUsdPriceFeed);
        tokenLending.setAllowedToken(wbtc, wbtcUsdPriceFeed);
        vm.stopBroadcast();
        return (tokenLending, config);
    }
}
