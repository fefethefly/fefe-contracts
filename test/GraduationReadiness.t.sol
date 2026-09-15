// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BarkToken} from "../src/BarkToken.sol";
import {LaunchpadV2} from "../src/v2/LaunchpadV2.sol";
import {BondingCurveV2} from "../src/v2/BondingCurveV2.sol";
import {IGraduationHandler} from "../src/interfaces.sol";

// Deliberately incomplete executors reproduce the integration gaps in the frozen candidate.
contract ReturnsAddressWithoutPool is IGraduationHandler {
    function graduate(address, uint256) external payable returns (address) {
        return address(0xbeef);
    }
}

contract RequiresLiquidityTokens is IGraduationHandler {
    error TOKENS_NOT_FUNDED();

    function graduate(address token, uint256 amount) external payable returns (address) {
        if (IERC20(token).balanceOf(address(this)) < amount) revert TOKENS_NOT_FUNDED();
        return address(this);
    }
}

contract GraduationReadinessTest is Test {
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address recipient = makeAddr("recipient");

    function launch(IGraduationHandler handler) internal returns (BarkToken token, BondingCurveV2 curve) {
        LaunchpadV2 pad = new LaunchpadV2(treasury, handler);
        LaunchpadV2.Launch memory plan = LaunchpadV2.Launch(
            "Lifecycle Test",
            "LIFE",
            BarkToken.Template.Creator,
            100,
            address(0),
            address(0),
            address(0),
            0,
            block.timestamp + 300
        );
        vm.deal(creator, 100 ether);
        vm.prank(creator);
        (address t, address c,) = pad.create{value: 1.001 ether}(plan);
        token = BarkToken(t);
        curve = BondingCurveV2(payable(c));
        // Isolate migration behavior at the threshold; this is not measured market income.
        vm.deal(address(curve), 25 ether + curve.creatorEarned() + curve.treasuryEarned());
    }

    function testCandidateCanMarkGraduatedWithoutAPoolAndSplitAssetsAcrossAddresses() public {
        ReturnsAddressWithoutPool handler = new ReturnsAddressWithoutPool();
        (BarkToken token, BondingCurveV2 curve) = launch(handler);
        uint256 tokens = token.balanceOf(address(curve));
        curve.graduate();
        assertTrue(curve.graduated());
        assertEq(curve.pool(), address(0xbeef));
        assertEq(curve.pool().code.length, 0);
        assertEq(address(handler).balance, 25 ether);
        assertEq(curve.pool().balance, 0);
        assertEq(token.balanceOf(curve.pool()), tokens);
        // This test documents an unsatisfied release gate, not an acceptable production result.
    }

    function testCandidateCallsExecutorBeforeFundingTokensAndRevertsAtomically() public {
        RequiresLiquidityTokens handler = new RequiresLiquidityTokens();
        (BarkToken token, BondingCurveV2 curve) = launch(handler);
        uint256 beforeNative = address(curve).balance;
        uint256 beforeTokens = token.balanceOf(address(curve));
        vm.expectRevert(RequiresLiquidityTokens.TOKENS_NOT_FUNDED.selector);
        curve.graduate();
        assertFalse(curve.graduated());
        assertEq(address(curve).balance, beforeNative);
        assertEq(token.balanceOf(address(curve)), beforeTokens);
        assertEq(address(handler).balance, 0);
    }

    function testCreatorTaxContinuesSendingTokensToClosedCurveAfterGraduation() public {
        (BarkToken token, BondingCurveV2 curve) = launch(new ReturnsAddressWithoutPool());
        curve.graduate();
        uint256 poolBefore = token.balanceOf(curve.pool());
        uint256 transferAmount = 100 ether;
        uint256 expectedCurveTax = transferAmount * 100 / 10_000 * 3_000 / 10_000;
        vm.prank(creator);
        token.transfer(recipient, transferAmount);
        assertEq(token.balanceOf(address(curve)), expectedCurveTax);
        assertEq(token.balanceOf(curve.pool()), poolBefore);
        assertEq(curve.backingReserve(), 0);
        vm.startPrank(creator);
        token.approve(address(curve), 1 ether);
        vm.expectRevert(BondingCurveV2.GRADUATED.selector);
        curve.sell(1 ether, 0);
        vm.stopPrank();
        // These received tokens do not automatically add pool liquidity or become holder yield.
    }
}
