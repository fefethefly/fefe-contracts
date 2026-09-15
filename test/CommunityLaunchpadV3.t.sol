// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommunityLaunchpadV3} from "../src/v3/CommunityLaunchpadV3.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {AdapterV3, GradV3} from "./LaunchpadV3.t.sol";

contract CommunityLaunchpadV3Test is Test {
    CommunityLaunchpadV3 pad;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");

    function setUp() public {
        pad = new CommunityLaunchpadV3(treasury, new GradV3(), new AdapterV3());
        vm.deal(creator, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function params() internal view returns (LaunchpadV3.Launch memory p) {
        p.name = "Community";
        p.symbol = "CLUB";
        p.virtualQuote = 1 ether;
        p.graduationQuote = 10 ether;
        p.buyTaxBps = 80;
        p.sellTaxBps = 80;
        p.protocolFeeBps = 20;
        p.split = FeeVaultV3.Split(10000, 0, 0, 0);
        p.deadline = block.timestamp + 60;
    }

    function test_communityTradePaysExactProtocolShare() public {
        LaunchpadV3.Launch memory p = params();
        vm.prank(creator);
        (address token, address curve, address vault) = pad.create{value: 0.0005 ether}(p);
        vm.prank(buyer);
        BondingCurveV3(payable(curve)).buy{value: 1 ether}(1 ether, 0, buyer);
        assertGt(MemeTokenV3(token).balanceOf(buyer), 0);
        assertEq(FeeVaultV3(payable(vault)).creatorEarned(), 0.008 ether);
        assertEq(BondingCurveV3(payable(curve)).treasuryEarned(), 0.002 ether);
        uint256 before = treasury.balance;
        BondingCurveV3(payable(curve)).claimTreasury();
        assertEq(treasury.balance - before, 0.002 ether);
    }

    function testFuzz_directCallsCannotOverrideFees(uint16 buyBps, uint16 sellBps, uint16 protocolBps) public {
        vm.assume(buyBps != 80 || sellBps != 80 || protocolBps != 20);
        LaunchpadV3.Launch memory p = params();
        p.buyTaxBps = buyBps;
        p.sellTaxBps = sellBps;
        p.protocolFeeBps = protocolBps;
        vm.prank(creator);
        vm.expectRevert(CommunityLaunchpadV3.COMMUNITY_FEE_MISMATCH.selector);
        pad.create{value: 0.0005 ether}(p);
        assertEq(pad.tokenCount(), 0);
    }

    function test_officialNameDoesNotGrantFeeExemption() public {
        LaunchpadV3.Launch memory p = params();
        p.name = "FEFE";
        p.symbol = "FEFE";
        p.buyTaxBps = 100;
        p.sellTaxBps = 100;
        p.protocolFeeBps = 0;
        vm.prank(creator);
        vm.expectRevert(CommunityLaunchpadV3.COMMUNITY_FEE_MISMATCH.selector);
        pad.create{value: 0.0005 ether}(p);
    }
}
