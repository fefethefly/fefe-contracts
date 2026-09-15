// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {CommodityLaunchpadV3} from "../src/v3/CommodityLaunchpadV3.sol";
import {MarketSwapDispatcherV3} from "../src/v3/uniswap/MarketSwapDispatcherV3.sol";
import {CommoditySwapAdapterV3} from "../src/v3/uniswap/CommoditySwapAdapterV3.sol";
import {CommodityOracleGuardV3} from "../src/v3/uniswap/CommodityOracleGuardV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";

/// Read-only connectivity/runtime review. Expected hashes must come from an independently reviewed bundle.
/// No broadcast, private key, environment mutation or release-list writes.
contract ReviewCommodityLaunchpad is Script {
    /// All expectations an operator pins before trusting a deployed stack. Tests pass this
    /// struct directly instead of going through process env: vm.setEnv mutates the process
    /// environment, which parallel test suites share, so env-driven tests race and flake.
    struct Expectations {
        address launchpad;
        string releaseMode;
        bytes32 policyHash;
        address treasury;
        address routeAdmin;
        uint256 sourceMaxAge;
        uint256 observationMaxAge;
        bytes32 padCodehash;
        bytes32 dispatcherCodehash;
        bytes32 commodityCodehash;
        bytes32 guardCodehash;
        bytes32 v4Codehash;
        bytes32 handlerCodehash;
        bytes32 hookCodehash;
        bytes32 factoryCodehash;
        bytes32 feedCodehash;
        bytes32 bridgeCodehash;
        bytes32 poolManagerCodehash;
        bytes32[] assetCodehashes;
        bytes32[] poolCodehashes;
    }

    function run() external view {
        require(block.chainid == 4663, "Robinhood mainnet review only");
        CommodityLaunchpadV3 pad = CommodityLaunchpadV3(vm.envAddress("LUMOB_COMMODITY_LAUNCHPAD"));
        uint256 count = pad.releasedAssetCount();
        bytes32[] memory assets = new bytes32[](count);
        bytes32[] memory pools = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = vm.envBytes32(string.concat("LUMOB_ASSET_", vm.toString(i), "_CODEHASH"));
            pools[i] = vm.envBytes32(string.concat("LUMOB_POOL_", vm.toString(i), "_CODEHASH"));
        }
        review(
            Expectations({
                launchpad: address(pad),
                releaseMode: vm.envString("LUMOB_EXPECTED_RELEASE_MODE"),
                policyHash: vm.envBytes32("LUMOB_EXPECTED_POLICY_HASH"),
                treasury: vm.envAddress("LUMOB_EXPECTED_TREASURY"),
                routeAdmin: vm.envAddress("LUMOB_EXPECTED_ROUTE_ADMIN"),
                sourceMaxAge: vm.envUint("LUMOB_EXPECTED_SOURCE_MAX_AGE"),
                observationMaxAge: vm.envUint("LUMOB_EXPECTED_OBSERVATION_MAX_AGE"),
                padCodehash: vm.envBytes32("LUMOB_PAD_CODEHASH"),
                dispatcherCodehash: vm.envBytes32("LUMOB_DISPATCHER_CODEHASH"),
                commodityCodehash: vm.envBytes32("LUMOB_COMMODITY_CODEHASH"),
                guardCodehash: vm.envBytes32("LUMOB_GUARD_CODEHASH"),
                v4Codehash: vm.envBytes32("LUMOB_V4_CODEHASH"),
                handlerCodehash: vm.envBytes32("LUMOB_HANDLER_CODEHASH"),
                hookCodehash: vm.envBytes32("LUMOB_HOOK_CODEHASH"),
                factoryCodehash: vm.envBytes32("LUMOB_FACTORY_CODEHASH"),
                feedCodehash: vm.envBytes32("LUMOB_FEED_CODEHASH"),
                bridgeCodehash: vm.envBytes32("LUMOB_BRIDGE_CODEHASH"),
                poolManagerCodehash: vm.envBytes32("LUMOB_POOL_MANAGER_CODEHASH"),
                assetCodehashes: assets,
                poolCodehashes: pools
            })
        );
    }

    function review(Expectations memory e) public view {
        require(block.chainid == 4663, "Robinhood mainnet review only");
        CommodityLaunchpadV3 pad = CommodityLaunchpadV3(e.launchpad);
        checkCode("LUMOB_PAD_CODEHASH", address(pad), e.padCodehash);
        pad.validateStack();
        bytes32 modeHash = keccak256(bytes(e.releaseMode));
        require(
            modeHash == keccak256("direct-quote-rewards-v1") || modeHash == keccak256("cross-asset-research-v1"),
            "unknown release mode"
        );
        require(keccak256(bytes(pad.releaseMode())) == modeHash, "release mode mismatch");
        console2.log("release mode", e.releaseMode);
        bytes32 expected = e.policyHash;
        require(expected != bytes32(0) && pad.policyHash() == expected, "policy hash mismatch");
        require(pad.treasury() == e.treasury, "treasury mismatch");
        MarketSwapDispatcherV3 dispatcher = pad.dispatcher();
        CommoditySwapAdapterV3 commodity = pad.commodityAdapter();
        CommodityOracleGuardV3 guard = pad.oracleGuard();
        UniswapV4SwapAdapterV3 market = pad.marketAdapter();
        UniswapV4GraduationHandlerV3 handler = pad.graduationHandler();
        checkCode("LUMOB_DISPATCHER_CODEHASH", address(dispatcher), e.dispatcherCodehash);
        checkCode("LUMOB_COMMODITY_CODEHASH", address(commodity), e.commodityCodehash);
        checkCode("LUMOB_GUARD_CODEHASH", address(guard), e.guardCodehash);
        require(guard.maxAgeCeiling() == e.sourceMaxAge, "source age policy mismatch");
        require(guard.maxObservationAge() == e.observationMaxAge, "observation age policy mismatch");
        console2.log("source maxAge ceiling", e.sourceMaxAge);
        console2.log("execution observation age", e.observationMaxAge);
        checkCode("LUMOB_V4_CODEHASH", address(market), e.v4Codehash);
        checkCode("LUMOB_HANDLER_CODEHASH", address(handler), e.handlerCodehash);
        checkCode("LUMOB_HOOK_CODEHASH", address(handler.hook()), e.hookCodehash);
        checkCode("LUMOB_FACTORY_CODEHASH", address(commodity.factory()), e.factoryCodehash);
        checkCode("LUMOB_FEED_CODEHASH", address(guard.feed()), e.feedCodehash);
        checkCode("LUMOB_BRIDGE_CODEHASH", commodity.bridge(), e.bridgeCodehash);
        checkCode("LUMOB_POOL_MANAGER_CODEHASH", address(handler.poolManager()), e.poolManagerCodehash);
        require(market.routeAdmin() == e.routeAdmin, "route admin mismatch");
        uint256 count = pad.releasedAssetCount();
        require(count > 0 && count <= 8, "bad release scope");
        require(count == e.assetCodehashes.length && count == e.poolCodehashes.length, "bad release scope");
        for (uint256 i; i < count; i++) {
            address asset = pad.releasedAssets(i);
            guard.validate(asset);
            checkCode(string.concat("LUMOB_ASSET_", vm.toString(i), "_CODEHASH"), asset, e.assetCodehashes[i]);
            address pool = commodity.pools(asset);
            checkCode(string.concat("LUMOB_POOL_", vm.toString(i), "_CODEHASH"), pool, e.poolCodehashes[i]);
            require(
                commodity.factory().getPool(asset, commodity.bridge(), commodity.poolFee()) == pool,
                "pool mapping changed"
            );
            (uint128 virtualQuote, uint128 graduationQuote, uint128 maxFirstBuy) = pad.quotePolicies(asset);
            console2.log("asset", asset);
            console2.log("virtualQuote", uint256(virtualQuote));
            console2.log("graduationQuote", uint256(graduationQuote));
            console2.log("maxFirstBuy", uint256(maxFirstBuy));
        }
        console2.log("review block", block.number);
        console2.log("policy hash", vm.toString(expected));
        console2.log("CONNECTIVITY CHECKED; NOT A RELEASE AUTHORIZATION");
    }

    function checkCode(string memory key, address target, bytes32 expected) private view {
        require(
            target.code.length > 0 && expected != bytes32(0) && target.codehash == expected,
            string.concat(key, " mismatch")
        );
        console2.log(key, target);
        console2.log("runtime hash", vm.toString(target.codehash));
    }
}
