// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommodityLaunchpadV3} from "./CommodityLaunchpadV3.sol";
import {MarketSwapDispatcherV3} from "./uniswap/MarketSwapDispatcherV3.sol";
import {UniswapV4GraduationHandlerV3} from "./uniswap/UniswapV4GraduationHandlerV3.sol";

/// Separate release candidate: holders receive the existing quote asset directly.
/// No automatic treasury conversion, buyback or jackpot. Does not authorize a deployment.
contract CommodityDirectRewardLaunchpadV3 is CommodityLaunchpadV3 {
    error UNSUPPORTED_DISTRIBUTION();

    function releaseMode() public pure override returns (string memory) {
        return "direct-quote-rewards-v1";
    }

    constructor(
        address treasury_,
        UniswapV4GraduationHandlerV3 handler_,
        MarketSwapDispatcherV3 dispatcher_,
        QuotePolicy[] memory policies
    ) CommodityLaunchpadV3(treasury_, handler_, dispatcher_, policies) {}

    function _validate(Launch calldata p) internal view override {
        if (
            p.split.burnBps != 0 || p.split.jackpotBps != 0 || p.split.basketBps == 0 || p.basketTokens.length != 1
                || p.basketWeights.length != 1 || p.basketTokens[0] != p.quoteAsset || p.basketWeights[0] != 10000
        ) {
            revert UNSUPPORTED_DISTRIBUTION();
        }
        super._validate(p);
    }
}
