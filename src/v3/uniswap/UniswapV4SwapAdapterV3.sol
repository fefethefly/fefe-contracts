// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapterV3, NATIVE} from "../InterfacesV3.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, V4} from "./V4Types.sol";
import {UniswapV4GraduationHandlerV3} from "./UniswapV4GraduationHandlerV3.sol";

/**
 * @title UniswapV4SwapAdapterV3
 * @notice Exact-input single-hop swaps on Uniswap v4 for FeeVaultV3 (basket purchases,
 * buybacks, post-graduation tax settlement). Routes:
 *   1. pairs configured by `routeAdmin` — the live ETH/stock pools differ in fee tier per
 *      stock (see docs/research/UNISWAP-ETH-STOCK-POOLS-2026-09-07.json), so they are set
 *      explicitly and can be re-pointed when liquidity migrates;
 *   2. meme pools created by the graduation handler, resolved automatically.
 * Holds no funds between calls. Partial fills revert.
 */
contract UniswapV4SwapAdapterV3 is ISwapAdapterV3, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ONLY_POOL_MANAGER();
    error ONLY_ADMIN();
    error BAD_VALUE();
    error BAD_ROUTE();
    error NO_ROUTE();
    error PARTIAL_FILL();
    error SLIPPAGE();
    error ALREADY_SET();

    IPoolManager public immutable poolManager;
    address public routeAdmin;
    UniswapV4GraduationHandlerV3 public handler;
    mapping(bytes32 pair => PoolKey) private _routes;

    event RouteSet(address indexed a, address indexed b, bytes32 poolId, uint24 fee, int24 tickSpacing, address hooks);
    event RouteAdminChanged(address admin);
    event HandlerSet(address handler);

    constructor(IPoolManager poolManager_, address routeAdmin_) {
        poolManager = poolManager_;
        routeAdmin = routeAdmin_;
    }

    modifier onlyAdmin() {
        if (msg.sender != routeAdmin) revert ONLY_ADMIN();
        _;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────
    function setHandler(UniswapV4GraduationHandlerV3 handler_) external onlyAdmin {
        if (address(handler) != address(0)) revert ALREADY_SET();
        handler = handler_;
        emit HandlerSet(address(handler_));
    }

    function setRouteAdmin(address admin) external onlyAdmin {
        routeAdmin = admin;
        emit RouteAdminChanged(admin);
    }

    /// `key` must be the sorted pool for exactly {a, b}. tickSpacing 0 clears the route.
    function setRoute(address a, address b, PoolKey calldata key) external onlyAdmin {
        (address lo, address hi) = a < b ? (a, b) : (b, a);
        if (lo == hi) revert BAD_ROUTE();
        if (key.tickSpacing != 0 && (key.currency0 != lo || key.currency1 != hi)) revert BAD_ROUTE();
        _routes[_pair(lo, hi)] = key;
        emit RouteSet(lo, hi, key.tickSpacing == 0 ? bytes32(0) : V4.poolId(key), key.fee, key.tickSpacing, key.hooks);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────
    function route(address tokenIn, address tokenOut) public view returns (PoolKey memory key, bool ok) {
        (address lo, address hi) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        key = _routes[_pair(lo, hi)];
        if (key.tickSpacing != 0) return (key, true);
        if (address(handler) != address(0)) {
            address meme = handler.pooled(tokenIn) ? tokenIn : handler.pooled(tokenOut) ? tokenOut : address(0);
            if (meme != address(0)) {
                key = handler.poolKeyOf(meme);
                if (key.currency0 == lo && key.currency1 == hi) return (key, true);
            }
        }
        return (key, false);
    }

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool ok) {
        (, ok) = route(tokenIn, tokenOut);
    }

    // ─── ISwapAdapterV3 ────────────────────────────────────────────────────────
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert BAD_VALUE();
        if (tokenIn == NATIVE) {
            if (msg.value != amountIn) revert BAD_VALUE();
        } else {
            if (msg.value != 0) revert BAD_VALUE();
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        (PoolKey memory key, bool ok) = route(tokenIn, tokenOut);
        if (!ok) revert NO_ROUTE();
        bool zeroForOne = tokenIn == key.currency0;
        bytes memory res = poolManager.unlock(abi.encode(key, zeroForOne, amountIn, recipient));
        amountOut = abi.decode(res, (uint256));
        if (amountOut < minOut) revert SLIPPAGE();
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        int256 delta = poolManager.swap(
            key,
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? V4.MIN_SQRT_PRICE + 1 : V4.MAX_SQRT_PRICE - 1),
            ""
        );
        (int128 dIn, int128 dOut) =
            zeroForOne ? (V4.amount0(delta), V4.amount1(delta)) : (V4.amount1(delta), V4.amount0(delta));
        if (dIn >= 0 || uint256(uint128(-dIn)) != amountIn) revert PARTIAL_FILL();
        if (dOut <= 0) revert PARTIAL_FILL();
        (address tokenIn, address tokenOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (tokenIn == NATIVE) {
            poolManager.settle{value: amountIn}();
        } else {
            poolManager.sync(tokenIn);
            IERC20(tokenIn).safeTransfer(address(poolManager), amountIn);
            poolManager.settle();
        }
        poolManager.take(tokenOut, recipient, uint256(uint128(dOut)));
        return abi.encode(uint256(uint128(dOut)));
    }

    function _pair(address lo, address hi) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(lo, hi));
    }

    receive() external payable {}
}
