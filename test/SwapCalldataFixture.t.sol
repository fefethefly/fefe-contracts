// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BarkSwapRouterV3} from "../src/v3/uniswap/BarkSwapRouterV3.sol";
import {PoolKey} from "../src/v3/uniswap/V4Types.sol";

/**
 * @dev Locks the front-end ABI against the contract: the calldata in the fixture is produced by
 * `web/lib/world/swap-execution.ts` (web/gen-fixture.mjs) and must decode into exactly the
 * arguments the router expects. A field reorder or type change on either side fails here
 * instead of in a user's wallet.
 *
 * Regenerate after changing the encoder:
 *   cd web && node gen-fixture.mjs
 */
contract SwapCalldataFixtureTest is Test {
    function testBuyCalldataMatchesRouterAbi() public view {
        string memory json = vm.readFile("test/fixtures/swap-calldata.json");
        bytes memory data = vm.parseJsonBytes(json, ".buy.calldata");
        assertEq(bytes4(data), BarkSwapRouterV3.swapExactEthForToken.selector, "selector");
        (PoolKey memory key, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline) =
            abi.decode(sliceAfterSelector(data), (PoolKey, uint256, uint256, address, uint256));
        assertEq(key.currency0, address(0), "native in");
        assertEq(key.currency1, vm.parseJsonAddress(json, ".token"), "token out");
        assertEq(uint256(key.fee), 3000);
        assertEq(int256(key.tickSpacing), 60);
        assertEq(key.hooks, address(0), "hookless only");
        assertEq(amountIn, 1e15, "amount in");
        assertEq(minOut, 995000, "minimum out");
        assertEq(recipient, vm.parseJsonAddress(json, ".recipient"));
        assertEq(deadline, 1_800_000_000);
    }

    function testSellCalldataMatchesRouterAbi() public view {
        string memory json = vm.readFile("test/fixtures/swap-calldata.json");
        bytes memory data = vm.parseJsonBytes(json, ".sell.calldata");
        assertEq(bytes4(data), BarkSwapRouterV3.swapExactTokenForEth.selector, "selector");
        (PoolKey memory key, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline) =
            abi.decode(sliceAfterSelector(data), (PoolKey, uint256, uint256, address, uint256));
        assertEq(key.currency1, vm.parseJsonAddress(json, ".token"), "token in");
        assertEq(amountIn, 123_456_789);
        assertEq(minOut, 42);
        assertEq(recipient, vm.parseJsonAddress(json, ".recipient"));
        assertEq(deadline, 1_800_000_001);
    }

    /// @dev The pool id the encoder implies must match keccak256(abi.encode(key)) — the desk refuses mismatches.
    function testFixturePoolIdMatchesTheKey() public view {
        string memory json = vm.readFile("test/fixtures/swap-calldata.json");
        bytes memory data = vm.parseJsonBytes(json, ".buy.calldata");
        (PoolKey memory key, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline) =
            abi.decode(sliceAfterSelector(data), (PoolKey, uint256, uint256, address, uint256));
        assertEq(keccak256(abi.encode(key)), vm.parseJsonBytes32(json, ".poolId"), "pool identity");
        // Keep every decoded field referenced so the whole tuple is proven decodable.
        assertEq(amountIn, 1e15);
        assertEq(minOut, 995000);
        assertEq(recipient, vm.parseJsonAddress(json, ".recipient"));
        assertEq(deadline, 1_800_000_000);
    }

    function sliceAfterSelector(bytes memory data) private pure returns (bytes memory out) {
        require(data.length > 4, "calldata too short");
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) out[i] = data[i + 4];
    }
}
