// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {InstantLaunchGateway} from "../src/candidates/InstantLaunchGateway.sol";
import {InstantLaunchAndBuyGateway} from "../src/candidates/InstantLaunchAndBuyGateway.sol";

/// @notice Deploys the Instant create and create-and-buy gateways on Robinhood mainnet 4663.
/// Copy both addresses and runtime code hashes into the web env before opening submit.
///
///   forge script script/DeployInstantLaunchGateways.s.sol --rpc-url $RH_MAINNET_RPC \
///     --private-key $DEPLOYER_KEY --evm-version cancun --broadcast -vv
contract DeployInstantLaunchGateways is Script {
    function run() external {
        require(block.chainid == 4663, "Instant gateways: Robinhood mainnet 4663 only");

        vm.startBroadcast();
        InstantLaunchGateway createGw = new InstantLaunchGateway();
        InstantLaunchAndBuyGateway buyGw = new InstantLaunchAndBuyGateway();
        vm.stopBroadcast();

        console2.log("InstantLaunchGateway", address(createGw));
        console2.logBytes32(address(createGw).codehash);
        console2.log("InstantLaunchAndBuyGateway", address(buyGw));
        console2.logBytes32(address(buyGw).codehash);
        console2.log("NEXT_PUBLIC_INSTANT_LAUNCH_GATEWAY", address(createGw));
        console2.log("NEXT_PUBLIC_INSTANT_LAUNCH_BUY_GATEWAY", address(buyGw));
    }
}
