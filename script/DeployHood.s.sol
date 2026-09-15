// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {TestStock} from "../src/periphery/TestnetHelpers.sol";

/// 测试网可铸造 HOOD:MockDex.mint 走开放铸造,官方脸 executeBuyback 才能进窝
contract DeployHood is Script {
    function run() external {
        vm.startBroadcast();
        TestStock stock = new TestStock("HOOD", "HOOD");
        vm.stopBroadcast();
        console2.log("TestStock(HOOD):", address(stock));
    }
}
