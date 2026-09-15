// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FefeSink} from "../src/v3/FefeSink.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {LaunchpadV3Test, AdapterV3} from "./LaunchpadV3.t.sol";

contract FefeSinkTest is Test {
    function test_setFefeOnce_andHarvestBurnsDirectBalance() public {
        AdapterV3 adapter = new AdapterV3();
        FefeSink sink = new FefeSink(address(this), adapter);
        MemeTokenV3 token = new MemeTokenV3();
        address[] memory none = new address[](0);
        token.initialize("FEFE", "FEFE", 100, 100, address(this), address(this), none, none);
        token.transfer(address(sink), 1_000 ether);

        vm.expectRevert(FefeSink.NOT_SET.selector);
        sink.harvest(address(token), address(0), 0);

        sink.setFefe(address(token));
        vm.expectRevert(FefeSink.ALREADY_SET.selector);
        sink.setFefe(address(token));

        uint256 supply = token.totalSupply();
        sink.harvest(address(token), address(0), 0);
        assertEq(token.balanceOf(address(sink)), 0);
        assertEq(token.totalSupply(), supply - 1_000 ether);
    }

    function test_harvestEthViaAdapterBuysAndBurns() public {
        AdapterV3 adapter = new AdapterV3();
        FefeSink sink = new FefeSink(address(this), adapter);
        MemeTokenV3 token = new MemeTokenV3();
        address[] memory none = new address[](0);
        token.initialize("FEFE", "FEFE", 100, 100, address(this), address(this), none, none);
        adapter.setMeme(address(token));
        token.transfer(address(adapter), 1_000_000 ether);
        sink.setFefe(address(token));

        vm.deal(address(sink), 1 ether);
        uint256 supply = token.totalSupply();
        sink.harvest(NATIVE, address(0), 0);
        assertEq(address(sink).balance, 0);
        assertLt(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(sink)), 0);
    }
}

contract FefeSinkLaunchpadTest is LaunchpadV3Test {
    function test_communityProtocolClaim_landsInTreasury() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.buyTaxBps = 80;
        p.sellTaxBps = 80;
        p.protocolFeeBps = 20;
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        p.split = FeeVaultV3.Split({creatorBps: 10000, basketBps: 0, jackpotBps: 0, burnBps: 0});
        p.jackpotEveryN = 0;
        p.basketTokens = new address[](0);
        p.basketWeights = new uint16[](0);
        (, BondingCurveV3 c,) = launch(p, pad.CREATION_FEE());
        vm.prank(alice);
        c.buy{value: 1 ether}(1 ether, 0, alice);
        uint256 before = treasury.balance;
        c.claimTreasury();
        assertEq(treasury.balance - before, 0.002 ether);
    }
}
