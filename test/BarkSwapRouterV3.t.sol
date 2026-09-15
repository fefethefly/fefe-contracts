// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BarkSwapRouterV3} from "../src/v3/uniswap/BarkSwapRouterV3.sol";
import {IPoolManager, PoolKey} from "../src/v3/uniswap/V4Types.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract RouterToken is ERC20 {
    uint16 public feeBps;
    address public feeSink;

    constructor() ERC20("Router Test", "RT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint16 bps, address sink) external {
        feeBps = bps;
        feeSink = sink;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeBps > 0 && from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, feeSink, fee);
            super._update(from, to, value - fee);
            return;
        }
        super._update(from, to, value);
    }
}

/// @dev Router logic against a PoolManager stand-in: exact input, settle amounts, slippage, key guards.
contract BarkSwapRouterV3Test is Test {
    uint256 constant AMOUNT = 1 ether;
    uint256 constant RATE = 2e18; // 1 ETH in -> 2 RT out

    MockPoolManager manager;
    BarkSwapRouterV3 router;
    RouterToken token;
    PoolKey key;
    address trader = makeAddr("trader");
    address recipient = makeAddr("recipient");

    function setUp() public {
        manager = new MockPoolManager();
        router = new BarkSwapRouterV3(IPoolManager(address(manager)));
        token = new RouterToken();
        key = PoolKey({currency0: address(0), currency1: address(token), fee: 3000, tickSpacing: 60, hooks: address(0)});
        // The pool needs inventory to pay out, and the trader needs ETH.
        vm.deal(address(manager), 1_000 ether);
        token.mint(address(manager), 1_000_000e18);
        vm.deal(trader, 100 ether);
    }

    function testEthInTokenOutPaysRecipientAndKeepsNoFunds() public {
        uint256 before = token.balanceOf(recipient);
        vm.prank(trader);
        uint256 out = router.swapExactEthForToken{value: 1 ether}(key, 1 ether, 0, recipient, block.timestamp);
        assertEq(out, (AMOUNT * RATE) / 1e18, "quoted output");
        assertEq(token.balanceOf(recipient) - before, out, "recipient received the tokens");
        assertEq(address(router).balance, 0, "router keeps no ETH");
        assertEq(token.balanceOf(address(router)), 0, "router keeps no tokens");
    }

    function testExcessEthIsRefundedToCaller() public {
        uint256 before = trader.balance;
        vm.prank(trader);
        router.swapExactEthForToken{value: 3 ether}(key, 1 ether, 0, recipient, block.timestamp);
        assertEq(before - trader.balance, 1 ether, "only the quoted input was spent");
    }

    function testSlippageIsEnforcedOnChain() public {
        uint256 tooMuch = (AMOUNT * RATE) / 1e18 + 1;
        vm.prank(trader);
        vm.expectRevert(BarkSwapRouterV3.SLIPPAGE.selector);
        router.swapExactEthForToken{value: 1 ether}(key, 1 ether, tooMuch, recipient, block.timestamp);
    }

    function testExpiredDeadlineReverts() public {
        vm.warp(1_000);
        vm.prank(trader);
        vm.expectRevert(BarkSwapRouterV3.EXPIRED.selector);
        router.swapExactEthForToken{value: 1 ether}(key, 1 ether, 0, recipient, 999);
    }

    function testTokenInEthOutPaysNativeToRecipient() public {
        uint256 amountIn = 100e18;
        token.mint(trader, amountIn);
        vm.prank(trader);
        token.approve(address(router), amountIn);
        uint256 nativeBefore = recipient.balance;
        vm.prank(trader);
        uint256 out = router.swapExactTokenForEth(key, amountIn, 0, recipient, block.timestamp);
        assertEq(token.allowance(trader, address(router)), 0, "the pull used the approval");
        assertEq(token.balanceOf(trader), 0, "the input left the trader");
        assertEq(out, (amountIn * RATE) / 1e18);
        assertEq(recipient.balance - nativeBefore, out, "recipient received ETH");
        assertEq(token.balanceOf(address(router)), 0);
    }

    function testHookedPoolIsRejected() public {
        PoolKey memory hooked = key;
        hooked.hooks = makeAddr("hook");
        vm.prank(trader);
        vm.expectRevert(BarkSwapRouterV3.HOOKED_POOL.selector);
        router.swapExactEthForToken{value: 1 ether}(hooked, 1 ether, 0, recipient, block.timestamp);
    }

    function testNonNativeQuotedPoolIsRejected() public {
        PoolKey memory pair = PoolKey({
            currency0: address(0x1111111111111111111111111111111111111111),
            currency1: address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(trader);
        vm.expectRevert(BarkSwapRouterV3.ONLY_NATIVE_QUOTED.selector);
        router.swapExactEthForToken{value: 1 ether}(pair, 1 ether, 0, recipient, block.timestamp);
    }

    function testPoolKeyGuardsRejectNonDeskPools() public {
        // Native ETH is the lowest address, so a pool with native as currency1 is not a desk route.
        PoolKey memory tokenFirst = PoolKey({
            currency0: address(token),
            currency1: address(0),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        PoolKey memory badFee = PoolKey({
            currency0: address(0),
            currency1: address(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: address(0)
        });
        PoolKey memory badSpacing = PoolKey({
            currency0: address(0),
            currency1: address(token),
            fee: 3000,
            tickSpacing: 0,
            hooks: address(0)
        });
        vm.startPrank(trader);
        vm.expectRevert(BarkSwapRouterV3.ONLY_NATIVE_QUOTED.selector);
        router.swapExactEthForToken{value: 1 ether}(tokenFirst, 1 ether, 0, recipient, block.timestamp);
        vm.expectRevert(BarkSwapRouterV3.BAD_KEY.selector);
        router.swapExactEthForToken{value: 1 ether}(badFee, 1 ether, 0, recipient, block.timestamp);
        vm.expectRevert(BarkSwapRouterV3.BAD_KEY.selector);
        router.swapExactEthForToken{value: 1 ether}(badSpacing, 1 ether, 0, recipient, block.timestamp);
        vm.stopPrank();
    }

    function testFeeOnTransferInputCannotHalfFill() public {
        uint256 amountIn = 100e18;
        token.mint(trader, amountIn);
        token.setFee(100, makeAddr("feeSink")); // 1% tax on transfer
        vm.startPrank(trader);
        token.approve(address(router), amountIn);
        vm.expectRevert(BarkSwapRouterV3.BAD_SETTLE.selector);
        router.swapExactTokenForEth(key, amountIn, 0, recipient, block.timestamp);
        vm.stopPrank();
    }

    function testOnlyPoolManagerCanCallBack() public {
        vm.expectRevert(BarkSwapRouterV3.ONLY_POOL_MANAGER.selector);
        router.unlockCallback(abi.encode(uint8(1), key, recipient, uint256(1), uint256(0)));
    }

    function testStrayNativeTransferIsRejected() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok,) = address(router).call{value: 1 wei}("");
        assertFalse(ok, "the router must not accept stray ETH");
    }
}
