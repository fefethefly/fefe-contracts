// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CommodityLaunchpadV3Test} from "./CommodityLaunchpadV3.t.sol";
import {ReviewCommodityLaunchpad} from "../script/ReviewCommodityLaunchpad.s.sol";

/// Review-drift scenarios against a locally bound stack. Expectations are passed to
/// ReviewCommodityLaunchpad.review() as explicit values: tests must not use vm.setEnv, because
/// forge runs suites in parallel and process-env writes race other threads (intermittent
/// codehash/policy mismatches under load). run() keeps the env interface for operators.
contract CommodityReviewDriftTest is CommodityLaunchpadV3Test {
    function expectations()
        internal
        returns (ReviewCommodityLaunchpad review, ReviewCommodityLaunchpad.Expectations memory e)
    {
        review = new ReviewCommodityLaunchpad();
        e = ReviewCommodityLaunchpad.Expectations({
            launchpad: address(pad),
            releaseMode: "cross-asset-research-v1",
            policyHash: pad.policyHash(),
            treasury: pad.treasury(),
            routeAdmin: address(this),
            sourceMaxAge: guard.maxAgeCeiling(),
            observationMaxAge: guard.maxObservationAge(),
            padCodehash: address(pad).codehash,
            dispatcherCodehash: address(dispatcher).codehash,
            commodityCodehash: address(adapter).codehash,
            guardCodehash: address(guard).codehash,
            v4Codehash: address(v4).codehash,
            handlerCodehash: address(handler).codehash,
            hookCodehash: address(hook).codehash,
            factoryCodehash: address(factory).codehash,
            feedCodehash: address(feed).codehash,
            bridgeCodehash: address(usdg).codehash,
            poolManagerCodehash: address(handler.poolManager()).codehash,
            assetCodehashes: codehashes([address(corn), address(coffee)]),
            poolCodehashes: codehashes([address(cornPool), address(coffeePool)])
        });
    }

    function codehashes(address[2] memory targets) private view returns (bytes32[] memory out) {
        out = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            out[i] = targets[i].codehash;
        }
    }

    function test_reviewAcceptsBoundStackAndRejectsCodePolicyOrAdminDrift() public {
        (ReviewCommodityLaunchpad review, ReviewCommodityLaunchpad.Expectations memory e) = expectations();
        review.review(e);
        assertNoCreation();
        e.observationMaxAge = 601;
        vm.expectRevert("observation age policy mismatch");
        review.review(e);
        e.observationMaxAge = 600;
        e.sourceMaxAge = 601;
        vm.expectRevert("source age policy mismatch");
        review.review(e);
        e.sourceMaxAge = 600;
        e.feedCodehash = bytes32(uint256(1));
        vm.expectRevert("LUMOB_FEED_CODEHASH mismatch");
        review.review(e);
        e.feedCodehash = address(feed).codehash;
        e.policyHash = bytes32(uint256(1));
        vm.expectRevert("policy hash mismatch");
        review.review(e);
        e.policyHash = pad.policyHash();
        v4.setRouteAdmin(address(123));
        vm.expectRevert("route admin mismatch");
        review.review(e);
        assertNoCreation();
    }

    function test_reviewMustExplicitlyMatchDirectReleaseMode() public {
        installDirect();
        (ReviewCommodityLaunchpad review, ReviewCommodityLaunchpad.Expectations memory e) = expectations();
        vm.expectRevert("release mode mismatch");
        review.review(e);
        e.releaseMode = "direct-quote-rewards-v1";
        review.review(e);
        assertEq(pad.tokenCount(), 0);
    }
}
