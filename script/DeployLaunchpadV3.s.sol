// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {IPoolManager, PoolKey, V4} from "../src/v3/uniswap/V4Types.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {FefeSink} from "../src/v3/FefeSink.sol";

/**
 * Robinhood Chain mainnet (4663) deployment of the V3 launchpad stack on Uniswap v4.
 *
 *   adapter  = UniswapV4SwapAdapterV3(poolManager, routeAdmin)
 *   sink     = FefeSink(admin, adapter)                 // default treasury; buy-and-burn FEFE
 *   handler  = UniswapV4GraduationHandlerV3(poolManager, treasury)
 *   hook     = BarkHookV3(poolManager, handler)         // CREATE2, salt mined for permission bits
 *   adapter.setHandler + ETH/NVDA route
 *   pad      = LaunchpadV3(treasury, handler, adapter)
 *   handler.bind(hook, pad)
 *
 * The hook is deployed through Foundry's deterministic CREATE2 factory
 * (0x4e59b44847b379578588920cA78FbF26c0B4956C, present on Robinhood mainnet), so the salt is
 * mined against that factory, not against the broadcaster.
 *
 * Env (all optional):
 *   TREASURY      fee / protocol recipient          default: newly deployed FefeSink
 *   ROUTE_ADMIN   adapter route admin               default: broadcaster
 *   POOL_MANAGER  Uniswap v4 PoolManager            default: Robinhood mainnet
 *   SKIP_NVDA_ROUTE=true to leave the route table empty
 *
 * Dry run (fork simulation, no broadcast):
 *   forge script script/DeployLaunchpadV3.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
 *     --sender $DEPLOYER --evm-version cancun -vv
 * Broadcast:
 *   source .env.deployer && forge script script/DeployLaunchpadV3.s.sol \
 *     --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $DEPLOYER_KEY \
 *     --evm-version cancun --broadcast -vv
 */
contract DeployLaunchpadV3 is Script {
    // CREATE2_FACTORY (0x4e59b44847b379578588920cA78FbF26c0B4956C) is inherited from forge-std.
    address constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // Most active hookless ETH/NVDA v4 pool on Robinhood mainnet (fee 500, tick spacing 10).
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    uint24 constant NVDA_FEE = 500;
    int24 constant NVDA_TICK_SPACING = 10;

    function run() external {
        require(
            block.chainid == 4663,
            string.concat(
                "DeployLaunchpadV3 is Robinhood mainnet 4663 only; this chain is ",
                vm.toString(block.chainid),
                ". From contracts/: forge script script/DeployLaunchpadV3.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --evm-version cancun -vv"
            )
        );
        address broadcaster = msg.sender;
        address routeAdmin = vm.envOr("ROUTE_ADMIN", broadcaster);
        IPoolManager pm = IPoolManager(vm.envOr("POOL_MANAGER", RH_POOL_MANAGER));
        bool skipRoute = vm.envOr("SKIP_NVDA_ROUTE", false);
        require(address(pm).code.length > 0, "PoolManager has no code on this chain");
        require(CREATE2_FACTORY.code.length > 0, "CREATE2 factory missing; hook salt mining assumes it");

        vm.startBroadcast();
        UniswapV4SwapAdapterV3 adapter = new UniswapV4SwapAdapterV3(pm, broadcaster);
        FefeSink sink = new FefeSink(broadcaster, adapter);
        address treasury = vm.envOr("TREASURY", address(sink));

        UniswapV4GraduationHandlerV3 handler = new UniswapV4GraduationHandlerV3(pm, treasury);

        (bytes32 salt, address predicted) = _mineHookSalt(pm, address(handler));
        BarkHookV3 hook = new BarkHookV3{salt: salt}(pm, address(handler));
        require(address(hook) == predicted, "hook address mismatch");

        adapter.setHandler(handler);
        if (!skipRoute && NVDA.code.length > 0) {
            adapter.setRoute(NATIVE, NVDA, PoolKey(NATIVE, NVDA, NVDA_FEE, NVDA_TICK_SPACING, address(0)));
        }
        if (routeAdmin != broadcaster) adapter.setRouteAdmin(routeAdmin);

        LaunchpadV3 pad = new LaunchpadV3(treasury, handler, adapter);
        handler.bind(hook, address(pad));
        vm.stopBroadcast();

        console2.log("chainId:", block.chainid);
        console2.log("PoolManager:", address(pm));
        console2.log("FefeSink:", address(sink));
        console2.log("Treasury:", treasury);
        console2.log("RouteAdmin:", routeAdmin);
        console2.log("UniswapV4GraduationHandlerV3:", address(handler));
        console2.log("BarkHookV3:", address(hook));
        console2.log("  hook salt:", vm.toString(salt));
        console2.log("UniswapV4SwapAdapterV3:", address(adapter));
        console2.log("LaunchpadV3:", address(pad));
        console2.log("  TOKEN_INIT_CODE_HASH:", vm.toString(pad.TOKEN_INIT_CODE_HASH()));
        console2.log("  CREATION_FEE (wei):", pad.CREATION_FEE());
        console2.log("web env: NEXT_PUBLIC_LAUNCHPAD_V3_ADDRESS=%s", address(pad));
    }

    function hookFlags() internal pure returns (uint160) {
        return V4.BEFORE_INITIALIZE_FLAG | V4.BEFORE_SWAP_FLAG | V4.AFTER_SWAP_FLAG | V4.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | V4.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    /// Mines a CREATE2 salt (against the deterministic factory) whose address carries exactly the hook's permission bits.
    function _mineHookSalt(IPoolManager pm, address handler) internal pure returns (bytes32 salt, address predicted) {
        bytes32 initHash = keccak256(abi.encodePacked(type(BarkHookV3).creationCode, abi.encode(pm, handler)));
        uint160 want = hookFlags();
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initHash)))));
            if ((uint160(predicted) & V4.ALL_HOOK_MASK) == want) return (salt, predicted);
        }
        revert("no hook salt found");
    }
}
