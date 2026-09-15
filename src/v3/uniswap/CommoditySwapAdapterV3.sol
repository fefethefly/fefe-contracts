// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapterV3} from "../InterfacesV3.sol";

import {CommodityOracleGuardV3} from "./CommodityOracleGuardV3.sol";

interface ICommodityV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface ICommodityV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function fee() external view returns (uint24);
    function swap(address recipient, bool zeroForOne, int256 amount, uint160 limit, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice Candidate ERC20 reward conversion through fixed V3 pools and a shared bridge.
/// No mutable routes, arbitrary calldata, router approvals, or native/meme pool fallback.
/// This adapter alone does NOT cover a market's graduation or meme-tax settlement.
/// Execution checks the pinned price source; deployment review and real-pool execution remain release gates.
contract CommoditySwapAdapterV3 is ISwapAdapterV3, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error BAD_CONFIG();
    error BAD_ROUTE();
    error BAD_VALUE();
    error WRONG_CHAIN();
    error BAD_CALLBACK();
    error PARTIAL_FILL();
    error TRANSFER_MISMATCH();
    error SLIPPAGE();

    uint160 private constant MIN_LIMIT = 4295128740;
    uint160 private constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;
    uint256 private constant MAX_INPUT = uint256(uint128(type(int128).max));
    uint256 public immutable chainId;
    CommodityOracleGuardV3 public immutable oracleGuard;
    ICommodityV3Factory public immutable factory;
    address public immutable bridge;
    uint24 public immutable poolFee;
    mapping(address asset => address pool) public pools;

    address private callbackPool;
    address private callbackToken;
    uint256 private callbackAmount;
    bool private callbackZeroForOne;
    bool private callbackPaid;

    constructor(
        uint256 chainId_,
        ICommodityV3Factory factory_,
        address bridge_,
        uint24 fee_,
        address[] memory assets,
        address[] memory expectedPools,
        CommodityOracleGuardV3 guard_
    ) {
        if (block.chainid != chainId_) revert WRONG_CHAIN();
        if (
            address(factory_).code.length == 0 || bridge_.code.length == 0 || fee_ == 0 || assets.length == 0
                || assets.length > 64 || assets.length != expectedPools.length
        ) revert BAD_CONFIG();
        if (address(guard_).code.length == 0 || guard_.chainId() != chainId_) revert BAD_CONFIG();
        oracleGuard = guard_;
        if (IERC20Metadata(bridge_).decimals() != 6) revert BAD_CONFIG();
        chainId = chainId_;
        factory = factory_;
        bridge = bridge_;
        poolFee = fee_;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            address pool = expectedPools[i];
            if (!guard_.hasAsset(asset)) revert BAD_CONFIG();
            if (asset == bridge_ || asset.code.length == 0 || pool.code.length == 0 || pools[asset] != address(0)) {
                revert BAD_CONFIG();
            }
            if (IERC20Metadata(asset).decimals() != 18 || factory_.getPool(asset, bridge_, fee_) != pool) {
                revert BAD_CONFIG();
            }
            ICommodityV3Pool p = ICommodityV3Pool(pool);
            (address lo, address hi) = asset < bridge_ ? (asset, bridge_) : (bridge_, asset);
            if (p.token0() != lo || p.token1() != hi || p.factory() != address(factory_) || p.fee() != fee_) {
                revert BAD_CONFIG();
            }
            pools[asset] = pool;
        }
    }

    function hasRoute(address tokenIn, address tokenOut) public view returns (bool) {
        return tokenIn != tokenOut && tokenIn != address(0) && tokenOut != address(0)
            && (tokenIn == bridge || pools[tokenIn] != address(0))
            && (tokenOut == bridge || pools[tokenOut] != address(0));
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        payable
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.chainid != chainId) revert WRONG_CHAIN();
        if (!hasRoute(tokenIn, tokenOut)) revert BAD_ROUTE();
        if (
            msg.value != 0 || amountIn == 0 || amountIn > MAX_INPUT || minOut == 0 || recipient == address(0)
                || recipient == address(this) || recipient == pools[tokenIn] || recipient == pools[tokenOut]
        ) revert BAD_VALUE();
        if (tokenIn != bridge) oracleGuard.validate(tokenIn);
        if (tokenOut != bridge) oracleGuard.validate(tokenOut);
        uint256 beforeInput = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) != beforeInput + amountIn) revert TRANSFER_MISMATCH();
        if (tokenIn == bridge || tokenOut == bridge) {
            amountOut = _hop(tokenIn, tokenOut, amountIn, recipient);
        } else {
            uint256 beforeBridge = IERC20(bridge).balanceOf(address(this));
            uint256 intermediate = _hop(tokenIn, bridge, amountIn, address(this));
            amountOut = _hop(bridge, tokenOut, intermediate, recipient);
            if (IERC20(bridge).balanceOf(address(this)) != beforeBridge) revert PARTIAL_FILL();
        }
        if (IERC20(tokenIn).balanceOf(address(this)) != beforeInput) revert PARTIAL_FILL();
        if (amountOut < minOut) revert SLIPPAGE();
        if (tokenIn != bridge) oracleGuard.validate(tokenIn);
        if (tokenOut != bridge) oracleGuard.validate(tokenOut);
    }

    function _hop(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        private
        returns (uint256 out)
    {
        if (amountIn == 0 || amountIn > MAX_INPUT) revert BAD_VALUE();
        address asset = tokenIn == bridge ? tokenOut : tokenIn;
        address pool = pools[asset];
        oracleGuard.validate(asset);
        if (factory.getPool(asset, bridge, poolFee) != pool) revert BAD_ROUTE();
        bool zeroForOne = tokenIn < tokenOut;
        uint256 beforeOutput = IERC20(tokenOut).balanceOf(recipient);
        callbackPool = pool;
        callbackToken = tokenIn;
        callbackAmount = amountIn;
        callbackZeroForOne = zeroForOne;
        callbackPaid = false;
        (int256 d0, int256 d1) =
            ICommodityV3Pool(pool).swap(recipient, zeroForOne, int256(amountIn), zeroForOne ? MIN_LIMIT : MAX_LIMIT, "");
        if (!callbackPaid) revert BAD_CALLBACK();
        delete callbackPool;
        delete callbackToken;
        delete callbackAmount;
        (int256 spent, int256 received) = zeroForOne ? (d0, d1) : (d1, d0);
        if (spent != int256(amountIn) || received >= 0 || received == type(int256).min) revert PARTIAL_FILL();
        out = uint256(-received);
        if (IERC20(tokenOut).balanceOf(recipient) != beforeOutput + out) revert TRANSFER_MISMATCH();
    }

    /// Pays only the currently active, constructor-pinned factory pool, exactly once.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != callbackPool || callbackPool == address(0) || callbackPaid) revert BAD_CALLBACK();
        (int256 owed, int256 received) =
            callbackZeroForOne ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (owed != int256(callbackAmount) || received >= 0) revert PARTIAL_FILL();
        callbackPaid = true;
        uint256 beforePool = IERC20(callbackToken).balanceOf(msg.sender);
        IERC20(callbackToken).safeTransfer(msg.sender, callbackAmount);
        if (IERC20(callbackToken).balanceOf(msg.sender) != beforePool + callbackAmount) revert TRANSFER_MISMATCH();
    }
}
