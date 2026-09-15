// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {CreateProbe} from "../src/periphery/CreateProbe.sol";

contract DeployProbe is Script {
    function run() external {
        vm.startBroadcast();
        CreateProbe p = new CreateProbe();
        vm.stopBroadcast();
        console2.log("Probe:", address(p));
    }
}
