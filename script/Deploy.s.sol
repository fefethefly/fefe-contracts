// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {TestGradHandler, MockDex, TestStock} from "../src/periphery/TestnetHelpers.sol";

/**
 * 测试网部署:工厂 + 毕业处理器 + MockDex + 测试股票(TSLA 1:1)
 * 用法: forge script script/Deploy.s.sol --rpc-url $RH_TEST_RPC --private-key $KEY --broadcast
 */
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        TestGradHandler grad = new TestGradHandler();
        BondingFactory factory = new BondingFactory(msg.sender, grad);
        MockDex dex = new MockDex();
        TestStock stock = new TestStock("xTSLA", "xTSLA");
        vm.stopBroadcast();

        console2.log("GradHandler:", address(grad));
        console2.log("Factory:", address(factory));
        console2.log("MockDex:", address(dex));
        console2.log("TestStock(xTSLA):", address(stock));
        console2.log("Treasury:", msg.sender);
    }
}
