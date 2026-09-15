// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDirectLaunchHandlerV3, IGraduationHandlerV3, NATIVE} from "../InterfacesV3.sol";
import {MemeTokenV3} from "../MemeTokenV3.sol";
import {IPoolManager, IUnlockCallback, PoolKey, ModifyLiquidityParams, V4} from "./V4Types.sol";
import {TickPrice} from "./TickPrice.sol";
import {BarkHookV3} from "./BarkHookV3.sol";

interface ICurveProtocolFee {
    function PROTOCOL_FEE_BPS() external view returns (uint256);
}

interface ILaunchpadDeployments {
    function deployments(address token)
        external
        view
        returns (address token_, address curve, address vault, address creator, address quoteAsset, uint64 createdAt);
}

/// Minimal binding surface of FeeVaultV3 used to prove a direct-launch vault matches the token.
interface IFeeVaultBinding {
    function token() external view returns (address);
    function quote() external view returns (address);
}

/**
 * @title UniswapV4GraduationHandlerV3
 * @notice Turns a graduated bonding curve into a Uniswap v4 pool: initializes
 * quote/meme at the curve's final price, deposits everything as one full-range position
 * owned by this contract, and registers the creator's taxes plus protocol share with
 * BarkHookV3. There is no function that removes liquidity, so the position is locked
 * forever. Pool LP fee is 0 — the same 1% trade take used on the curve is charged by
 * the hook (tax → FeeVault, protocol → treasury / FefeSink).
 *
 * Only curves created by the bound LaunchpadV3 can graduate through this handler.
 */
