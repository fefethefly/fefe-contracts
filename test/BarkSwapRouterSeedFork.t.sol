// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BarkSwapRouterV3} from "../src/v3/uniswap/BarkSwapRouterV3.sol";
import {IPoolManager, PoolKey, ModifyLiquidityParams, V4} from "../src/v3/uniswap/V4Types.sol";

contract TestnetSeedToken is ERC20 {
    constructor() ERC20("Bark Test", "BTEST") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/**
 * @dev Builds a real ETH/token v4 pool on a Robinhood testnet fork: initialize at a 1:1 price and
 * deposit full-range liquidity into the live PoolManager, then swap through BarkSwapRouterV3.
 * This is the same sequence the deploy script runs, checked before spending testnet gas.
 *
 * BARK_RUN_SEED_FORK=1 forge test --match-path test/BarkSwapRouterSeedFork.t.sol -vv
 */
contract BarkSwapRouterSeedForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    uint160 constant Q96 = 0x1000000000000000000000000; // 2^96: price 1:1

    BarkSwapRouterV3 router;
    TestnetSeedToken token;
    PoolKey key;
    address trader = makeAddr("seed-trader");

    function setUp() public {
        if (!vm.envOr("BARK_RUN_SEED_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("BARK_SWAP_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")));
        assertEq(block.chainid, 46630, "fork the Robinhood testnet");
        router = new BarkSwapRouterV3(IPoolManager(POOL_MANAGER));
        token = new TestnetSeedToken();
        key = PoolKey({currency0: address(0), currency1: address(token), fee: 3000, tickSpacing: 60, hooks: address(0)});
        vm.deal(address(this), 100 ether);
        vm.deal(trader, 10 ether);
    }

    function testSeededPoolIsSwappableBothWays() public {
        uint256 ethSide = 0.01 ether;
        uint256 tokenSide = 20_000e18;

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        manager.initialize(key, Q96);
        token.approve(POOL_MANAGER, tokenSide);
        (uint256 used0, uint256 used1) =
            abi.decode(manager.unlock(abi.encode(key, ethSide, tokenSide)), (uint256, uint256));
        assertGt(used0, 0, "ETH side deposited");
        assertGt(used1, 0, "token side deposited");

        // ETH -> token
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        uint256 out = router.swapExactEthForToken{value: 0.001 ether}(key, 0.001 ether, 0, trader, block.timestamp);
        assertGt(out, 0, "token output");
        assertEq(token.balanceOf(trader) - before, out, "trader got tokens");

        // token -> ETH
        uint256 nativeBefore = trader.balance;
        vm.startPrank(trader);
        token.approve(address(router), out);
        uint256 ethOut = router.swapExactTokenForEth(key, out, 0, trader, block.timestamp);
        vm.stopPrank();
        assertGt(ethOut, 0, "ETH output");
        assertEq(trader.balance - nativeBefore, ethOut, "trader got ETH back");
        assertEq(address(router).balance, 0, "router keeps no ETH");
        assertEq(token.balanceOf(address(router)), 0, "router keeps no tokens");
    }

    // ─── PoolManager callback used only by this seeding helper ─────────────────
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "only pool manager");
        (PoolKey memory poolKey, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));
        uint256 liq = Math.min(amount0, amount1);
        liq -= liq / 1_000_000 + 1;
        (int256 delta,) = IPoolManager(POOL_MANAGER).modifyLiquidity(
            poolKey,
            ModifyLiquidityParams(
                V4.minUsableTick(poolKey.tickSpacing),
                V4.maxUsableTick(poolKey.tickSpacing),
                int256(liq),
                bytes32(0)
            ),
            ""
        );
        int128 d0 = V4.amount0(delta);
        int128 d1 = V4.amount1(delta);
        require(d0 <= 0 && d1 <= 0, "unexpected delta");
        if (d0 < 0) IPoolManager(POOL_MANAGER).settle{value: uint128(-d0)}();
        if (d1 < 0) {
            IPoolManager(POOL_MANAGER).sync(poolKey.currency1);
            IERC20(poolKey.currency1).transfer(POOL_MANAGER, uint128(-d1));
            IPoolManager(POOL_MANAGER).settle();
        }
        return abi.encode(uint256(uint128(-d0)), uint256(uint128(-d1)));
    }

    receive() external payable {}
}
