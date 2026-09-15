// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "../src/v3/uniswap/V4Types.sol";
import {BarkSwapRouterV3} from "../src/v3/uniswap/BarkSwapRouterV3.sol";
import {BarkTestnetSeederV3} from "../src/v3/uniswap/BarkTestnetSeederV3.sol";

/**
 * Deploys the swap-desk execution stack.
 *
 *   router  = BarkSwapRouterV3(poolManager)   // every chain: exact-input hookless ETH/token swaps
 *   seeder  = BarkTestnetSeederV3(poolManager) // testnet only; its constructor reverts on 4663
 *
 * Env:
 *   POOL_MANAGER   Uniswap v4 PoolManager   default: 0x8366a39CC670B4001A1121B8F6A443A643e40951 (both chains)
 *   ROUTER_ONLY    true to skip the testnet seeder
 *   RPC            chain to deploy on       default: Robinhood testnet
 *
 * Dry run (no broadcast):
 *   forge script script/DeploySwapDesk.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com \
 *     --sender $DEPLOYER --evm-version cancun -vv
 * Broadcast:
 *   source .env.deployer && forge script script/DeploySwapDesk.s.sol \
 *     --rpc-url https://rpc.testnet.chain.robinhood.com --private-key $DEPLOYER_KEY \
 *     --evm-version cancun --broadcast -vv
 *
 * After broadcasting, copy both addresses plus the runtime code hashes into the web env so the
 * swap desk can verify the deployment before it builds any transaction.
 */
contract DeploySwapDesk is Script {
    address constant DEFAULT_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        bool routerOnly = vm.envOr("ROUTER_ONLY", false);

        vm.startBroadcast();
        BarkSwapRouterV3 router = new BarkSwapRouterV3(IPoolManager(poolManager));
        console2.log("chainId", block.chainid);
        console2.log("poolManager", poolManager);
        console2.log("BarkSwapRouterV3", address(router));
        console2.logBytes32(address(router).codehash);

        if (!routerOnly) {
            BarkTestnetSeederV3 seeder = new BarkTestnetSeederV3(IPoolManager(poolManager));
            console2.log("BarkTestnetSeederV3", address(seeder));
            console2.logBytes32(address(seeder).codehash);
        }
        vm.stopBroadcast();
    }
}