contract UniswapV4GraduationHandlerV3 is IGraduationHandlerV3, IDirectLaunchHandlerV3, IUnlockCallback {
    using SafeERC20 for IERC20;

    error ONLY_POOL_MANAGER();
    error ONLY_DEPLOYER();
    error ALREADY_BOUND();
    error NOT_BOUND();
    error NOT_A_CURVE();
    error NOT_DIRECT_LAUNCHPAD();
    error BAD_AMOUNTS();
    error BAD_VALUE();
    error PRICE_OUT_OF_RANGE();
    error NOT_POOLED();
    error TRANSFER_FAILED();

    uint24 public constant LP_FEE = 0; // hook takes the 1% trade fee; no extra LP layer
    int24 public constant TICK_SPACING = 200;
    uint256 private constant Q96 = 1 << 96;

    IPoolManager public immutable poolManager;
    address public immutable treasury;
    address public immutable deployer;
    BarkHookV3 public hook;
    address public launchpad;
    address public directLaunchpad;

    struct Range {
        int24 lower;
        int24 upper;
    }

    mapping(address token => PoolKey) private _keyOf;
    mapping(address token => bool) public pooled;
    mapping(address token => Range) private _rangeOf;

    event Bound(address hook, address launchpad);
    event BoundDirect(address directLaunchpad);
    /// amount0 / amount1 are the deposited amounts in pool currency order (currency0 given).
    event Graduated(
        address indexed token,
        bytes32 indexed poolId,
        address currency0,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidity,
        uint160 sqrtPriceX96
    );
    /// Direct launch: token pool built from 100% of supply at the virtual-quote price.
    event DirectLaunched(
        address indexed token,
        bytes32 indexed poolId,
        address currency0,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidity,
        uint160 sqrtPriceX96
    );
    event FeesCollected(address indexed token, uint256 amount0, uint256 amount1);

    constructor(IPoolManager poolManager_, address treasury_) {
        poolManager = poolManager_;
        treasury = treasury_;
        deployer = msg.sender;
    }

    /// One-shot wiring after the hook (needs this address) and launchpad (needs this address) exist.
    function bind(BarkHookV3 hook_, address launchpad_) external {
        if (msg.sender != deployer) revert ONLY_DEPLOYER();
        if (address(hook) != address(0)) revert ALREADY_BOUND();
        if (hook_.handler() != address(this) || launchpad_.code.length == 0) revert NOT_BOUND();
        hook = hook_;
        launchpad = launchpad_;
        emit Bound(address(hook_), launchpad_);
    }

    /// One-shot wiring for a direct-only deployment: bind the hook without a curve launchpad.
    function bindHook(BarkHookV3 hook_) external {
        if (msg.sender != deployer) revert ONLY_DEPLOYER();
        if (address(hook) != address(0)) revert ALREADY_BOUND();
        if (hook_.handler() != address(this)) revert NOT_BOUND();
        hook = hook_;
        emit Bound(address(hook_), address(0));
    }

    /// One-shot wiring of the direct launchpad. The hook must already be bound.
    function bindDirect(address directLaunchpad_) external {
        if (msg.sender != deployer) revert ONLY_DEPLOYER();
        if (address(hook) == address(0)) revert NOT_BOUND();
        if (directLaunchpad != address(0)) revert ALREADY_BOUND();
        if (directLaunchpad_.code.length == 0) revert NOT_BOUND();
        directLaunchpad = directLaunchpad_;
        emit BoundDirect(directLaunchpad_);
    }

    function poolKeyOf(address token) external view returns (PoolKey memory) {
        if (!pooled[token]) revert NOT_POOLED();
        return _keyOf[token];
    }

    // ─── IGraduationHandlerV3 ──────────────────────────────────────────────────
    function graduate(address token, address quote, uint256 quoteAmount, uint256 tokenAmount)
        external
        payable
        override
        returns (address pool, bool taxOnTransfer)
    {
        address vault = _checkCaller(token, quote, quoteAmount, tokenAmount);
        PoolKey memory key = _key(token, quote);
        uint256 protocolBps = ICurveProtocolFee(msg.sender).PROTOCOL_FEE_BPS();
        if (protocolBps > type(uint16).max) revert BAD_AMOUNTS();
        hook.register(
            key,
            vault,
            quote,
            MemeTokenV3(token).buyTaxBps(),
            MemeTokenV3(token).sellTaxBps(),
            uint16(protocolBps),
            treasury
        );
        _keyOf[token] = key;
        pooled[token] = true;
        if (key.currency0 == quote) _seed(token, key, quoteAmount, tokenAmount);
        else _seed(token, key, tokenAmount, quoteAmount);
        return (address(poolManager), false);
    }

    // ─── IDirectLaunchHandlerV3 ────────────────────────────────────────────────
    /// @notice One transaction: initialize the pool at the virtual-quote price and deposit 100%
    /// of supply as a single-sided position locked in this contract. No LP fee, no protocol share.
    function launchDirect(address token, address quote, uint256 virtualQuote, address vault)
        external
        override
        returns (address pool)
    {
        _checkDirectCaller(token, quote, vault);
        if (virtualQuote == 0) revert BAD_AMOUNTS();
        PoolKey memory key = _key(token, quote);
        hook.register(
            key, vault, quote, MemeTokenV3(token).buyTaxBps(), MemeTokenV3(token).sellTaxBps(), uint16(0), treasury
        );
        _keyOf[token] = key;
        pooled[token] = true;
        _seedDirect(token, key, virtualQuote);
        return address(poolManager);
    }

    function _seedDirect(address token, PoolKey memory key, uint256 virtualQuote) internal {
        (int24 tickLower, int24 tickUpper, uint128 liq, uint160 sqrtP0) =
            _tokenSidePosition(token, key, _initialSqrtPrice(token, key, virtualQuote));
        poolManager.initialize(key, sqrtP0);
        _rangeOf[token] = Range(tickLower, tickUpper);
        (uint256 used0, uint256 used1) = _depositDirect(token, key, tickLower, tickUpper, liq);
        // Exclude the pool from dividends, exactly like the graduated path.
        MemeTokenV3(token).setExempt(address(poolManager), true);
        // Burn the rounding dust so pool + dead == FIXED_SUPPLY.
        _burnDust(token);
        emit DirectLaunched(token, V4.poolId(key), key.currency0, used0, used1, liq, sqrtP0);
    }

    function _depositDirect(address token, PoolKey memory key, int24 low, int24 high, uint128 liq)
        internal returns (uint256, uint256)
    {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 a0 = key.currency0 == token ? balance : 0;
        uint256 a1 = key.currency1 == token ? balance : 0;
        return abi.decode(poolManager.unlock(abi.encode(key, low, high, liq, a0, a1)), (uint256, uint256));
    }

    function _checkDirectCaller(address token, address quote, address vault) internal view {
        if (address(hook) == address(0) || directLaunchpad == address(0)) revert NOT_BOUND();
        if (msg.sender != directLaunchpad) revert NOT_DIRECT_LAUNCHPAD();
        if (pooled[token]) revert ALREADY_BOUND();
        if (MemeTokenV3(token).curve() != address(this)) revert NOT_A_CURVE();
        if (IFeeVaultBinding(vault).token() != token || IFeeVaultBinding(vault).quote() != quote) revert NOT_A_CURVE();
        if (IERC20(token).balanceOf(address(this)) < MemeTokenV3(token).FIXED_SUPPLY()) revert BAD_AMOUNTS();
    }

    /// sqrtPriceX96 for the virtual-quote launch price, in pool currency order (P = token / quote).
    function _initialSqrtPrice(address token, PoolKey memory key, uint256 virtualQuote)
        internal
        view
        returns (uint160 sqrtP0)
    {
        uint256 S = MemeTokenV3(token).FIXED_SUPPLY();
        uint256 num = key.currency1 == token ? S : virtualQuote;
        uint256 den = key.currency1 == token ? virtualQuote : S;
        sqrtP0 = uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
        if (sqrtP0 <= V4.MIN_SQRT_PRICE || sqrtP0 >= V4.MAX_SQRT_PRICE) revert PRICE_OUT_OF_RANGE();
    }

    /// Direct vaults use the adapter for buybacks from their first trade.
    function graduated() external pure returns (bool) { return true; }

    /// Snap to a usable tick in the direction that never requires quote funding.
    /// The opening token price rounds up by less than 1.0001^200 (about 2.03%).
    /// Binary search avoids introducing a second inverse tick/price implementation.
    function _tokenSidePosition(address token, PoolKey memory key, uint160 target)
        internal view returns (int24 tickLower, int24 tickUpper, uint128 liq, uint160 sqrtP0)
    {
        int24 low = V4.minUsableTick(key.tickSpacing) / key.tickSpacing;
        int24 high = V4.maxUsableTick(key.tickSpacing) / key.tickSpacing;
        int24 minTick = low * key.tickSpacing;
        int24 maxTick = high * key.tickSpacing;
        while (low < high) {
            int24 mid = low + (high - low + 1) / 2;
            if (TickPrice.getSqrtPriceAtTick(mid * key.tickSpacing) <= target) low = mid;
            else high = mid - 1;
        }
        int24 edge = low * key.tickSpacing;
        if (key.currency0 == token && TickPrice.getSqrtPriceAtTick(edge) < target) edge += key.tickSpacing;
        if (edge <= minTick || edge >= maxTick) revert PRICE_OUT_OF_RANGE();
        sqrtP0 = TickPrice.getSqrtPriceAtTick(edge);
        uint256 supply = MemeTokenV3(token).FIXED_SUPPLY();
        uint256 l;
        if (key.currency1 == token) {
            tickLower = minTick;
            tickUpper = edge;
            l = Math.mulDiv(supply, Q96, uint256(sqrtP0) - TickPrice.getSqrtPriceAtTick(minTick));
        } else {
            tickLower = edge;
            tickUpper = maxTick;
            uint160 upper = TickPrice.getSqrtPriceAtTick(maxTick);
            l = Math.mulDiv(supply, Math.mulDiv(sqrtP0, upper, Q96), uint256(upper) - sqrtP0);
        }
        if (l == 0 || l > type(uint128).max) revert BAD_AMOUNTS();
        liq = uint128(l);
    }

    function _burnDust(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(address(0xdead), bal);
    }

    /// Initializes at the curve's final price and deposits (a0, a1) — in currency order — as full-range liquidity.
    function _seed(address token, PoolKey memory key, uint256 a0, uint256 a1) internal {
        (uint160 sqrtPriceX96, uint128 liq) = _priceAndLiquidity(a0, a1);
        int24 low = V4.minUsableTick(key.tickSpacing);
        int24 high = V4.maxUsableTick(key.tickSpacing);
        _rangeOf[token] = Range(low, high);
        poolManager.initialize(key, sqrtPriceX96);
        (uint256 used0, uint256 used1) =
            abi.decode(poolManager.unlock(abi.encode(key, low, high, liq, a0, a1)), (uint256, uint256));
        emit Graduated(token, V4.poolId(key), key.currency0, used0, used1, liq, sqrtPriceX96);
        // Rounding dust goes to the treasury so nothing is stranded here.
        _sweep(key.currency0, a0 - used0);
        _sweep(key.currency1, a1 - used1);
    }

    function _checkCaller(address token, address quote, uint256 quoteAmount, uint256 tokenAmount)
        internal
        view
        returns (address vault)
    {
        if (address(hook) == address(0)) revert NOT_BOUND();
        address curve;
        (, curve, vault,,,) = ILaunchpadDeployments(launchpad).deployments(token);
        if (curve == address(0) || msg.sender != curve) revert NOT_A_CURVE();
        if (quoteAmount == 0 || tokenAmount == 0) revert BAD_AMOUNTS();
        if (quote == NATIVE) {
            if (msg.value != quoteAmount) revert BAD_VALUE();
        } else {
            if (msg.value != 0 || IERC20(quote).balanceOf(address(this)) < quoteAmount) revert BAD_VALUE();
        }
        if (IERC20(token).balanceOf(address(this)) < tokenAmount) revert BAD_AMOUNTS();
    }

    function _key(address token, address quote) internal view returns (PoolKey memory) {
        (address c0, address c1) = quote < token ? (quote, token) : (token, quote);
        return PoolKey(c0, c1, LP_FEE, TICK_SPACING, address(hook));
    }

    /// sqrtPriceX96 = sqrt(a1 / a0) * 2^96; full-range L = min(a0 * sqrtP / Q96, a1 * Q96 / sqrtP), shaved for rounding.
    function _priceAndLiquidity(uint256 a0, uint256 a1) internal pure returns (uint160 sqrtPriceX96, uint128 liq) {
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
        if (sqrtPriceX96 <= V4.MIN_SQRT_PRICE || sqrtPriceX96 >= V4.MAX_SQRT_PRICE) revert PRICE_OUT_OF_RANGE();
        uint256 l = Math.min(Math.mulDiv(a0, sqrtPriceX96, Q96), Math.mulDiv(a1, Q96, sqrtPriceX96));
        l -= l / 1_000_000 + 1;
        if (l == 0 || l > type(uint128).max) revert BAD_AMOUNTS();
        liq = uint128(l);
    }

    /// Anyone may push the locked position's accrued LP fees to the treasury.
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1) {
        if (!pooled[token]) revert NOT_POOLED();
        Range memory r = _rangeOf[token];
        bytes memory res =
            poolManager.unlock(abi.encode(_keyOf[token], r.lower, r.upper, uint128(0), uint256(0), uint256(0)));
        (amount0, amount1) = abi.decode(res, (uint256, uint256));
        emit FeesCollected(token, amount0, amount1);
    }

    // ─── PoolManager callback ──────────────────────────────────────────────────
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liq, uint256 a0, uint256 a1) =
            abi.decode(data, (PoolKey, int24, int24, uint128, uint256, uint256));
        ModifyLiquidityParams memory p = ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liq)), bytes32(0));
        (int256 delta,) = poolManager.modifyLiquidity(key, p, "");
        int128 d0 = V4.amount0(delta);
        int128 d1 = V4.amount1(delta);
        if (liq == 0) {
            // Fee collection: deltas are what the pool owes us.
            if (d0 < 0 || d1 < 0) revert BAD_AMOUNTS();
            if (d0 > 0) poolManager.take(key.currency0, treasury, uint128(d0));
            if (d1 > 0) poolManager.take(key.currency1, treasury, uint128(d1));
            return abi.encode(uint256(uint128(d0)), uint256(uint128(d1)));
        }
        if (d0 > 0 || d1 > 0 || uint128(-d0) > a0 || uint128(-d1) > a1) revert BAD_AMOUNTS();
        _pay(key.currency0, uint128(-d0));
        _pay(key.currency1, uint128(-d1));
        return abi.encode(uint256(uint128(-d0)), uint256(uint128(-d1)));
    }

    function _pay(address currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == NATIVE) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(currency).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _sweep(address currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == NATIVE) {
            (bool ok,) = payable(treasury).call{value: amount}("");
            if (!ok) revert TRANSFER_FAILED();
        } else {
            IERC20(currency).safeTransfer(treasury, amount);
        }
    }

    receive() external payable {}
}
