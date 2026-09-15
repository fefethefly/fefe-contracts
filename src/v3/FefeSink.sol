// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapterV3, NATIVE} from "./InterfacesV3.sol";
import {MemeTokenV3} from "./MemeTokenV3.sol";

/**
 * @title FefeSink
 * @notice Collects community protocol fees (and creation fees sent as ETH) and
 * permissionlessly buys official FEFE to burn. Official FEFE/NVDA sets
 * protocolFeeBps = 0 so this sink is not fed by the official book.
 *
 * FefeSink is a usage flywheel. It must not be counted as operating surplus S.
 */
contract FefeSink is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NOT_ADMIN();
    error ALREADY_SET();
    error NOT_SET();
    error NOTHING();
    error BAD_TOKEN();

    address public immutable admin;
    ISwapAdapterV3 public immutable adapter;
    address public fefe;

    event FefeBound(address indexed fefe);
    event Burned(address indexed quote, address indexed via, uint256 spent, uint256 burned);

    constructor(address admin_, ISwapAdapterV3 adapter_) {
        if (admin_ == address(0) || address(adapter_) == address(0)) revert BAD_TOKEN();
        admin = admin_;
        adapter = adapter_;
    }

    function setFefe(address fefe_) external {
        if (msg.sender != admin) revert NOT_ADMIN();
        if (fefe != address(0)) revert ALREADY_SET();
        if (fefe_ == address(0) || fefe_.code.length == 0) revert BAD_TOKEN();
        fefe = fefe_;
        emit FefeBound(fefe_);
    }

    /// Swap `quote` (optionally via an intermediate) into FEFE and burn it.
    /// `via == address(0)` is a single hop. Permissionless.
    function harvest(address quote, address via, uint256 minOut) external nonReentrant {
        address fefe_ = fefe;
        if (fefe_ == address(0)) revert NOT_SET();
        uint256 amount = quote == NATIVE ? address(this).balance : IERC20(quote).balanceOf(address(this));
        if (amount == 0) revert NOTHING();
        uint256 got;
        if (quote == fefe_) {
            got = amount;
        } else if (via == address(0) || via == fefe_) {
            got = _swap(quote, fefe_, amount, minOut);
        } else {
            uint256 mid = _swap(quote, via, amount, 0);
            got = _swap(via, fefe_, mid, minOut);
        }
        MemeTokenV3(fefe_).burn(got);
        emit Burned(quote, via, amount, got);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        if (tokenIn == NATIVE) {
            out = adapter.swapExactIn{value: amountIn}(NATIVE, tokenOut, amountIn, minOut, address(this));
        } else {
            IERC20(tokenIn).forceApprove(address(adapter), amountIn);
            out = adapter.swapExactIn(tokenIn, tokenOut, amountIn, minOut, address(this));
        }
    }

    receive() external payable {}
}
