// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Native ETH is represented by address(0) everywhere in V3.
address constant NATIVE = address(0);

/// Swap adapter used by fee vaults to turn quote into basket stocks, or meme tax into quote.
/// tokenIn == address(0) means native ETH sent as msg.value. Output goes to `recipient`.
interface ISwapAdapterV3 {
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
}

/// Graduation: receives the remaining tokens (already transferred) and the raised quote
/// (ETH as msg.value or ERC20 already transferred), builds the AMM pool and locks LP.
/// `taxOnTransfer` = true registers `pool` as a taxed market on the token (classic AMMs);
/// false means the venue collects the creator tax itself (Uniswap v4 hook) and `pool` is
/// only excluded from dividends.
interface IGraduationHandlerV3 {
    function graduate(address token, address quoteAsset, uint256 quoteAmount, uint256 tokenAmount)
        external
        payable
        returns (address pool, bool taxOnTransfer);
}

/// Receives meme-denominated transfer tax after graduation (token pushes, then calls onTax).
interface ITaxSinkV3 {
    function onTax(uint256 amount) external;
}

/// Direct launch (openlaunch-style): the token is already minted to the handler; this builds
/// the v4 pool and locks 100% of supply as a single-sided position at the virtual-quote price.
/// No creation fee, no protocol share, no LP fee — the caller pays only gas.
interface IDirectLaunchHandlerV3 {
    function launchDirect(address token, address quote, uint256 virtualQuote, address vault)
        external
        returns (address pool);
}
