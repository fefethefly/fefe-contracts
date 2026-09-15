// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CommodityLaunchpadV3Test} from "./CommodityLaunchpadV3.t.sol";
import {CommodityDirectRewardLaunchpadV3} from "../src/v3/CommodityDirectRewardLaunchpadV3.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";

/// Inherits the full-mode tests too; installDirect() is only used by the additional scope tests.
/// Env-driven review scenarios live in CommodityReviewDriftTest, not here: suites run in
/// parallel and vm.setEnv writes are process-wide, so this suite must not mutate LUMOB_* keys.
contract CommodityDirectRewardLaunchpadV3Test is CommodityLaunchpadV3Test {
    function test_directScopeRejectsCrossAssetBuybackJackpotAndEmptyRewards() public {
        LaunchpadV3.Launch memory original = installDirect();
        for (uint256 i; i < 4; ++i) {
            LaunchpadV3.Launch memory p = original;
            if (i == 0) p.basketTokens[0] = address(coffee);
            if (i == 1) p.split = FeeVaultV3.Split(3000, 6000, 0, 1000);
            if (i == 2) p.split = FeeVaultV3.Split(3000, 6000, 1000, 0);
            if (i == 3) p.split = FeeVaultV3.Split(10000, 0, 0, 0);
            vm.expectRevert(CommodityDirectRewardLaunchpadV3.UNSUPPORTED_DISTRIBUTION.selector);
            create(p);
            original.basketTokens[0] = address(corn);
        }
        assertNoCreation();
    }

    function test_directRewardsIgnoreAdverseConversionPoolAndTinyCallerFloor() public {
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(installDirect());
        vm.startPrank(bob);
        corn.approve(address(curve), 1 ether);
        curve.buy(1 ether, 1, bob);
        vm.stopPrank();
        cornPool.setMode(1);
        coffeePool.setMode(7);
        uint256 budget = vault.basketPending();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1;
        vm.prank(makeAddr("untrusted-keeper"));
        vault.buyBasket(mins);
        assertEq(corn.balanceOf(address(token)), budget);
        assertEq(token.totalDistributed(address(corn)), budget);
        assertEq(vault.basketPending(), 0);
        assertEq(vault.burnPending(), 0);
        assertEq(vault.memePending(), 0);
        vm.expectRevert(FeeVaultV3.NOTHING_PENDING.selector);
        vault.buybackAndBurn(1);
        vm.expectRevert(FeeVaultV3.NOTHING_PENDING.selector);
        vault.settleTax(1);
        vm.expectRevert(FeeVaultV3.ONLY_TOKEN.selector);
        vault.onTax(1 ether);
        uint256 expected = token.pending(alice, address(corn));
        uint256 before = corn.balanceOf(alice);
        feed.setPaused(true);
        vm.prank(alice);
        token.claimRewards();
        assertEq(corn.balanceOf(alice) - before, expected);
    }

    function testFuzz_zeroBuybackShareNeverAccumulatesRoundingBudget(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        (MemeTokenV3 token,, FeeVaultV3 vault) = create(installDirect());
        corn.mint(address(vault), amount);
        vault.onMarketFee(amount);
        assertEq(vault.burnPending(), 0);
        assertEq(vault.jackpotPot(), 0);
        assertEq(vault.creatorEarned() + vault.basketPending(), amount);
        assertGt(vault.basketPending(), 0);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1;
        vault.buyBasket(mins);
        assertEq(corn.balanceOf(address(token)) + vault.creatorEarned(), amount);
        vm.expectRevert(FeeVaultV3.NOTHING_PENDING.selector);
        vault.buybackAndBurn(1);
    }
}
