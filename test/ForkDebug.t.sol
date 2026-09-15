// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {BarkToken} from "../src/BarkToken.sol";

/// Opt-in diagnostic of historical deployments, never an unforked unit test or a broadcast.
abstract contract LegacyDebugForkFixture is Test {
    function setUp() public {
        if (!vm.envOr("BARK_RUN_LEGACY_DEBUG_FORK", false)) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envUint("BARK_LEGACY_DEBUG_FORK_BLOCK");
        assertGt(pinned, 0);
        vm.createSelectFork("https://rpc.testnet.chain.robinhood.com", pinned);
        assertEq(vm.getChainId(), 46630);
        assertGt(address(0xbe85DF5e174F02450FCd64769f5fe3eEE5c47e07).code.length, 0);
    }
}

/// 在测试网 fork 上直接调用已部署的工厂,让 foundry 解码确切 revert。
contract ForkDebugTest is LegacyDebugForkFixture {
    function test_ForkCreate() public {
        // Requires BARK_RUN_LEGACY_DEBUG_FORK=true and an explicit BARK_LEGACY_DEBUG_FORK_BLOCK.
        BondingFactory factory = BondingFactory(payable(0xbe85DF5e174F02450FCd64769f5fe3eEE5c47e07));
        vm.deal(address(this), 1 ether);
        factory.createToken{value: 0.001 ether}(
            "HoodHound",
            "HOOD",
            BarkToken.Template.StockVault,
            100,
            0x5bD1c396Bb9ffb3168497334E6c68DcDAa823027,
            0x1B771C48Cac6A5B521D55aDfFA0103A02fb5F1bd,
            0xEb98a6F6A61fe057D3bd9051C307f38EcF3Eb6a0
        );
    }
}
