// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {InstantLaunchAndBuyGateway} from "../src/candidates/InstantLaunchAndBuyGateway.sol";

contract InstantLaunchAndBuyGatewayUnitTest is Test {
    function testWrongChainCannotDeployAtomicGateway() public {
        vm.chainId(46630);
        vm.expectRevert(InstantLaunchAndBuyGateway.WrongChain.selector);
        new InstantLaunchAndBuyGateway();
    }

    function testMissingProtocolCannotDeployAtomicGateway() public {
        vm.chainId(4663);
        vm.expectRevert(
            abi.encodeWithSelector(
                InstantLaunchAndBuyGateway.DeploymentMismatch.selector,
                address(0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0)
            )
        );
        new InstantLaunchAndBuyGateway();
    }

    function uninitializedCode() internal returns (InstantLaunchAndBuyGateway gateway) {
        address target = makeAddr("callback-validation-only");
        vm.etch(target, vm.getDeployedCode("InstantLaunchAndBuyGateway.sol:InstantLaunchAndBuyGateway"));
        return InstantLaunchAndBuyGateway(target);
    }

    function testUnsolicitedCallbackRejectedEvenFromManagerWithoutPendingBuy() public {
        InstantLaunchAndBuyGateway gateway = uninitializedCode();
        vm.expectRevert(InstantLaunchAndBuyGateway.InvalidCallback.selector);
        gateway.unlockCallback("");
        address manager = gateway.POOL_MANAGER();
        vm.expectRevert(InstantLaunchAndBuyGateway.InvalidCallback.selector);
        vm.prank(manager);
        gateway.unlockCallback(abi.encode(address(this), address(1), uint128(1), uint256(1)));
    }

    function testInvalidAmountMinimumAndExpiryFailBeforeProtocolReads() public {
        InstantLaunchAndBuyGateway gateway = uninitializedCode();
        vm.deal(address(this), uint256(uint128(type(int128).max)) + 1);
        vm.expectRevert(InstantLaunchAndBuyGateway.InvalidBuy.selector);
        gateway.createAndBuy("Ocean Club", "OCEAN", bytes32(0), 1, block.timestamp);
        vm.expectRevert(InstantLaunchAndBuyGateway.InvalidBuy.selector);
        gateway.createAndBuy{value: 1}("Ocean Club", "OCEAN", bytes32(0), 0, block.timestamp);
        vm.expectRevert(InstantLaunchAndBuyGateway.InvalidBuy.selector);
        gateway.createAndBuy{value: uint256(uint128(type(int128).max)) + 1}(
            "Ocean Club", "OCEAN", bytes32(0), 1, block.timestamp
        );
        vm.warp(100);
        vm.expectRevert(InstantLaunchAndBuyGateway.Expired.selector);
        gateway.createAndBuy{value: 1}("Ocean Club", "OCEAN", bytes32(0), 1, 99);
    }
}
