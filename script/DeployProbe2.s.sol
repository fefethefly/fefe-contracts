// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {CallerProbe} from "../src/periphery/CreateProbe.sol";

contract DeployProbe2 is Script {
    function run() external {
        vm.startBroadcast();
        CallerProbe p = new CallerProbe();
        vm.stopBroadcast();
        console2.log("CallerProbe:", address(p));
    }
}
