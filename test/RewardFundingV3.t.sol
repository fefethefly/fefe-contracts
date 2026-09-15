// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";

contract FundingReward is ERC20 {
    bool public failTransfers;
    MemeTokenV3 public callback;
    bool public callbackBlocked;
    constructor() ERC20("Reward", "R") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function setFail(bool fail) external { failTransfers = fail; }
    function setCallback(MemeTokenV3 target) external { callback = target; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!failTransfers, "transfer failed");
        if (address(callback) != address(0)) {
            try callback.claimRewards() { callbackBlocked = false; }
            catch { callbackBlocked = true; }
        }
        return super.transfer(to, amount);
    }
}

contract RewardFundingV3Test is Test {
    MemeTokenV3 token;
    FundingReward reward;
    FundingReward second;
    address vault = address(0x100);
    address curve = address(0x200);
    address alice = address(0x300);
    address bob = address(0x400);

    function setUp() public {
        token = new MemeTokenV3();
        reward = new FundingReward();
        second = new FundingReward();
        address[] memory rewards = new address[](2);
        rewards[0] = address(reward); rewards[1] = address(second);
        token.initialize("LUMOB", "LUM", 0, 0, curve, vault, rewards, new address[](0));
    }
    function holders() internal {
        vm.startPrank(curve);
        token.transfer(alice, 100 ether);
        token.transfer(bob, 100 ether);
        vm.stopPrank();
    }
    function notify(uint256 amount) internal {
        vm.prank(vault);
        token.notifyReward(address(reward), amount);
    }
    function test_unfundedAndDuplicateNotificationCannotCreateLiabilities() public {
        holders();
        vm.expectRevert(MemeTokenV3.REWARD_NOT_FUNDED.selector); notify(1 ether);
        assertEq(token.totalDistributed(address(reward)), 0);
        reward.mint(address(token), 10 ether);
        notify(10 ether);
        vm.expectRevert(MemeTokenV3.REWARD_NOT_FUNDED.selector); notify(1);
        assertEq(token.pending(alice, address(reward)), 5 ether);
        assertEq(token.totalDistributed(address(reward)), 10 ether);
    }
    function test_donationCannotBeAllocatedByAnArbitraryCaller() public {
        holders(); reward.mint(address(token), 10 ether);
        vm.prank(alice);
        vm.expectRevert(MemeTokenV3.NOT_AUTHORIZED.selector);
        token.notifyReward(address(reward), 10 ether);
        assertEq(token.pending(alice, address(reward)), 0);
        notify(10 ether);
    }
    function test_partialClaimsReserveOtherHoldersAndAllowNewFunding() public {
        holders(); reward.mint(address(token), 10 ether); notify(10 ether);
        vm.prank(alice); token.claimRewards();
        assertEq(token.totalClaimed(address(reward)), 5 ether);
        vm.expectRevert(MemeTokenV3.REWARD_NOT_FUNDED.selector); notify(1);
        reward.mint(address(token), 2 ether); notify(2 ether);
        assertEq(token.pending(alice, address(reward)), 1 ether);
        assertEq(token.pending(bob, address(reward)), 6 ether);
        vm.prank(bob); token.claimRewards();
        vm.prank(alice); token.claimRewards();
        assertEq(token.totalClaimed(address(reward)), 12 ether);
        assertEq(reward.balanceOf(address(token)), 0);
    }
    function test_unallocatedRewardsAreReservedAndOnlyDistributedOnce() public {
        reward.mint(address(token), 10 ether); notify(10 ether);
        assertEq(token.unallocated(address(reward)), 10 ether);
        vm.expectRevert(MemeTokenV3.REWARD_NOT_FUNDED.selector); notify(1);
        holders(); notify(0); notify(0);
        assertEq(token.unallocated(address(reward)), 0);
        assertEq(token.pending(alice, address(reward)), 5 ether);
        assertEq(token.totalDistributed(address(reward)), 10 ether);
    }
    function test_failedSecondAssetTransferRollsBackAllClaimsAndAccounting() public {
        holders(); reward.mint(address(token), 10 ether); notify(10 ether);
        second.mint(address(token), 8 ether);
        vm.prank(vault); token.notifyReward(address(second), 8 ether);
        second.setFail(true);
        vm.prank(alice); vm.expectRevert("transfer failed"); token.claimRewards();
        assertEq(reward.balanceOf(alice), 0);
        assertEq(token.totalClaimed(address(reward)), 0);
        assertEq(token.pending(alice, address(reward)), 5 ether);
        second.setFail(false);
        vm.prank(alice); assertEq(token.claimRewards(), 2);
        assertEq(second.balanceOf(alice), 4 ether);
    }
    function test_rewardTransferCannotReenterClaims() public {
        holders(); reward.mint(address(token), 10 ether); notify(10 ether);
        // The reward contract is itself a holder with a genuine accrued entitlement.
        vm.prank(curve); token.transfer(address(reward), 100 ether);
        reward.mint(address(token), 3 ether); notify(3 ether);
        reward.setCallback(token);
        vm.prank(alice); token.claimRewards();
        assertTrue(reward.callbackBlocked());
        assertEq(token.pending(address(reward), address(reward)), 1 ether);
    }
    function testFuzz_claimTransferAndNewFundingRemainSolvent(uint96 initial, uint96 added) public {
        holders();
        uint256 a = bound(initial, 1 ether, 1_000_000 ether);
        uint256 b = bound(added, 1 ether, 1_000_000 ether);
        reward.mint(address(token), a); notify(a);
        vm.startPrank(alice); token.claimRewards(); token.transfer(bob, 50 ether); vm.stopPrank();
        reward.mint(address(token), b); notify(b);
        vm.prank(bob); token.claimRewards();
        vm.prank(alice); token.claimRewards();
        assertEq(token.totalDistributed(address(reward)), a + b);
        assertEq(reward.balanceOf(address(token)), a + b - token.totalClaimed(address(reward)));
        assertLe(token.totalClaimed(address(reward)), a + b);
        vm.expectRevert(MemeTokenV3.REWARD_NOT_FUNDED.selector); notify(1);
    }
}
