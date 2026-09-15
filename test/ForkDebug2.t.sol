// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {BarkToken} from "../src/BarkToken.sol";
import {LegacyDebugForkFixture} from "./ForkDebug.t.sol";

contract ForkDebug2Test is LegacyDebugForkFixture {
    function test_ForkCreateAsEOA() public {
        // Requires BARK_RUN_LEGACY_DEBUG_FORK=true and an explicit BARK_LEGACY_DEBUG_FORK_BLOCK.
        address eoa = 0x1B771C48Cac6A5B521D55aDfFA0103A02fb5F1bd;
        vm.deal(eoa, 1 ether);
        vm.prank(eoa);
        BondingFactory(payable(0xbe85DF5e174F02450FCd64769f5fe3eEE5c47e07)).createToken{value: 0.001 ether}(
            "HoodHound",
            "HOOD",
            BarkToken.Template.StockVault,
            100,
            0x5bD1c396Bb9ffb3168497334E6c68DcDAa823027,
            eoa,
            0xEb98a6F6A61fe057D3bd9051C307f38EcF3Eb6a0
        );
    }
}
