// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Minimal ABI surface of Uniswap v4 core used by BarkStreet V3. Struct layouts and
 * function selectors match v4-core (PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951
 * on Robinhood Chain). Kept local so the repo does not vendor v4-core.
 */
struct PoolKey {
    address currency0; // address(0) = native ETH; sorted currency0 < currency1
    address currency1;
    uint24 fee; // static LP fee in pips (1e6 = 100%)
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // negative = exact input, positive = exact output
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    /// Returns (callerDelta, feesAccrued) as packed BalanceDelta (amount0 << 128 | amount1).
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// Hook callbacks the PoolManager invokes on BarkHookV3 (selectors must match v4-core IHooks).
interface IHooksV3 {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, int256 beforeSwapDelta, uint24 lpFeeOverride);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        int256 delta,
        bytes calldata hookData
    ) external returns (bytes4, int128 hookDeltaUnspecified);
}

library V4 {
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    // Hook permission bits (low 14 bits of the hook address).
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;

    function poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function amount0(int256 delta) internal pure returns (int128) {
        return int128(delta >> 128);
    }

    function amount1(int256 delta) internal pure returns (int128) {
        return int128(delta);
    }

    function toBalanceDelta(int128 a0, int128 a1) internal pure returns (int256) {
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    /// BeforeSwapDelta packs (specified << 128 | unspecified).
    function toBeforeSwapDelta(int128 specified, int128 unspecified) internal pure returns (int256) {
        return (int256(specified) << 128) | int256(uint256(uint128(unspecified)));
    }

    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MIN_TICK / tickSpacing) * tickSpacing;
    }

    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MAX_TICK / tickSpacing) * tickSpacing;
    }
}
