// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Minimal PoolManager stand-in for BarkSwapRouterV3 unit tests. It mirrors the
 * v4-core behaviour the router depends on: an `unlock` that calls back the caller,
 * `swap` returning a packed delta without moving funds, and `settle`/`take` as the
 * only paths that move value. `settle()` reports the balance it saw since `sync`,
 * so a fee-on-transfer token is detected exactly as it would be on chain.
 *
 * Signatures are decoded from calldata instead of v4-core types so the mock stays
 * independent of the router's imports.
 */
/// Tuple layout must match v4-core so the router's `swap` call selects this function.
struct MockPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct MockSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

contract MockPoolManager {
    error NOT_UNLOCKED();
    error ALREADY_UNLOCKED();
    error INSUFFICIENT();

    /// amount1 received per amount0 in, scaled by 1e18. The same rate is used in both directions.
    uint256 public rate = 2e18;

    bool private _unlocked;
    address private _synced;
    uint256 private _syncedBalance;

    function setRate(uint256 next) external {
        rate = next;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (_unlocked) revert ALREADY_UNLOCKED();
        _unlocked = true;
        (bool ok, bytes memory wrapped) =
            msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        _unlocked = false;
        if (!ok) {
            assembly {
                revert(add(wrapped, 0x20), mload(wrapped))
            }
        }
        // The callback returns abi.encode(bytes); v4-core returns the inner payload.
        (bool decoded, bytes memory payload) = _tryDecodeBytes(wrapped);
        return decoded ? payload : wrapped;
    }

    /**
     * Declared with the v4-core tuple signature so the selector matches what the router calls.
     * PoolKey (160 bytes) and SwapParams (96 bytes) are static head words, so the parameters
     * start at 4 + 160. Exact input only: amount0 = -amountIn and amount1 = +amountIn * rate
     * (mirrored when the input is currency1).
     */
    function swap(MockPoolKey calldata, MockSwapParams calldata, bytes calldata) external view returns (int256) {
        bytes calldata data = msg.data;
        if (!_unlocked) revert NOT_UNLOCKED();
        (bool zeroForOne, int256 specified) = abi.decode(data[4 + 160:], (bool, int256));
        uint256 amountIn = uint256(-specified);
        uint256 out = (amountIn * rate) / 1e18;
        int128 d0 = zeroForOne ? -int128(int256(amountIn)) : int128(int256(out));
        int128 d1 = zeroForOne ? int128(int256(out)) : -int128(int256(amountIn));
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    function sync(address currency) external {
        if (!_unlocked) revert NOT_UNLOCKED();
        _synced = currency;
        _syncedBalance = _balanceOf(currency, address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (!_unlocked) revert NOT_UNLOCKED();
        paid = _synced == address(0) ? msg.value : _balanceOf(_synced, address(this)) - _syncedBalance;
        _synced = address(0);
        _syncedBalance = 0;
    }

    function take(address currency, address to, uint256 amount) external {
        if (!_unlocked) revert NOT_UNLOCKED();
        if (currency == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert INSUFFICIENT();
        } else {
            SafeERC20.safeTransfer(IERC20(currency), to, amount);
        }
    }

    function _tryDecodeBytes(bytes memory raw) private pure returns (bool, bytes memory) {
        if (raw.length < 64) return (false, raw);
        uint256 offset;
        uint256 length;
        assembly {
            offset := mload(add(raw, 0x20))
            length := mload(add(raw, 0x40))
        }
        if (offset != 0x20 || length + 64 != raw.length) return (false, raw);
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = raw[64 + i];
        }
        return (true, out);
    }

    function _balanceOf(address currency, address who) private view returns (uint256) {
        return currency == address(0) ? who.balance : IERC20(currency).balanceOf(who);
    }

    receive() external payable {}
}
