// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, V4} from "./V4Types.sol";

/**
 * @title BarkSwapRouterV3
 * @notice Exact-input swaps on Uniswap v4 for the ETH-quoted pools the swap desk observes.
 *
 * Unlike UniswapV4SwapAdapterV3 (routeAdmin registers each pair before the FeeVault may use it),
 * this router takes the pool key from the caller. That is safe because the key only points at
 * liquidity the caller already chose, and the caller sets `minAmountOut`, so the worst case is a
 * swap the caller would have rejected. What the router does enforce:
 *   - hookless pools only (`key.hooks == address(0)`), so no external contract can take a cut
 *     inside the swap;
 *   - currency0 must be native ETH and currency1 an ERC20, matching the desk's route;
 *   - exact input, deadline, and `amountOut >= minAmountOut`;
 *   - the settled input equals the requested input, so fee-on-transfer tokens cannot half-fill.
 *
 * Holds no funds between calls; `receive()` exists only for PoolManager refunds.
 */
contract BarkSwapRouterV3 is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ONLY_POOL_MANAGER();
    error ONLY_NATIVE_QUOTED();
    error HOOKED_POOL();
    error BAD_KEY();
    error BAD_AMOUNT();
    error EXPIRED();
    error SLIPPAGE();
    error BAD_SETTLE();
    error TRANSFER_FAILED();

    IPoolManager public immutable poolManager;

    /// Set for the duration of one unlock: inside `unlockCallback` msg.sender is the PoolManager,
    /// so the trader who owes the input has to be carried across the callback boundary.
    address private _payer;

    event Swapped(
        address indexed caller,
        address indexed recipient,
        PoolKey key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(IPoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert BAD_KEY();
        poolManager = poolManager_;
    }

    /// @notice Pay ETH, receive `key.currency1`. Excess ETH is returned to the caller.
    function swapExactEthForToken(
        PoolKey calldata key,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        _checkKey(key);
        if (recipient == address(0) || amountIn == 0 || msg.value < amountIn || block.timestamp > deadline) {
            if (block.timestamp > deadline) revert EXPIRED();
            revert BAD_AMOUNT();
        }
        _payer = msg.sender;
        bytes memory result = poolManager.unlock(abi.encode(uint8(1), key, recipient, amountIn, minAmountOut));
        _payer = address(0);
        amountOut = abi.decode(result, (uint256));
        if (msg.value > amountIn) _sendNative(msg.sender, msg.value - amountIn);
        emit Swapped(msg.sender, recipient, key, true, amountIn, amountOut);
    }

    /// @notice Pay `key.currency1`, receive ETH. The caller must approve this router first.
    function swapExactTokenForEth(
        PoolKey calldata key,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        _checkKey(key);
        if (recipient == address(0) || amountIn == 0 || block.timestamp > deadline) {
            if (block.timestamp > deadline) revert EXPIRED();
            revert BAD_AMOUNT();
        }
        _payer = msg.sender;
        bytes memory result = poolManager.unlock(abi.encode(uint8(2), key, recipient, amountIn, minAmountOut));
        _payer = address(0);
        amountOut = abi.decode(result, (uint256));
        emit Swapped(msg.sender, recipient, key, false, amountIn, amountOut);
    }

    /// The pool identity is the key itself, so these checks only reject pools this desk never prices.
    function _checkKey(PoolKey calldata key) internal pure {
        if (key.hooks != address(0)) revert HOOKED_POOL();
        if (key.currency0 != address(0) || key.currency1 == address(0)) revert ONLY_NATIVE_QUOTED();
        if (key.tickSpacing <= 0 || key.tickSpacing > 32767) revert BAD_KEY();
        if (key.fee > 1_000_000 || (key.fee & 0x800000) != 0) revert BAD_KEY();
        if (key.currency0 >= key.currency1) revert BAD_KEY();
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
        (uint8 mode, PoolKey memory key, address recipient, uint256 amountIn, uint256 minAmountOut) =
            abi.decode(data, (uint8, PoolKey, address, uint256, uint256));
        bool zeroForOne = mode == 1;
        if (mode != 1 && mode != 2) revert BAD_KEY();

        int256 delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? V4.MIN_SQRT_PRICE + 1 : V4.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 d0 = V4.amount0(delta);
        int128 d1 = V4.amount1(delta);

        // Exact input: the input side is what we owe, the other side is what the pool owes us.
        if (zeroForOne) {
            if (d0 >= 0 || d1 <= 0) revert BAD_SETTLE();
            _settleNative(uint128(-d0));
            poolManager.take(key.currency1, recipient, uint128(d1));
        } else {
            if (d1 >= 0 || d0 <= 0) revert BAD_SETTLE();
            _settleToken(key.currency1, uint128(-d1));
            poolManager.take(key.currency0, recipient, uint128(d0));
        }

        uint256 amountOut = uint256(uint128(zeroForOne ? d1 : d0));
        if (amountOut < minAmountOut) revert SLIPPAGE();
        return abi.encode(amountOut);
    }

    function _settleNative(uint256 amount) internal {
        poolManager.settle{value: amount}();
    }

    function _settleToken(address token, uint256 amount) internal {
        if (_payer == address(0)) revert BAD_SETTLE();
        poolManager.sync(token);
        // Balance the PoolManager by transfer, then require it recognized exactly `amount`:
        // a fee-on-transfer token would otherwise leave the pool short.
        IERC20(token).safeTransferFrom(_payer, address(poolManager), amount);
        if (poolManager.settle() != amount) revert BAD_SETTLE();
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TRANSFER_FAILED();
    }

    /// @dev Only the PoolManager refunds ETH here; a stray sender would otherwise be stuck with the router.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert TRANSFER_FAILED();
    }
}
