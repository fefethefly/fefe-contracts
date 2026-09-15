// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager, IHooksV3, IUnlockCallback, PoolKey, SwapParams, V4} from "./V4Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NATIVE} from "../InterfacesV3.sol";

interface IMarketFeeSink {
    function onMarketFee(uint256 amount) external payable;
}

/**
 * @title BarkHookV3
 * @notice Uniswap v4 hook that charges the creator-configured buy / sell tax plus the
 * per-token protocol share on graduated BarkStreet pools. Tax goes to FeeVaultV3;
 * protocol share goes to the launchpad treasury (FefeSink). Fees are taken as swap
 * deltas (never as fee-on-transfer).
 *
 * Direction: quote in → buy tax; quote out → sell tax. When the quote is the specified
 * currency the fee is taken in `beforeSwap`; otherwise in `afterSwap`.
 *
 * Only the graduation handler can initialize pools with this hook or register fee terms.
 * Terms are immutable per pool. No owner.
 */
contract BarkHookV3 is IHooksV3, IUnlockCallback {
    error ONLY_POOL_MANAGER();
    error ONLY_HANDLER();
    error BAD_HOOK_ADDRESS();
    error BAD_KEY();
    error ALREADY_REGISTERED();
    error TAX_TOO_HIGH();
    error TRANSFER_FAILED();

    uint160 public constant REQUIRED_FLAGS = V4.BEFORE_INITIALIZE_FLAG | V4.BEFORE_SWAP_FLAG | V4.AFTER_SWAP_FLAG
        | V4.BEFORE_SWAP_RETURNS_DELTA_FLAG | V4.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint16 public constant MAX_TAX_BPS = 1_000;
    uint16 public constant MAX_PROTOCOL_BPS = 100;

    struct Market {
        address vault;
        address quote;
        uint16 buyBps;
        uint16 sellBps;
        bool quoteIsZero;
        bool active;
        uint16 protocolBps;
        address treasury;
    }

    IPoolManager public immutable poolManager;
    address public immutable handler;
    mapping(bytes32 poolId => Market) public markets;
    // A first buy can precede the router's settlement into an otherwise empty currency.
    // ERC-6909 claims book the fee without relying on unrelated pools' token balances.
    struct PendingFee { uint256 tax; uint256 protocol; }
    mapping(bytes32 poolId => PendingFee) public pendingFees;
    event FeeDeferred(bytes32 indexed poolId, uint256 tax, uint256 protocol);
    event DeferredFeeSettled(bytes32 indexed poolId, uint256 tax, uint256 protocol);

    event MarketRegistered(
        bytes32 indexed poolId, address indexed vault, address quote, uint16 buyBps, uint16 sellBps, uint16 protocolBps
    );
    event FeeTaken(bytes32 indexed poolId, address indexed vault, uint256 amount, bool isBuy);
    event ProtocolFeeTaken(bytes32 indexed poolId, address indexed treasury, uint256 amount, bool isBuy);

    constructor(IPoolManager poolManager_, address handler_) {
        if ((uint160(address(this)) & V4.ALL_HOOK_MASK) != REQUIRED_FLAGS) revert BAD_HOOK_ADDRESS();
        poolManager = poolManager_;
        handler = handler_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
        _;
    }

    function register(
        PoolKey calldata key,
        address vault,
        address quote,
        uint16 buyBps,
        uint16 sellBps,
        uint16 protocolBps,
        address treasury
    ) external {
        if (msg.sender != handler) revert ONLY_HANDLER();
        if (key.hooks != address(this) || (quote != key.currency0 && quote != key.currency1)) revert BAD_KEY();
        if (
            buyBps > MAX_TAX_BPS || sellBps > MAX_TAX_BPS || protocolBps > MAX_PROTOCOL_BPS
                || uint256(buyBps) + protocolBps > MAX_TAX_BPS || uint256(sellBps) + protocolBps > MAX_TAX_BPS
        ) revert TAX_TOO_HIGH();
        if (protocolBps > 0 && treasury == address(0)) revert BAD_KEY();
        bytes32 id = V4.poolId(key);
        if (markets[id].active) revert ALREADY_REGISTERED();
        markets[id] = Market({
            vault: vault,
            quote: quote,
            buyBps: buyBps,
            sellBps: sellBps,
            quoteIsZero: quote == key.currency0,
            active: true,
            protocolBps: protocolBps,
            treasury: treasury
        });
        emit MarketRegistered(id, vault, quote, buyBps, sellBps, protocolBps);
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != handler) revert ONLY_HANDLER();
        return IHooksV3.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int256, uint24)
    {
        bytes32 id = V4.poolId(key);
        Market memory m = markets[id];
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsZero = exactIn == params.zeroForOne;
        // The quote is the unspecified currency: afterSwap handles it.
        if (!m.active || specifiedIsZero != m.quoteIsZero) return (IHooksV3.beforeSwap.selector, 0, 0);
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        // Exact input of quote = buy; exact output of quote = sell.
        (uint256 taxFee, uint256 protocolFee) = _fees(amount, exactIn ? m.buyBps : m.sellBps, m.protocolBps);
        uint256 fee = taxFee + protocolFee;
        if (fee == 0) return (IHooksV3.beforeSwap.selector, 0, 0);
        _collect(id, m, taxFee, protocolFee, exactIn);
        return (IHooksV3.beforeSwap.selector, V4.toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bytes32 id = V4.poolId(key);
        Market memory m = markets[id];
        bool specifiedIsZero = (params.amountSpecified < 0) == params.zeroForOne;
        // Already charged in beforeSwap when the quote was the specified currency.
        if (!m.active || specifiedIsZero == m.quoteIsZero) return (IHooksV3.afterSwap.selector, 0);
        int128 q = m.quoteIsZero ? V4.amount0(delta) : V4.amount1(delta);
        // q < 0: trader pays quote (exact-output buy); q > 0: trader receives quote (exact-input sell).
        bool isBuy = q < 0;
        uint256 amount = isBuy ? uint256(uint128(-q)) : uint256(uint128(q));
        (uint256 taxFee, uint256 protocolFee) = _fees(amount, isBuy ? m.buyBps : m.sellBps, m.protocolBps);
        uint256 fee = taxFee + protocolFee;
        if (fee == 0) return (IHooksV3.afterSwap.selector, 0);
        _collect(id, m, taxFee, protocolFee, isBuy);
        return (IHooksV3.afterSwap.selector, int128(int256(fee)));
    }

    function _fees(uint256 amount, uint16 taxBps, uint16 protocolBps)
        internal
        pure
        returns (uint256 taxFee, uint256 protocolFee)
    {
        taxFee = (amount * taxBps) / 10_000;
        protocolFee = (amount * protocolBps) / 10_000;
    }

    /// Pulls tax to the vault and the protocol share to treasury, always in quote terms.
    function _collect(bytes32 id, Market memory m, uint256 taxFee, uint256 protocolFee, bool isBuy) internal {
        if (taxFee > 0) emit FeeTaken(id, m.vault, taxFee, isBuy);
        if (protocolFee > 0) emit ProtocolFeeTaken(id, m.treasury, protocolFee, isBuy);
        uint256 held = m.quote == NATIVE ? address(poolManager).balance : IERC20(m.quote).balanceOf(address(poolManager));
        PendingFee memory pending = pendingFees[id];
        if (pending.tax + pending.protocol > 0 && held >= pending.tax + pending.protocol + taxFee + protocolFee) {
            _flush(id, m);
            held -= pending.tax + pending.protocol;
        }
        if (held < taxFee + protocolFee) {
            pendingFees[id].tax += taxFee;
            pendingFees[id].protocol += protocolFee;
            poolManager.mint(address(this), uint256(uint160(m.quote)), taxFee + protocolFee);
            emit FeeDeferred(id, taxFee, protocolFee);
            return;
        }
        _payFees(m, taxFee, protocolFee);
    }

    /// Anyone can settle a deferred first-trade fee after its router has funded the manager.
    /// A later swap also settles it automatically when reserves allow.
    function settleFees(bytes32 id) external {
        if (!markets[id].active) revert BAD_KEY();
        poolManager.unlock(abi.encode(id));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        bytes32 id = abi.decode(data, (bytes32));
        _flush(id, markets[id]);
        return "";
    }

    function _flush(bytes32 id, Market memory m) internal {
        PendingFee memory fee = pendingFees[id];
        uint256 amount = fee.tax + fee.protocol;
        if (amount == 0) return;
        delete pendingFees[id];
        poolManager.burn(address(this), uint256(uint160(m.quote)), amount);
        _payFees(m, fee.tax, fee.protocol);
        emit DeferredFeeSettled(id, fee.tax, fee.protocol);
    }

    function _payFees(Market memory m, uint256 taxFee, uint256 protocolFee) internal {
        uint256 fee = taxFee + protocolFee;
        if (m.quote == NATIVE) {
            poolManager.take(NATIVE, address(this), fee);
            if (protocolFee > 0) {
                (bool ok,) = payable(m.treasury).call{value: protocolFee}("");
                if (!ok) revert TRANSFER_FAILED();
            }
            if (taxFee > 0) IMarketFeeSink(m.vault).onMarketFee{value: taxFee}(taxFee);
        } else {
            if (protocolFee > 0) {
                poolManager.take(m.quote, m.treasury, protocolFee);
            }
            if (taxFee > 0) {
                poolManager.take(m.quote, m.vault, taxFee);
                IMarketFeeSink(m.vault).onMarketFee(taxFee);
            }
        }
    }

    receive() external payable {}
}
