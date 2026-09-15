// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CommodityDirectRewardLaunchpadV3Test} from "./CommodityDirectRewardLaunchpadV3.t.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";

/// Actual local contract execution behind the UI's fee, capacity and income explanations.
/// No RPC, wallet key or broadcast. The v4 fixture is not evidence of real graduation liquidity.
contract DirectQuoteLifecycleTest is CommodityDirectRewardLaunchpadV3Test {
    function test_directUiQuoteFeesMatchExecutedBuyAndSharedBudget() public {
        LaunchpadV3.Launch memory p = installDirect();
        p.antiSnipeSeconds = 60;
        p.antiSnipeMaxWalletBps = 500;
        p.antiSnipeTaxBps = 3000;
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(p);
        vm.warp(block.timestamp + 30);
        uint256 input = 0.25 ether;
        (uint256 output, uint256 protocol, uint256 tax, uint256 penalty) = curve.quoteBuy(input, bob);
        assertEq(penalty, input * 1500 / 10000);
        uint256 quoteBefore = corn.balanceOf(bob);
        uint256 reserveBefore = curve.backingReserve();
        uint256 protocolBefore = curve.treasuryEarned();
        vm.startPrank(bob);
        corn.approve(address(curve), input);
        assertEq(curve.buy(input, output, bob), output);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), output);
        assertEq(quoteBefore - corn.balanceOf(bob), input);
        assertEq(curve.backingReserve() - reserveBefore, input - protocol - tax - penalty);
        assertEq(curve.treasuryEarned() - protocolBefore, protocol);
        assertEq(vault.creatorEarned(), tax * 3000 / 10000);
        assertEq(vault.basketPending(), tax - vault.creatorEarned() + penalty);
        assertEq(token.pending(bob, address(corn)), 0, "shared budget is not yet allocated");
        assertEq(corn.balanceOf(address(curve)), curve.backingReserve() + curve.treasuryEarned());
    }

    function test_directUiPositiveQuoteDoesNotBypassAntiSnipeCapacity() public {
        LaunchpadV3.Launch memory p = installDirect();
        p.antiSnipeSeconds = 60;
        p.antiSnipeMaxWalletBps = 100;
        p.antiSnipeTaxBps = 3000;
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(p);
        (uint256 output,,,) = curve.quoteBuy(1 ether, bob);
        assertGt(output, token.FIXED_SUPPLY() * 100 / 10000);
        uint256 before = corn.balanceOf(bob);
        vm.startPrank(bob);
        corn.approve(address(curve), 1 ether);
        vm.expectRevert(BondingCurveV3.SNIPE_CAP.selector);
        curve.buy(1 ether, 1, bob);
        vm.stopPrank();
        assertEq(corn.balanceOf(bob), before);
        assertEq(token.balanceOf(bob), 0);
        assertEq(vault.basketPending(), 0);
    }

    function test_directUiPositiveSellQuoteCannotSpendVirtualBacking() public {
        (MemeTokenV3 token, BondingCurveV3 curve,) = create(installDirect());
        (uint256 out, uint256 protocol, uint256 tax) = curve.quoteSell(token.FIXED_SUPPLY());
        assertGt(out, 0);
        assertGt(out + protocol + tax, curve.backingReserve());
        uint256 input = token.FIXED_SUPPLY();
        vm.prank(bob);
        vm.expectRevert(BondingCurveV3.INSUFFICIENT_BACKING.selector);
        curve.sell(input, 1);
    }

    function test_directUiAllocatedRightsSurviveBothCompleteExitOrders() public {
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(installDirect());
        vm.startPrank(bob);
        corn.approve(address(curve), 1 ether);
        curve.buy(1 ether, 1, bob);
        vm.stopPrank();
        uint256[] memory mins = new uint256[](1);
        vault.buyBasket(mins);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            address first = i == 0 ? bob : alice;
            address second = i == 0 ? alice : bob;
            uint256 totalBefore = corn.balanceOf(alice) + corn.balanceOf(bob) + corn.balanceOf(address(curve))
                + corn.balanceOf(address(vault)) + corn.balanceOf(address(token));
            _exitAndClaim(token, curve, first);
            _exitAndClaim(token, curve, second);
            assertEq(token.balanceOf(alice) + token.balanceOf(bob), 0);
            assertEq(curve.tokenReserve(), token.FIXED_SUPPLY());
            assertLe(curve.backingReserve(), 1);
            assertEq(
                corn.balanceOf(alice) + corn.balanceOf(bob) + corn.balanceOf(address(curve))
                    + corn.balanceOf(address(vault)) + corn.balanceOf(address(token)),
                totalBefore
            );
            assertEq(
                corn.balanceOf(address(token)),
                token.totalDistributed(address(corn)) - token.totalClaimed(address(corn))
            );
            if (i == 0) assertTrue(vm.revertToState(snapshot));
        }
    }

    function _exitAndClaim(MemeTokenV3 token, BondingCurveV3 curve, address who) private {
        uint256 owed = token.pending(who, address(corn));
        assertGt(owed, 0);
        uint256 tokens = token.balanceOf(who);
        (uint256 expected,,) = curve.quoteSell(tokens);
        vm.startPrank(who);
        token.approve(address(curve), tokens);
        uint256 beforeSell = corn.balanceOf(who);
        assertEq(curve.sell(tokens, expected), expected);
        assertEq(corn.balanceOf(who) - beforeSell, expected);
        assertEq(token.pending(who, address(corn)), owed);
        uint256 beforeClaim = corn.balanceOf(who);
        token.claimRewards();
        assertEq(corn.balanceOf(who) - beforeClaim, owed);
        vm.expectRevert(MemeTokenV3.NOTHING_TO_CLAIM.selector);
        token.claimRewards();
        vm.stopPrank();
    }
}
