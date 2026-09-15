// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {TestStock} from "../src/periphery/TestnetHelpers.sol";

contract DeployStock2 is Script {
    function run() external {
        vm.startBroadcast();
        TestStock stock = new TestStock("xTSLA", "xTSLA");
        vm.stopBroadcast();
        console2.log("TestStock2:", address(stock));
    }
}
