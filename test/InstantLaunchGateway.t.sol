// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {InstantLaunchGateway, InstantCommunityToken} from "../src/candidates/InstantLaunchGateway.sol";

contract InstantLaunchGatewayUnitTest is Test {
    function testWrongNetworkCannotDeployGateway() public {
        vm.chainId(46630);
        vm.expectRevert(InstantLaunchGateway.WrongChain.selector);
        new InstantLaunchGateway();
    }

    function testMissingDeploymentCannotBeAssumedFromChainId() public {
        vm.chainId(4663);
        vm.expectRevert(
            abi.encodeWithSelector(
                InstantLaunchGateway.DeploymentMismatch.selector, address(0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0)
            )
        );
        new InstantLaunchGateway();
    }

    function testFuzzStandardTransfersPreserveSupplyWithoutTax(uint256 amount) public {
        InstantCommunityToken token = new InstantCommunityToken("Ocean Club", "OCEAN");
        uint256 supply = 1_000_000_000 ether;
        amount = bound(amount, 0, supply);
        address receiver = makeAddr("token-receiver");
        assertEq(token.decimals(), 18);
        token.transfer(receiver, amount);
        assertEq(token.balanceOf(receiver), amount);
        assertEq(token.balanceOf(address(this)), supply - amount);
        assertEq(token.totalSupply(), supply);
        vm.prank(receiver);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), supply);
    }

    function testNoAdditionalMintOrOwnershipEntry() public {
        InstantCommunityToken token = new InstantCommunityToken("Ocean Club", "OCEAN");
        (bool mint,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        (bool owner,) = address(token).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(mint);
        assertFalse(owner);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
