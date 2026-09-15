// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BarkSwapRouterV3} from "../src/v3/uniswap/BarkSwapRouterV3.sol";
import {BarkTestnetSeederV3} from "../src/v3/uniswap/BarkTestnetSeederV3.sol";
import {IPoolManager, PoolKey, V4} from "../src/v3/uniswap/V4Types.sol";

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

/**
 * @dev The exact testnet flow a wallet will run: seed a real ETH/token pool through
 * BarkTestnetSeederV3, then swap it both ways through BarkSwapRouterV3 against the live
 * PoolManager. Fork-only; nothing is broadcast.
 *
 *   BARK_RUN_SEED_FORK=1 forge test --match-path test/BarkTestnetSeederV3.t.sol -vv
 */
contract BarkTestnetSeederV3Test is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;

    BarkSwapRouterV3 router;
    BarkTestnetSeederV3 seeder;
    address trader = makeAddr("seeded-trader");

    function setUp() public {
        if (!vm.envOr("BARK_RUN_SEED_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("BARK_SWAP_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")));
        assertEq(block.chainid, 46630, "fork the Robinhood testnet");
        router = new BarkSwapRouterV3(IPoolManager(POOL_MANAGER));
        seeder = new BarkTestnetSeederV3(IPoolManager(POOL_MANAGER));
        vm.deal(address(this), 100 ether);
        vm.deal(trader, 10 ether);
    }

    function testSeederCreatesSwappablePoolAndWithdraws() public {
        uint256 supply = 1_000_000e18;
        uint256 ethIn = 0.02 ether;
        (address token, bytes32 poolId) =
            seeder.createTokenAndPool{value: ethIn}("Bark Test", "BTEST", supply, FEE, SPACING);

        (uint160 sqrtPrice,,,) = IStateView(STATE_VIEW).getSlot0(poolId);
        uint128 liquidity = IStateView(STATE_VIEW).getLiquidity(poolId);
        assertGt(sqrtPrice, 0, "pool initialized on the live manager");
        assertGt(liquidity, 0, "pool holds liquidity");

        PoolKey memory key = PoolKey(address(0), token, FEE, SPACING, address(0));
        assertEq(V4.poolId(key), poolId, "seed address the router uses matches");

        // ETH -> token through the production router
        uint256 before = IERC20(token).balanceOf(trader);
        vm.prank(trader);
        uint256 out = router.swapExactEthForToken{value: 0.005 ether}(key, 0.005 ether, 0, trader, block.timestamp);
        assertGt(out, 0, "token output");
        assertEq(IERC20(token).balanceOf(trader) - before, out);

        // token -> ETH back through the router
        vm.startPrank(trader);
        IERC20(token).approve(address(router), out);
        uint256 nativeBefore = trader.balance;
        uint256 ethOut = router.swapExactTokenForEth(key, out, 0, trader, block.timestamp);
        vm.stopPrank();
        assertGt(ethOut, 0, "ETH output");
        assertEq(trader.balance - nativeBefore, ethOut);

        // the creator can pull the seeded liquidity back out
        uint256 creatorEthBefore = address(this).balance;
        (uint256 ethBack, uint256 tokenBack) = seeder.withdraw(token);
        assertGt(ethBack, 0, "ETH returned");
        assertGt(tokenBack, 0, "tokens returned");
        assertEq(address(this).balance - creatorEthBefore, ethBack);
        assertEq(IERC20(token).balanceOf(address(this)), tokenBack);
        assertEq(IStateView(STATE_VIEW).getLiquidity(poolId), 0, "position closed");
    }

    /// @dev The seeder pays withdrawn ETH straight to its creator, which is this test contract.
    receive() external payable {}

    function testSeederRefusesMainnetChain() public {
        // The guard is checked against block.chainid, so prove it here by forking mainnet.
        vm.createSelectFork(vm.envOr("BARK_SWAP_FORK_RPC_MAINNET", string("https://rpc.mainnet.chain.robinhood.com")));
        vm.expectRevert(BarkTestnetSeederV3.WRONG_CHAIN.selector);
        new BarkTestnetSeederV3(IPoolManager(POOL_MANAGER));
    }
}
