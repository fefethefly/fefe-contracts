// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {PoolKey} from "../src/v3/uniswap/V4Types.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";

/**
 * Registers (or overwrites) one ETH/stock route on the V3 swap adapter. Run by the route admin.
 *
 *   ADAPTER=0x... STOCK=0x... FEE=500 TICK_SPACING=10 [HOOKS=0x0] \
 *   forge script script/SetRouteV3.s.sol --rpc-url $RPC --private-key $ROUTE_ADMIN_KEY --broadcast -vv
 *
 * Pick the most liquid hookless v4 pool for the stock (see docs/research/UNISWAP-*-POOLS-*.json).
 */
contract SetRouteV3 is Script {
    function run() external {
        UniswapV4SwapAdapterV3 adapter = UniswapV4SwapAdapterV3(payable(vm.envAddress("ADAPTER")));
        address stock = vm.envAddress("STOCK");
        uint24 fee = uint24(vm.envUint("FEE"));
        int24 tickSpacing = int24(int256(vm.envUint("TICK_SPACING")));
        address hooks = vm.envOr("HOOKS", address(0));
        require(stock != NATIVE && stock.code.length > 0, "STOCK must be a deployed ERC20");

        (address c0, address c1) = NATIVE < stock ? (NATIVE, stock) : (stock, NATIVE);
        vm.startBroadcast();
        adapter.setRoute(NATIVE, stock, PoolKey(c0, c1, fee, tickSpacing, hooks));
        vm.stopBroadcast();
        console2.log("route set: ETH <->", stock);
        console2.log("  fee / tickSpacing / hooks:", fee, uint256(int256(tickSpacing)));
        console2.log("  hooks:", hooks);
    }
}
