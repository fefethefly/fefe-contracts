// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapterV3} from "../InterfacesV3.sol";
import {CommoditySwapAdapterV3} from "./CommoditySwapAdapterV3.sol";
import {CommodityOracleGuardV3} from "./CommodityOracleGuardV3.sol";

interface IMarketRouteAdapterV3 is ISwapAdapterV3 {
    function hasRoute(address tokenIn, address tokenOut) external view returns (bool);
}

/// Fixed adapter selection for FeeVault reward purchases and graduated meme/V4 swaps.
/// A failed selected venue never falls through to another venue. V4 route governance remains upstream.
contract MarketSwapDispatcherV3 is ISwapAdapterV3, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error BAD_CONFIG();
    error WRONG_CHAIN();
    error BAD_VALUE();
    error NO_ROUTE();
    error INPUT_MISMATCH();
    error OUTPUT_MISMATCH();
    error SLIPPAGE();
    uint256 public immutable chainId;
    CommoditySwapAdapterV3 public immutable commodity;
    IMarketRouteAdapterV3 public immutable market;
    CommodityOracleGuardV3 public immutable oracleGuard;
    event RoutedSwap(
        address indexed caller,
        address indexed adapter,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    constructor(CommoditySwapAdapterV3 commodity_, IMarketRouteAdapterV3 market_) {
        if (
            address(commodity_).code.length == 0 || address(market_).code.length == 0
                || address(commodity_) == address(market_)
        ) revert BAD_CONFIG();
        if (commodity_.chainId() != block.chainid) revert WRONG_CHAIN();
        chainId = block.chainid;
        commodity = commodity_;
        market = market_;
        oracleGuard = commodity_.oracleGuard();
    }

    /// Route topology only; source freshness, liquidity and output are checked separately at execution.
    function selectedAdapter(address tokenIn, address tokenOut) public view returns (address) {
        if (block.chainid != chainId) revert WRONG_CHAIN();
        if (tokenIn == tokenOut) return address(0);
        if (commodity.hasRoute(tokenIn, tokenOut)) return address(commodity);
        return market.hasRoute(tokenIn, tokenOut) ? address(market) : address(0);
    }

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool) {
        return selectedAdapter(tokenIn, tokenOut) != address(0);
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        address selected = selectedAdapter(tokenIn, tokenOut);
        if (selected == address(0)) revert NO_ROUTE();
        if (
            amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || minOut == 0 || recipient == address(0)
                || recipient == address(this) || recipient == address(commodity) || recipient == address(market)
                || (tokenIn == address(0) ? msg.value != amountIn : msg.value != 0)
        ) revert BAD_VALUE();
        // Commodity health also protects commodity/meme swaps that use the market adapter.
        if (selected != address(commodity)) validateSources(tokenIn, tokenOut);
        uint256 inputBefore =
            tokenIn == address(0) ? address(this).balance - msg.value : IERC20(tokenIn).balanceOf(address(this));
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore + amountIn) revert INPUT_MISMATCH();
            IERC20(tokenIn).forceApprove(selected, amountIn);
        }
        uint256 outputBefore = balance(tokenOut, recipient);
        amountOut =
            ISwapAdapterV3(selected).swapExactIn{value: msg.value}(tokenIn, tokenOut, amountIn, minOut, recipient);
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(selected, 0);
        if (balance(tokenIn, address(this)) != inputBefore) revert INPUT_MISMATCH();
        if (balance(tokenOut, recipient) != outputBefore + amountOut) revert OUTPUT_MISMATCH();
        if (amountOut < minOut) revert SLIPPAGE();
        if (selected != address(commodity)) validateSources(tokenIn, tokenOut);
        emit RoutedSwap(msg.sender, selected, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function validateSources(address a, address b) private view {
        if (oracleGuard.hasAsset(a)) oracleGuard.validate(a);
        if (oracleGuard.hasAsset(b)) oracleGuard.validate(b);
    }

    function balance(address asset, address account) private view returns (uint256) {
        return asset == address(0) ? account.balance : IERC20(asset).balanceOf(account);
    }
}
