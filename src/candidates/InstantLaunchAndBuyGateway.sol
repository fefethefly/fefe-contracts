// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    InstantCommunityToken,
    InstantDistribution,
    InstantPoolKey,
    IInstantLauncher,
    IInstantPositions,
    IInstantStrategy
} from "./InstantLaunchGateway.sol";

struct InitialSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IInitialBuyPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(InstantPoolKey calldata key, InitialSwapParams calldata params, bytes calldata hookData)
        external
        returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @notice Undeployed isolated candidate: creation and exact-input initial buy succeed or revert together.
/// @dev No platform fee, arbitrary router, hook, recipient, strategy or relay support. Not audited.
contract InstantLaunchAndBuyGateway is ReentrancyGuard {
    error InvalidBuy();
    error InvalidCallback();
    error BuyNotFilled();
    error MinimumOutputNotMet();
    error UnexpectedSettlement();
    bytes32 private pendingBuy;

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

    event InitialBuy(
        address indexed buyer, address indexed token, uint256 indexed positionId, uint256 nativeIn, uint256 tokensOut
    );

    constructor() {
        _checkDeployment();
    }

    function createAndBuy(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        uint256 minimumTokensOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 positionId, uint256 tokensOut) {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0 || msg.value > uint256(uint128(type(int128).max)) || minimumTokensOut == 0) {
            revert InvalidBuy();
        }
        _validateMetadata(bytes(name), bytes(symbol));
        if (tokenFor[msg.sender][salt] != address(0)) revert SaltUsed();
        _checkDeployment();
        uint256 nativeBefore = address(this).balance - msg.value;
        (token, positionId) = _create(name, symbol, salt);
        bytes memory context = abi.encode(msg.sender, token, uint128(msg.value), minimumTokensOut);
        pendingBuy = keccak256(context);
        bytes memory result = IInitialBuyPoolManager(POOL_MANAGER).unlock(context);
        if (result.length != 32 || pendingBuy != bytes32(0)) revert UnexpectedSettlement();
        tokensOut = abi.decode(result, (uint256));
        InstantCommunityToken created = InstantCommunityToken(token);
        if (
            address(this).balance != nativeBefore || tokensOut < minimumTokensOut
                || created.balanceOf(msg.sender) != tokensOut || created.balanceOf(address(this)) != 0
                || created.balanceOf(POOL_MANAGER) + created.balanceOf(address(0xdead)) + tokensOut
                    != created.totalSupply()
        ) revert UnexpectedSettlement();
        emit CommunityCreated(msg.sender, token, positionId, salt);
        emit InitialBuy(msg.sender, token, positionId, msg.value, tokensOut);
    }

    function _create(string calldata name, string calldata symbol, bytes32 salt)
        private
        returns (address token, uint256 positionId)
    {
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
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || pendingBuy == bytes32(0) || keccak256(data) != pendingBuy) {
            revert InvalidCallback();
        }
        pendingBuy = bytes32(0);
        (address buyer, address token, uint128 amount, uint256 minimumOut) =
            abi.decode(data, (address, address, uint128, uint256));
        IInitialBuyPoolManager manager = IInitialBuyPoolManager(POOL_MANAGER);
        int256 delta = manager.swap(
            InstantPoolKey(address(0), token, 2500, 25, address(0)),
            InitialSwapParams(true, -int256(uint256(amount)), 4295128740),
            ""
        );
        int128 nativeDelta = int128(delta >> 128);
        int128 tokenDelta = int128(delta);
        if (nativeDelta != -int128(amount) || tokenDelta <= 0) revert BuyNotFilled();
        uint256 output = uint128(tokenDelta);
        if (output < minimumOut) revert MinimumOutputNotMet();
        manager.sync(address(0));
        if (manager.settle{value: amount}() != amount) revert UnexpectedSettlement();
        manager.take(token, buyer, output);
        return abi.encode(output);
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
