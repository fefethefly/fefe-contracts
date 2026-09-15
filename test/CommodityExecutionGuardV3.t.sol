// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CommodityAdapterFixture} from "./CommoditySwapAdapterV3.t.sol";
import {CommodityOracleGuardV3, ICommodityPriceFeedV3} from "../src/v3/uniswap/CommodityOracleGuardV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";

contract CommodityExecutionGuardV3Test is CommodityAdapterFixture {
    function test_pausedDisabledAndReadFailuresStopWithoutFunding() public {
        feed.setPaused(true);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        swap(1 ether, 1);
        feed.setPaused(false);
        feed.setFail(true);
        vm.expectRevert("feed unavailable");
        swap(1 ether, 1);
        feed.setFail(false);
        ICommodityPriceFeedV3.Config memory c = ICommodityPriceFeedV3.Config(false, false, 300, 1, 100 ether);
        ICommodityPriceFeedV3.Observation memory o = ICommodityPriceFeedV3.Observation(1 ether, 99990, 99995);
        feed.set(coffee.assetId(), c, o);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        swap(1 ether, 1);
        c.enabled = true;
        c.paused = true;
        feed.set(coffee.assetId(), c, o);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        swap(1 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(coffee.balanceOf(bob), 0);
    }

    function test_oldObservationDoesNotBecomeFreshWhenRepublished() public {
        ICommodityPriceFeedV3.Config memory c = ICommodityPriceFeedV3.Config(true, false, 300, 1, 100 ether);
        feed.set(coffee.assetId(), c, ICommodityPriceFeedV3.Observation(1 ether, 99700, 100000));
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        swap(1 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
    }

    function test_exactExpiryStopsTransactionPreviouslyValidated() public {
        guard.validate(address(corn));
        vm.warp(100290);
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        swap(1 ether, 1);
        refreshFeed();
        assertEq(swap(1 ether, 1), 1 ether);
    }

    function test_futureTimeBadBoundsAndZeroPriceFailClosed() public {
        for (uint256 i; i < 7; i++) {
            ICommodityPriceFeedV3.Config memory c = ICommodityPriceFeedV3.Config(true, false, 300, 1, 100 ether);
            ICommodityPriceFeedV3.Observation memory o = ICommodityPriceFeedV3.Observation(1 ether, 99990, 99995);
            if (i == 0) o.observedAt = 0;
            if (i == 1) {
                o.observedAt = 100001;
                o.updatedAt = 100001;
            }
            if (i == 2) o.updatedAt = 99989;
            if (i == 3) o.priceWad = 0;
            if (i == 4) c.minPriceWad = 101 ether;
            if (i == 5) c.maxPriceWad = 1;
            if (i == 6) c.maxAge = 0;
            feed.set(coffee.assetId(), c, o);
            vm.expectRevert(CommodityOracleGuardV3.INVALID_OBSERVATION.selector);
            swap(1 ether, 1);
            assertEq(corn.balanceOf(alice), 100 ether);
        }
    }

    function test_sourcePolicyExtensionFailsEvenWithFreshObservation() public {
        feed.set(
            coffee.assetId(),
            ICommodityPriceFeedV3.Config(true, false, 601, 1, 100 ether),
            ICommodityPriceFeedV3.Observation(1 ether, 99990, 99995)
        );
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_POLICY_CHANGED.selector);
        swap(1 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
    }

    function separatePolicy(uint32 sourceCeiling, uint32 observationAge) private returns (CommodityOracleGuardV3) {
        (address[] memory assets,) = config();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = corn.assetId();
        ids[1] = coffee.assetId();
        return new CommodityOracleGuardV3(block.chainid, feed, sourceCeiling, observationAge, assets, ids);
    }

    function test_longSourceSlaDoesNotExtendExecutionFreshness() public {
        CommodityOracleGuardV3 strict = separatePolicy(3600, 600);
        ICommodityPriceFeedV3.Config memory c = ICommodityPriceFeedV3.Config(true, false, 3600, 1, 100 ether);
        feed.set(coffee.assetId(), c, ICommodityPriceFeedV3.Observation(1 ether, 99401, 99995));
        strict.validate(address(coffee));
        // A recent publication timestamp cannot refresh an older observation.
        feed.set(coffee.assetId(), c, ICommodityPriceFeedV3.Observation(1 ether, 99400, 100000));
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        strict.validate(address(coffee));
        c.maxAge = 3601;
        feed.set(coffee.assetId(), c, ICommodityPriceFeedV3.Observation(1 ether, 99999, 100000));
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_POLICY_CHANGED.selector);
        strict.validate(address(coffee));
    }

    function testFuzz_stricterOfSourceAndExecutionExpiryAlwaysWins(uint32 sourceAge, uint32 observationAge) public {
        sourceAge = uint32(bound(sourceAge, 1, 3600));
        observationAge = uint32(bound(observationAge, 1, 3600));
        CommodityOracleGuardV3 strict = separatePolicy(3600, observationAge);
        feed.set(
            coffee.assetId(),
            ICommodityPriceFeedV3.Config(true, false, sourceAge, 1, 100 ether),
            ICommodityPriceFeedV3.Observation(1 ether, 100000, 100000)
        );
        uint32 effective = sourceAge < observationAge ? sourceAge : observationAge;
        vm.warp(100000 + effective - 1);
        strict.validate(address(coffee));
        vm.warp(100000 + effective);
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        strict.validate(address(coffee));
    }

    function test_zeroOrExcessiveExecutionAgeIsRejected() public {
        (address[] memory assets,) = config();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = corn.assetId();
        ids[1] = coffee.assetId();
        vm.expectRevert(CommodityOracleGuardV3.BAD_CONFIG.selector);
        new CommodityOracleGuardV3(block.chainid, feed, 3600, 0, assets, ids);
        vm.expectRevert(CommodityOracleGuardV3.BAD_CONFIG.selector);
        new CommodityOracleGuardV3(block.chainid, feed, 600, 601, assets, ids);
    }

    function test_guardedGetterAndTokenIdentityMustStillMatch() public {
        feed.setMismatch(true);
        vm.expectRevert(CommodityOracleGuardV3.INVALID_OBSERVATION.selector);
        swap(1 ether, 1);
        feed.setMismatch(false);
        coffee.setAssetId(bytes32(uint256(123)));
        vm.expectRevert(CommodityOracleGuardV3.IDENTITY_CHANGED.selector);
        swap(1 ether, 1);
        vm.expectRevert(CommodityOracleGuardV3.UNKNOWN_ASSET.selector);
        guard.validate(address(usdg));
    }

    function test_staleVaultBudgetRemainsClaimableAfterSourceRecovery() public {
        (MemeTokenV3 token, FeeVaultV3 vault) = vaultSetup();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 10 ether;
        vm.warp(100290);
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        vault.buyBasket(mins);
        assertEq(vault.basketPending(), 10 ether);
        assertEq(corn.balanceOf(address(vault)), 10 ether);
        assertEq(token.totalDistributed(address(coffee)), 0);
        refreshFeed();
        vault.buyBasket(mins);
        assertEq(token.pending(alice, address(coffee)), 5 ether);
        assertEq(vault.basketPending(), 0);
    }

    function test_sourceExpiryCannotFreezeAlreadyFundedHolderClaims() public {
        (MemeTokenV3 token, FeeVaultV3 vault) = vaultSetup();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 10 ether;
        vault.buyBasket(mins);
        uint256 pending = token.pending(alice, address(coffee));
        assertGt(pending, 0);
        vm.warp(100290);
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        guard.validate(address(coffee));
        uint256 before = coffee.balanceOf(alice);
        vm.prank(alice);
        token.claimRewards();
        assertEq(coffee.balanceOf(alice) - before, pending);
        assertEq(token.pending(alice, address(coffee)), 0);
        assertEq(token.totalClaimed(address(coffee)), pending);
    }

    function test_guardConstructorRejectsUnpinnedIdentityAndMissingSource() public {
        address[] memory assets = new address[](1);
        assets[0] = address(corn);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = coffee.assetId();
        vm.expectRevert(CommodityOracleGuardV3.BAD_CONFIG.selector);
        new CommodityOracleGuardV3(block.chainid, feed, 600, 600, assets, ids);
        ids[0] = corn.assetId();
        vm.expectRevert(CommodityOracleGuardV3.BAD_CONFIG.selector);
        new CommodityOracleGuardV3(block.chainid, ICommodityPriceFeedV3(address(123)), 600, 600, assets, ids);
        vm.expectRevert(CommodityOracleGuardV3.BAD_CONFIG.selector);
        new CommodityOracleGuardV3(block.chainid, feed, 0, 600, assets, ids);
    }
}
