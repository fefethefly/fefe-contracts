// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FefeAnchor} from "../src/fefe/FefeAnchor.sol";

/// @dev Same pairing rule as `web/lib/brain/merkle.ts`: sorted SHA-256 pairs.
library Sha256Merkle {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? sha256(abi.encodePacked(a, b)) : sha256(abi.encodePacked(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length != 0, "no leaves");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 n = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](n);
            for (uint256 i = 0; i < level.length; i += 2) {
                next[i / 2] = i + 1 < level.length ? hashPair(level[i], level[i + 1]) : level[i];
            }
            level = next;
        }
        return level[0];
    }

    function verify(bytes32 leaf, bytes32[] memory proof, bytes32 expected) internal pure returns (bool) {
        bytes32 acc = leaf;
        for (uint256 i = 0; i < proof.length; i++) acc = hashPair(acc, proof[i]);
        return acc == expected;
    }
}

contract FefeAnchorTest is Test {
    FefeAnchor anchor;
    address signer = makeAddr("signer");
    address stranger = makeAddr("stranger");

    function setUp() public {
        anchor = new FefeAnchor(signer);
    }

    function testConstructorRejectsZeroSigner() public {
        vm.expectRevert(FefeAnchor.ZeroSigner.selector);
        new FefeAnchor(address(0));
    }

    function testAnchorHappyPathAndReplay() public {
        bytes32 root = keccak256("root-not-empty");
        vm.prank(signer);
        vm.expectEmit(true, false, false, true);
        emit FefeAnchor.Anchored(8305, root, "/api/world/lineage/anchor/8305", 4);
        anchor.anchor(8305, root, "/api/world/lineage/anchor/8305", 4);
        assertEq(anchor.rootOf(8305), root);
        assertEq(anchor.leavesOf(8305), 4);
        assertEq(anchor.signer(), signer);

        vm.prank(signer);
        vm.expectRevert(FefeAnchor.EpochTaken.selector);
        anchor.anchor(8305, keccak256("other"), "x", 1);
    }

    function testOnlySigner() public {
        vm.prank(stranger);
        vm.expectRevert(FefeAnchor.NotSigner.selector);
        anchor.anchor(1, bytes32(uint256(1)), "u", 1);
    }

    function testEmptyRootAndZeroLeaves() public {
        vm.startPrank(signer);
        vm.expectRevert(FefeAnchor.EmptyRoot.selector);
        anchor.anchor(1, bytes32(0), "u", 1);
        vm.expectRevert(FefeAnchor.ZeroLeaves.selector);
        anchor.anchor(1, bytes32(uint256(1)), "u", 0);
        vm.stopPrank();
    }

    function testNoPayablePath() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(anchor).call{value: 0.1 ether}("");
        assertFalse(ok, "contract must not accept ETH");
        assertEq(address(anchor).balance, 0);
    }

    /// Three leaves, odd count: last is promoted. Must match `merkle.ts`.
    function testMerkleSortedSha256MatchesTsFixture() public {
        bytes32 a = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        bytes32 b = hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        bytes32 c = hex"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = a;
        leaves[1] = b;
        leaves[2] = c;
        bytes32 root = Sha256Merkle.root(leaves);
        // Computed by web/lib/brain/merkle.ts over the same three leaves.
        assertEq(root, hex"773d3451fc1a58582ef05fbd2e2319bb5db3a4928b317aa980a1b91dd542ff94");

        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = b;
        proof0[1] = c;
        assertTrue(Sha256Merkle.verify(a, proof0, root));

        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = Sha256Merkle.hashPair(a, b);
        assertTrue(Sha256Merkle.verify(c, proof2, root));
    }

    function testDrillWritesTestnetRoot() public {
        // sol 8305 = floor(59800701 / 7200); the same formula as mars-city.solOf.
        uint64 epoch = uint64(uint256(59800701) / 7200);
        assertEq(epoch, 8305);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = hex"1111111111111111111111111111111111111111111111111111111111111111";
        leaves[1] = hex"2222222222222222222222222222222222222222222222222222222222222222";
        bytes32 root = Sha256Merkle.root(leaves);
        vm.prank(signer);
        anchor.anchor(epoch, root, "/api/world/lineage/anchor/8305", 2);
        assertEq(anchor.rootOf(epoch), root);
    }
}
