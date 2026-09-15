// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FefeSink} from "../FefeSink.sol";
import {MemeTokenV3} from "../MemeTokenV3.sol";
import {BondingCurveV3} from "../BondingCurveV3.sol";
import {LaunchpadV3} from "../LaunchpadV3.sol";
import {UniswapV4SwapAdapterV3} from "./UniswapV4SwapAdapterV3.sol";
import {UniswapV4GraduationHandlerV3} from "./UniswapV4GraduationHandlerV3.sol";
import {IPoolManager, IHooksV3, PoolKey, SwapParams, ModifyLiquidityParams, V4} from "./V4Types.sol";

/// @notice Buy-and-burn execution bridge for an EXISTING immutable FefeSink/adapter.
/// Its zero-liquidity V4 keys are execution endpoints, not independent price discovery.
/// ETH uses a constructor-pinned ETH/quote pool; FEFE uses its original curve or graduated pool.
/// Before graduation only execute() activates the hook, preventing unbounded harvest.
/// After graduation quote/FEFE preserves the original permissionless pool path,
/// including the official vault's buybacks. That legacy path still trusts caller minOut.
/// No withdrawals, recipient selection, mutable market, arbitrary calldata or new FEFE.
contract FefeBuybackHookV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error BAD_CONFIG();
    error BAD_HOOK_ADDRESS();
    error ONLY_OPERATOR();
    error ONLY_POOL_MANAGER();
    error EXECUTION_INACTIVE();
    error BAD_ROUTE();
    error BAD_PLAN();
    error BALANCE_CHANGED();
    error GRADUATION_BOUNDARY();
    error PARTIAL_FILL();
    error SLIPPAGE();
    error BURN_MISMATCH();
    error NO_LIQUIDITY();
    /// Intentional revert: preview never leaves state changes, even if sent as a transaction.
    error BuybackPreview(uint256 quoteIn, uint256 burned);

    uint160 public constant REQUIRED_FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 3);
    uint256 public constant MAX_DEADLINE = 5 minutes;
    uint256 private constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    address public immutable operator;
    FefeSink public immutable sink;
    MemeTokenV3 public immutable fefe;
    BondingCurveV3 public immutable curve;
    UniswapV4SwapAdapterV3 public immutable adapter;
    UniswapV4GraduationHandlerV3 public immutable handler;
    IPoolManager public immutable poolManager;
    address public immutable quote;
    PoolKey private _nativeQuotePool;

    struct Execution {
        address source;
        uint256 amount;
        uint256 minQuote;
        uint256 minFefe;
        uint256 received;
        uint256 quoteReceived;
        bool active;
        bool consumed;
    }
    Execution private _execution;

    event BuybackExecuted(address indexed source, uint256 spent, uint256 quoteIn, uint256 burned, bool graduated);

    constructor(address official_, address launchpad_, address operator_) {
        if ((uint160(address(this)) & V4.ALL_HOOK_MASK) != REQUIRED_FLAGS) revert BAD_HOOK_ADDRESS();
        if (
            block.chainid != 4663 || operator_ == address(0) || official_.code.length == 0
                || launchpad_.code.length == 0
        ) {
            revert BAD_CONFIG();
        }
        operator = operator_;
        MemeTokenV3 token = MemeTokenV3(official_);
        LaunchpadV3 pad = LaunchpadV3(launchpad_);
        BondingCurveV3 c = BondingCurveV3(payable(token.curve()));
        FefeSink collector = FefeSink(payable(pad.treasury()));
        UniswapV4SwapAdapterV3 a = UniswapV4SwapAdapterV3(payable(address(collector.adapter())));
        UniswapV4GraduationHandlerV3 h = a.handler();
        (address registeredToken, address registeredCurve,,, address registeredQuote,) = pad.deployments(official_);
        address q = c.quote();
        if (
            registeredToken != official_ || registeredCurve != address(c) || registeredQuote != q || q == address(0)
                || q == official_ || q.code.length == 0 || address(c.token()) != official_
                || c.launchpad() != launchpad_ || collector.fefe() != official_ || address(pad.adapter()) != address(a)
                || address(c.gradHandler()) != address(h) || h.launchpad() != launchpad_
                || address(h.poolManager()) != address(a.poolManager()) || h.treasury() != address(collector)
        ) revert BAD_CONFIG();
        (PoolKey memory stockPool, bool ok) = a.route(address(0), q);
        if (!ok || stockPool.currency0 != address(0) || stockPool.currency1 != q || stockPool.hooks != address(0)) {
            revert BAD_CONFIG();
        }
        fefe = token;
        curve = c;
        sink = collector;
        adapter = a;
        handler = h;
        poolManager = a.poolManager();
        quote = q;
        _nativeQuotePool = stockPool;
    }

    function nativeQuotePool() external view returns (PoolKey memory) {
        return _nativeQuotePool;
    }

    function keyFor(address source) public view returns (PoolKey memory) {
        if (source != address(0) && source != quote) revert BAD_ROUTE();
        (address lo, address hi) = source < address(fefe) ? (source, address(fefe)) : (address(fefe), source);
        return PoolKey(lo, hi, 0, 1, address(this));
    }

    /// The legacy sink spends its entire selected balance. Pin that balance, market
    /// phase, both conversion floors and a short deadline before submitting.
    function execute(
        address source,
        uint256 amount,
        uint256 minQuote,
        uint256 minFefe,
        bool graduated,
        uint256 deadline
    ) external nonReentrant returns (uint256 burned) {
        if (msg.sender != operator) revert ONLY_OPERATOR();
        (burned,) = _execute(source, amount, minQuote, minFefe, graduated, deadline);
    }

    /// Call using eth_call from operator at a pinned block. Decode BuybackPreview;
    /// any other revert is a failed path, not a quote. Apply slippage floors to this
    /// full-route result and refresh immediately before sending execute().
    function preview(address source, uint256 amount, bool graduated) external nonReentrant {
        if (msg.sender != operator) revert ONLY_OPERATOR();
        (uint256 burned, uint256 quoteIn) = _execute(source, amount, 1, 1, graduated, block.timestamp);
        revert BuybackPreview(quoteIn, burned);
    }

    function _execute(
        address source,
        uint256 amount,
        uint256 minQuote,
        uint256 minFefe,
        bool graduated,
        uint256 deadline
    ) private returns (uint256 burned, uint256 quoteIn) {
        if (source != address(0) && source != quote) revert BAD_ROUTE();
        if (
            amount == 0 || amount > MAX_AMOUNT || minQuote == 0 || minFefe == 0 || deadline < block.timestamp
                || deadline > block.timestamp + MAX_DEADLINE || curve.graduated() != graduated
        ) revert BAD_PLAN();
        uint256 balance = source == address(0) ? address(sink).balance : IERC20(source).balanceOf(address(sink));
        if (balance != amount) revert BALANCE_CHANGED();
        (PoolKey memory route, bool ok) = adapter.route(source, address(fefe));
        if (!ok || V4.poolId(route) != V4.poolId(keyFor(source))) revert BAD_ROUTE();
        uint256 supply = fefe.totalSupply();
        uint256 held = fefe.balanceOf(address(sink));
        _execution = Execution(source, amount, minQuote, minFefe, 0, 0, true, false);
        sink.harvest(source, address(0), minFefe);
        Execution memory done = _execution;
        if (
            !done.consumed || done.received == 0 || fefe.totalSupply() > supply
                || supply - fefe.totalSupply() != done.received || fefe.balanceOf(address(sink)) != held
        ) revert BURN_MISMATCH();
        burned = done.received;
        quoteIn = done.quoteReceived;
        delete _execution;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 price) external view returns (bytes4) {
        _onlyManager();
        if (sender != operator || price != uint160(1 << 96)) revert BAD_CONFIG();
        _source(key);
        return IHooksV3.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _onlyManager();
        revert NO_LIQUIDITY();
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, int256, uint24)
    {
        _onlyManager();
        Execution memory plan = _execution;
        address source = _source(key);
        if (!plan.active) {
            // Preserve the official vault and the standard V4 Quoter once it graduates.
            if (
                source != quote || !curve.graduated() || params.amountSpecified >= 0
                    || params.amountSpecified < -int256(MAX_AMOUNT)
            ) revert EXECUTION_INACTIVE();
            uint256 amount = uint256(-params.amountSpecified);
            address tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
            uint256 got = _poolBuy(_graduatedPool(), tokenIn, amount);
            if (got > MAX_AMOUNT) revert PARTIAL_FILL();
            return (IHooksV3.beforeSwap.selector, V4.toBeforeSwapDelta(int128(int256(amount)), -int128(int256(got))), 0);
        }
        if (plan.consumed || sender != address(adapter)) revert EXECUTION_INACTIVE();
        if (
            source != plan.source || params.amountSpecified != -int256(plan.amount)
                || params.zeroForOne != (source == key.currency0)
        ) revert BAD_PLAN();
        _execution.consumed = true;
        uint256 quoteIn = source == quote ? plan.amount : _poolBuy(_nativeQuotePool, source, plan.amount);
        if (quoteIn < plan.minQuote) revert SLIPPAGE();
        uint256 out;
        bool graduated = curve.graduated();
        if (graduated) {
            out = _poolBuy(_graduatedPool(), quote, quoteIn);
        } else {
            out = _curveBuy(quoteIn, plan.minFefe);
        }
        if (out < plan.minFefe || out > MAX_AMOUNT) revert SLIPPAGE();
        _execution.received = out;
        _execution.quoteReceived = quoteIn;
        emit BuybackExecuted(source, plan.amount, quoteIn, out, graduated);
        return
            (IHooksV3.beforeSwap.selector, V4.toBeforeSwapDelta(int128(int256(plan.amount)), -int128(int256(out))), 0);
    }

    function _curveBuy(uint256 amount, uint256 minOut) private returns (uint256 out) {
        (, uint256 protocolFee, uint256 tax, uint256 penalty) = curve.quoteBuy(amount, address(this));
        (, uint128 threshold,,,,,,,,) = curve.config();
        // The existing graduation handler calls unlock(). Crossing here would nest
        // unlocks inside the adapter's unlock; reject before moving any curve funds.
        if (curve.backingReserve() + amount - protocolFee - tax - penalty >= threshold) revert GRADUATION_BOUNDARY();
        uint256 beforeQuote = IERC20(quote).balanceOf(address(this));
        uint256 beforeFefe = fefe.balanceOf(address(this));
        poolManager.take(quote, address(this), amount);
        if (IERC20(quote).balanceOf(address(this)) != beforeQuote + amount) revert PARTIAL_FILL();
        IERC20(quote).forceApprove(address(curve), amount);
        out = curve.buy(amount, minOut, address(this));
        IERC20(quote).forceApprove(address(curve), 0);
        if (IERC20(quote).balanceOf(address(this)) != beforeQuote || fefe.balanceOf(address(this)) != beforeFefe + out)
        {
            revert PARTIAL_FILL();
        }
        poolManager.sync(address(fefe));
        IERC20(address(fefe)).safeTransfer(address(poolManager), out);
        if (poolManager.settle() != out || fefe.balanceOf(address(this)) != beforeFefe) revert PARTIAL_FILL();
    }

    /// Nested swaps leave deltas on this hook. The outer custom delta cancels them;
    /// the unchanged adapter settles input and takes FEFE for the unchanged sink.
    function _poolBuy(PoolKey memory key, address source, uint256 amount) private returns (uint256 out) {
        if (amount == 0 || amount > MAX_AMOUNT) revert BAD_PLAN();
        bool zeroForOne = source == key.currency0;
        int256 delta = poolManager.swap(
            key, SwapParams(zeroForOne, -int256(amount), zeroForOne ? V4.MIN_SQRT_PRICE + 1 : V4.MAX_SQRT_PRICE - 1), ""
        );
        (int128 paid, int128 got) =
            zeroForOne ? (V4.amount0(delta), V4.amount1(delta)) : (V4.amount1(delta), V4.amount0(delta));
        if (paid >= 0 || uint256(-int256(paid)) != amount || got <= 0) revert PARTIAL_FILL();
        return uint256(uint128(got));
    }

    function _source(PoolKey memory key) private view returns (address source) {
        source = key.currency0 == address(fefe) ? key.currency1 : key.currency0;
        if (V4.poolId(key) != V4.poolId(keyFor(source))) revert BAD_ROUTE();
    }

    function _onlyManager() private view {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
    }

    function _graduatedPool() private view returns (PoolKey memory market) {
        market = handler.poolKeyOf(address(fefe));
        if (
            market.hooks != address(handler.hook()) || market.hooks == address(this)
                || !((market.currency0 == quote && market.currency1 == address(fefe))
                    || (market.currency1 == quote && market.currency0 == address(fefe)))
        ) revert BAD_ROUTE();
    }
}
