// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

struct InstantDistribution {
    address strategy;
    uint128 amount;
    bytes configData;
}

struct InstantPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IInstantLauncher {
    function distributeToken(address token, InstantDistribution calldata distribution, bytes32 salt) external payable;
}

interface IInstantPositions {
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 id) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 id) external view returns (InstantPoolKey memory, uint256);
}

interface IInstantStrategy {
    function launcher() external view returns (address);
    function positionManager() external view returns (address);
    function poolManager() external view returns (address);
    function feeSplitter() external view returns (address);
    function beneficiaryVault() external view returns (address);
}

/// @dev Undeployed candidate: fixed supply, no privileged mint, tax, owner, or upgrade functions.
contract InstantCommunityToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

/// @notice Undeployed Robinhood-mainnet-only integration candidate; not an audited launch service.
/// @dev Creates and distributes atomically. The direct caller receives the fee NFT, not free tokens.
/// No payments, first buy, platform fee, relaying, or arbitrary strategy selection in this candidate.
contract InstantLaunchGateway is ReentrancyGuard {
    error WrongChain();
    error DeploymentMismatch(address target);
    error InvalidMetadata();
    error Expired();
    error SaltUsed();
    error IncompleteLaunch();

    uint256 public constant CHAIN_ID = 4663;
    address public constant LAUNCHER = 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0;
    address public constant STRATEGY = 0x23f8209572b4a1C2AD88A42749E830791Fb027f1;
    address public constant POSITIONS = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant SPLITTER = 0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf;
    address public constant BENEFICIARY_VAULT = 0xd35E9CA72F64C7F93BE30fad67524323396B36D7;
    address public constant COMPOUNDER = 0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a;

    mapping(address creator => mapping(bytes32 salt => address token)) public tokenFor;
    event CommunityCreated(address indexed creator, address indexed token, uint256 indexed positionId, bytes32 salt);

    constructor() {
        _checkDeployment();
    }

    function create(string calldata name, string calldata symbol, bytes32 salt, uint256 deadline)
        external
        nonReentrant
        returns (address token, uint256 positionId)
    {
        if (block.timestamp > deadline) revert Expired();
        _validateMetadata(bytes(name), bytes(symbol));
        if (tokenFor[msg.sender][salt] != address(0)) revert SaltUsed();
        _checkDeployment();
        positionId = IInstantPositions(POSITIONS).nextTokenId();
        InstantCommunityToken created =
            new InstantCommunityToken{salt: keccak256(abi.encode(msg.sender, salt))}(name, symbol);
        token = address(created);
        tokenFor[msg.sender][salt] = token;
        if (!created.transfer(LAUNCHER, created.totalSupply())) revert IncompleteLaunch();
        IInstantLauncher(LAUNCHER)
            .distributeToken(
                token, InstantDistribution(STRATEGY, uint128(created.totalSupply()), abi.encode(msg.sender)), bytes32(0)
            );
        _checkPosition(created, positionId);
        emit CommunityCreated(msg.sender, token, positionId, salt);
    }

    function _checkPosition(InstantCommunityToken token, uint256 id) private view {
        (InstantPoolKey memory key,) = IInstantPositions(POSITIONS).getPoolAndPositionInfo(id);
        if (
            key.currency0 != address(0) || key.currency1 != address(token) || key.fee != 2500 || key.tickSpacing != 25
                || key.hooks != address(0) || IInstantPositions(POSITIONS).nextTokenId() != id + 1
                || IInstantPositions(POSITIONS).getPositionLiquidity(id) == 0
                || IERC721(POSITIONS).ownerOf(id) != SPLITTER || IERC721(BENEFICIARY_VAULT).ownerOf(id) != msg.sender
                || token.balanceOf(address(this)) != 0 || token.balanceOf(LAUNCHER) != 0
                || token.balanceOf(STRATEGY) != 0
                || token.balanceOf(POOL_MANAGER) + token.balanceOf(address(0xdead)) != token.totalSupply()
        ) revert IncompleteLaunch();
    }

    function _validateMetadata(bytes memory name, bytes memory symbol) private pure {
        if (name.length == 0 || name.length > 96 || symbol.length < 2 || symbol.length > 8) revert InvalidMetadata();
        if (name[0] == 0x20 || name[name.length - 1] == 0x20) revert InvalidMetadata();
        for (uint256 i; i < name.length; i++) {
            if (uint8(name[i]) < 32 || uint8(name[i]) == 127) revert InvalidMetadata();
        }
        for (uint256 i; i < symbol.length; i++) {
            uint8 c = uint8(symbol[i]);
            if (!((c >= 65 && c <= 90) || (c >= 48 && c <= 57))) revert InvalidMetadata();
        }
    }

    function _requireHash(address target, bytes32 expected) private view {
        if (target.codehash != expected) revert DeploymentMismatch(target);
    }

    function _checkDeployment() private view {
        if (block.chainid != CHAIN_ID) revert WrongChain();
        // Observed runtimes at block 55428656. Hash pinning is not source verification or an audit.
        _requireHash(LAUNCHER, 0x4a586d925c9d59ece13ce2239ebd7dea9ee725f9d33c6667e0fd16ae8d977d80);
        _requireHash(STRATEGY, 0x29df27cf43533e9b3708dcd2a2c0fd17a1a8796407e7d39375f47e5c809cffca);
        _requireHash(POSITIONS, 0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2);
        _requireHash(POOL_MANAGER, 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626);
        _requireHash(SPLITTER, 0x8238e5106b3a895514083110d1f3b4e51be61148604f35113719af56ae325f42);
        _requireHash(BENEFICIARY_VAULT, 0x725412bf002214373afc095b0b9e4c756b1d12ac37d5c7dfe1667db4385403b6);
        _requireHash(COMPOUNDER, 0xb9b1a32990c06baedf12b01208967d6a8373afbf99b684ea81b07c7b99e5dbe9);
        IInstantStrategy strategy = IInstantStrategy(STRATEGY);
        if (
            strategy.launcher() != LAUNCHER || strategy.positionManager() != POSITIONS
                || strategy.poolManager() != POOL_MANAGER || strategy.feeSplitter() != SPLITTER
                || strategy.beneficiaryVault() != BENEFICIARY_VAULT
        ) revert DeploymentMismatch(STRATEGY);
    }
}
