// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager, IUnlockCallback, PoolKey, ModifyLiquidityParams, V4} from "./V4Types.sol";

/// @dev Plain ERC20 used only to give the testnet swap desk something to trade against.
contract BarkTestTokenV3 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/**
 * @title BarkTestnetSeederV3
 * @notice Testnet-only helper that creates an ETH/token Uniswap v4 pool with real liquidity, so
 * BarkSwapRouterV3 can be exercised end to end with a wallet instead of a fork.
 *
 * Deliberately not deployable on mainnet: the constructor reverts unless chainid == 46630.
 * Liquidity is deposited full-range by this contract and can be withdrawn by the depositor.
 * It is a test fixture, not a product surface.
 */
contract BarkTestnetSeederV3 is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ONLY_POOL_MANAGER();
    error WRONG_CHAIN();
    error BAD_AMOUNT();
    error BAD_SETTLE();
    error NOTHING_TO_WITHDRAW();

    uint256 public constant CHAIN_ID = 46630; // Robinhood Chain testnet
    uint160 private constant Q96 = 0x1000000000000000000000000; // 1:1 initial price

    IPoolManager public immutable poolManager;
    address public immutable creator;

    struct SeededPool {
        PoolKey key;
        uint128 liquidity;
        uint256 ethDeposited;
        uint256 tokenDeposited;
        bool exists;
    }

    mapping(address token => SeededPool) private _pools;

    event TokenCreated(address indexed token, string name, string symbol, uint256 supply);
    // poolId is indexed so a client can find the pool from the receipt alone.
    event PoolSeeded(address indexed token, bytes32 indexed poolId, uint128 liquidity, uint256 ethIn, uint256 tokenIn);
    event LiquidityWithdrawn(address indexed token, uint256 ethOut, uint256 tokenOut);

    constructor(IPoolManager poolManager_) {
        if (block.chainid != CHAIN_ID) revert WRONG_CHAIN();
        poolManager = poolManager_;
        creator = msg.sender;
    }

    /// @notice Deploys a test token and its ETH pool in one transaction. The caller funds the pool.
    function createTokenAndPool(string calldata name, string calldata symbol, uint256 supply, uint24 fee, int24 tickSpacing)
        external
        payable
        nonReentrant
        returns (address token, bytes32 poolId)
    {
        BarkTestTokenV3 deployed = new BarkTestTokenV3(name, symbol, supply);
        token = address(deployed);
        emit TokenCreated(token, name, symbol, supply);
        // The whole supply is available to seed; unused tokens stay with this contract for the caller.
        poolId = _seed(token, fee, tickSpacing, msg.value, supply);
    }

    /// @notice Seeds an existing token's ETH pool with the attached ETH and `tokenAmount` tokens.
    function seedExistingToken(address token, uint256 tokenAmount, uint24 fee, int24 tickSpacing)
        external
        payable
        nonReentrant
        returns (bytes32 poolId)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        poolId = _seed(token, fee, tickSpacing, msg.value, tokenAmount);
    }

    function poolOf(address token) external view returns (SeededPool memory) {
        return _pools[token];
    }

    function _seed(address token, uint24 fee, int24 tickSpacing, uint256 ethAmount, uint256 tokenAmount)
        internal
        returns (bytes32 poolId)
    {
        if (ethAmount == 0 || tokenAmount == 0) revert BAD_AMOUNT();
        PoolKey memory key = PoolKey({
            currency0: address(0),
            currency1: token,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        poolId = V4.poolId(key);
        poolManager.initialize(key, Q96);
        (uint256 used0, uint256 used1, uint256 liquidity) =
            abi.decode(poolManager.unlock(abi.encode(key, ethAmount, tokenAmount)), (uint256, uint256, uint256));
        if (liquidity == 0 || liquidity > type(uint128).max) revert BAD_AMOUNT();
        _pools[token] = SeededPool({
            key: key,
            liquidity: uint128(liquidity),
            ethDeposited: ethAmount,
            tokenDeposited: tokenAmount,
            exists: true
        });
        emit PoolSeeded(token, poolId, uint128(liquidity), used0, used1);
    }

    /// @notice Returns the seeded liquidity to the creator. No trading fees are collected here.
    function withdraw(address token) external nonReentrant returns (uint256 ethOut, uint256 tokenOut) {
        if (msg.sender != creator) revert NOTHING_TO_WITHDRAW();
        SeededPool memory pool = _pools[token];
        if (!pool.exists) revert NOTHING_TO_WITHDRAW();
        (ethOut, tokenOut) = abi.decode(
            poolManager.unlock(abi.encode(pool.key, uint256(0), uint256(0))), (uint256, uint256)
        );
        delete _pools[token];
        emit LiquidityWithdrawn(token, ethOut, tokenOut);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));
        bool removing = amount0 == 0 && amount1 == 0;
        uint128 liquidity;
        if (removing) {
            liquidity = _pools[key.currency1].liquidity;
        } else {
            uint256 liq = Math.min(amount0, amount1);
            liq -= liq / 1_000_000 + 1;
            if (liq == 0 || liq > type(uint128).max) revert BAD_AMOUNT();
            liquidity = uint128(liq);
        }
        (int256 delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                V4.minUsableTick(key.tickSpacing),
                V4.maxUsableTick(key.tickSpacing),
                removing ? -int256(uint256(liquidity)) : int256(uint256(liquidity)),
                bytes32(0)
            ),
            ""
        );
        int128 d0 = V4.amount0(delta);
        int128 d1 = V4.amount1(delta);
        if (removing) {
            if (d0 < 0 || d1 < 0) revert BAD_SETTLE();
            if (d0 > 0) poolManager.take(key.currency0, creator, uint128(d0));
            if (d1 > 0) poolManager.take(key.currency1, creator, uint128(d1));
        } else {
            if (d0 > 0 || d1 > 0) revert BAD_SETTLE();
            if (d0 < 0) poolManager.settle{value: uint128(-d0)}();
            if (d1 < 0) {
                poolManager.sync(key.currency1);
                IERC20(key.currency1).safeTransfer(address(poolManager), uint128(-d1));
                if (poolManager.settle() != uint128(-d1)) revert BAD_SETTLE();
            }
        }
        // Report the liquidity that was minted or burned so the caller can record the position.
        return abi.encode(
            uint256(uint128(d0 < 0 ? -d0 : d0)),
            uint256(uint128(d1 < 0 ? -d1 : d1)),
            uint256(liquidity)
        );
    }

    receive() external payable {}
}
