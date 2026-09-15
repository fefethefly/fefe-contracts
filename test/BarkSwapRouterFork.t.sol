// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BarkSwapRouterV3} from "../src/v3/uniswap/BarkSwapRouterV3.sol";
import {IPoolManager, PoolKey, V4} from "../src/v3/uniswap/V4Types.sol";

interface IForkStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

/**
 * @dev Opt-in fork test: a real exact-input swap against the live Uniswap v4 PoolManager on
 * Robinhood Chain. Run with BARK_RUN_SWAP_FORK=1 and an explicit block, e.g.
 *
 *   BARK_RUN_SWAP_FORK=1 BARK_SWAP_FORK_BLOCK=<n> \
 *   forge test --match-path test/BarkSwapRouterFork.t.sol -vv
 *
 * The swap mutates fork state only; nothing is broadcast.
 */
contract BarkSwapRouterForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant POOL_MANAGER_CODE_HASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;

    /// ETH/Booh, fee 500, tickSpacing 1 — a live hookless pool this desk quotes.
    address constant BOOH = 0xBb0b4865e52bFAf7C368538A5Ce40f3e4B1Ff945;
    uint24 constant BOOH_FEE = 500;
    int24 constant BOOH_SPACING = 1;

    BarkSwapRouterV3 router;
    address trader = makeAddr("fork-trader");

    function setUp() public {
        if (!vm.envOr("BARK_RUN_SWAP_FORK", false)) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("BARK_SWAP_FORK_BLOCK", uint256(0));
        if (pinned == 0) {
            vm.createSelectFork(vm.envOr("BARK_SWAP_FORK_RPC", string("https://rpc.mainnet.chain.robinhood.com")));
        } else {
            vm.createSelectFork(
                vm.envOr("BARK_SWAP_FORK_RPC", string("https://rpc.mainnet.chain.robinhood.com")), pinned
            );
        }
        assertEq(block.chainid, 4663, "fork the Robinhood mainnet");
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODE_HASH, "PoolManager bytecode changed");
        router = new BarkSwapRouterV3(IPoolManager(POOL_MANAGER));
        vm.deal(trader, 10 ether);
    }

    function key() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: BOOH, fee: BOOH_FEE, tickSpacing: BOOH_SPACING, hooks: address(0)});
    }

    function testForkEthToTokenSwapSettlesAgainstLivePoolManager() public {
        // The pool must be real: native ETH paired with Booh, with liquidity to trade against.
        bytes32 id = V4.poolId(key());
        (uint160 sqrtPrice,,,) = IForkStateView(STATE_VIEW).getSlot0(id);
        uint128 liquidity = IForkStateView(STATE_VIEW).getLiquidity(id);
        assertGt(sqrtPrice, 0, "pool not initialized");
        assertGt(liquidity, 0, "pool has no liquidity");

        uint256 amountIn = 0.0005 ether;
        uint256 before = IERC20(BOOH).balanceOf(trader);
        vm.prank(trader);
        uint256 out = router.swapExactEthForToken{value: amountIn}(key(), amountIn, 0, trader, block.timestamp);
        assertGt(out, 0, "no output");
        assertEq(IERC20(BOOH).balanceOf(trader) - before, out, "trader received the tokens");
        assertEq(address(router).balance, 0, "router keeps no ETH");
        assertEq(IERC20(BOOH).balanceOf(address(router)), 0, "router keeps no tokens");
    }

    function testForkSlippageGuardRejectsWorseThanLimit() public {
        uint256 amountIn = 0.0005 ether;
        // Quote first, then demand 1 wei more than the pool can give.
        vm.prank(trader);
        uint256 out = router.swapExactEthForToken{value: amountIn}(key(), amountIn, 0, trader, block.timestamp);
        uint256 before = IERC20(BOOH).balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(BarkSwapRouterV3.SLIPPAGE.selector);
        router.swapExactEthForToken{value: amountIn}(key(), amountIn, out + 1, trader, block.timestamp);
        assertEq(IERC20(BOOH).balanceOf(trader), before, "a rejected swap must not move tokens");
    }
}
