// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FefeAnchor
/// @notice One Merkle root per Mars sol on Robinhood Chain.
///         Leaves are verified moments, lineage edges, results and environment
///         specs. The contract stores the root; anyone recomputes a proof
///         off-chain against it. No token, no payable path, no user transaction.
///
///         Mainnet (4663) deploys in the official-token window. Before unveil
///         the same bytecode is exercised on testnet 46630 only.
contract FefeAnchor {
    error NotSigner();
    error EpochTaken();
    error EmptyRoot();
    error ZeroLeaves();
    error ZeroSigner();

    event Anchored(uint64 indexed epoch, bytes32 root, string uri, uint64 leaves);

    address public immutable signer;
    mapping(uint64 epoch => bytes32 root) public rootOf;
    mapping(uint64 epoch => string uri) public uriOf;
    mapping(uint64 epoch => uint64 leaves) public leavesOf;

    constructor(address signer_) {
        if (signer_ == address(0)) revert ZeroSigner();
        signer = signer_;
    }

    /// @dev Platform signer only. `epoch = floor(head / 7200)`, same as `solOf`.
    function anchor(uint64 epoch, bytes32 root, string calldata uri, uint64 leaves) external {
        if (msg.sender != signer) revert NotSigner();
        if (root == bytes32(0)) revert EmptyRoot();
        if (leaves == 0) revert ZeroLeaves();
        if (rootOf[epoch] != bytes32(0)) revert EpochTaken();
        rootOf[epoch] = root;
        uriOf[epoch] = uri;
        leavesOf[epoch] = leaves;
        emit Anchored(epoch, root, uri, leaves);
    }
}
