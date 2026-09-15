// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {LaunchpadV3} from "./LaunchpadV3.sol";
import {CommodityOracleGuardV3} from "./uniswap/CommodityOracleGuardV3.sol";
import {CommoditySwapAdapterV3} from "./uniswap/CommoditySwapAdapterV3.sol";
import {MarketSwapDispatcherV3} from "./uniswap/MarketSwapDispatcherV3.sol";
import {UniswapV4SwapAdapterV3} from "./uniswap/UniswapV4SwapAdapterV3.sol";
import {UniswapV4GraduationHandlerV3} from "./uniswap/UniswapV4GraduationHandlerV3.sol";
import {BarkHookV3} from "./uniswap/BarkHookV3.sol";

/// A separate, immutable commodity launch scope. No defaults or admin expansion of approved assets.
/// Source health is checked at creation; existing curve buys/sells are not oracle-gated by this class.
contract CommodityLaunchpadV3 is LaunchpadV3 {
    error BAD_RELEASE_CONFIG();
    error STACK_NOT_BOUND();
    error ASSET_NOT_RELEASED();
    error CURVE_POLICY_MISMATCH();
    error FIRST_BUY_LIMIT();
    error REWARD_ROUTE_UNAVAILABLE();

    struct QuotePolicy {
        address asset;
        uint128 virtualQuote;
        uint128 graduationQuote;
        uint128 maxFirstBuy;
    }

    struct Limits {
        uint128 virtualQuote;
        uint128 graduationQuote;
        uint128 maxFirstBuy;
    }
    uint256 public immutable releaseChainId;
    CommodityOracleGuardV3 public immutable oracleGuard;
    MarketSwapDispatcherV3 public immutable dispatcher;
    CommoditySwapAdapterV3 public immutable commodityAdapter;
    UniswapV4SwapAdapterV3 public immutable marketAdapter;
    UniswapV4GraduationHandlerV3 public immutable graduationHandler;
    bytes32 public immutable policyHash;
    mapping(address => Limits) public quotePolicies;
    address[] public releasedAssets;

    constructor(
        address treasury_,
        UniswapV4GraduationHandlerV3 handler_,
        MarketSwapDispatcherV3 dispatcher_,
        QuotePolicy[] memory policies
    ) LaunchpadV3(treasury_, handler_, dispatcher_) {
        if (dispatcher_.chainId() != block.chainid || policies.length == 0 || policies.length > 8) revert BAD_RELEASE_CONFIG();
        releaseChainId = block.chainid;
        dispatcher = dispatcher_;
        oracleGuard = dispatcher_.oracleGuard();
        commodityAdapter = dispatcher_.commodity();
        marketAdapter = UniswapV4SwapAdapterV3(payable(address(dispatcher_.market())));
        graduationHandler = handler_;
        if (
            address(marketAdapter.handler()) != address(handler_)
                || address(marketAdapter.poolManager()) != address(handler_.poolManager())
                || address(handler_.poolManager()).code.length == 0 || handler_.treasury() != treasury_
        ) revert BAD_RELEASE_CONFIG();
        for (uint256 i; i < policies.length; ++i) {
            QuotePolicy memory p = policies[i];
            if (
                p.virtualQuote == 0 || p.graduationQuote == 0 || p.maxFirstBuy > p.graduationQuote
                    || quotePolicies[p.asset].virtualQuote != 0 || !oracleGuard.hasAsset(p.asset)
                    || commodityAdapter.pools(p.asset) == address(0)
            ) revert BAD_RELEASE_CONFIG();
            quotePolicies[p.asset] = Limits(p.virtualQuote, p.graduationQuote, p.maxFirstBuy);
            releasedAssets.push(p.asset);
        }
        policyHash = keccak256(abi.encode(block.chainid, treasury_, address(handler_), address(dispatcher_), policies));
    }

    function releasedAssetCount() external view returns (uint256) {
        return releasedAssets.length;
    }

    function releaseMode() public pure virtual returns (string memory) {
        return "cross-asset-research-v1";
    }

    function validateStack() public view {
        if (
            block.chainid != releaseChainId || graduationHandler.launchpad() != address(this)
                || address(marketAdapter.handler()) != address(graduationHandler)
        ) revert STACK_NOT_BOUND();
        BarkHookV3 hook = graduationHandler.hook();
        if (
            address(hook).code.length == 0 || hook.handler() != address(graduationHandler)
                || address(hook.poolManager()) != address(graduationHandler.poolManager())
        ) revert STACK_NOT_BOUND();
    }

    function _validate(Launch calldata p) internal view virtual override {
        super._validate(p);
        validateStack();
        Limits memory limits = quotePolicies[p.quoteAsset];
        if (limits.virtualQuote == 0) revert ASSET_NOT_RELEASED();
        if (p.virtualQuote != limits.virtualQuote || p.graduationQuote != limits.graduationQuote) {
            revert CURVE_POLICY_MISMATCH();
        }
        if (p.firstBuyQuote > limits.maxFirstBuy) revert FIRST_BUY_LIMIT();
        oracleGuard.validate(p.quoteAsset);
        for (uint256 i; i < p.basketTokens.length; ++i) {
            address reward = p.basketTokens[i];
            if (quotePolicies[reward].virtualQuote == 0) revert ASSET_NOT_RELEASED();
            oracleGuard.validate(reward);
            if (reward != p.quoteAsset && dispatcher.selectedAdapter(p.quoteAsset, reward) != address(commodityAdapter))
            {
                revert REWARD_ROUTE_UNAVAILABLE();
            }
        }
    }
}
