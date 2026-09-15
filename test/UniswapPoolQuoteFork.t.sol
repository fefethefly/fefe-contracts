// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniswapInstantLaunchForkTest, ForkStandardToken, ForkPoolKey, ForkSwapHarness, IForkPositionManager, IForkStrategy} from "./UniswapInstantLaunchFork.t.sol";

struct ForkQuoteParams {
    ForkPoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

interface IForkQuoter {
    function poolManager() external view returns (address);
    function quoteExactInputSingle(ForkQuoteParams calldata params) external returns (uint256, uint256);
    function quoteExactOutputSingle(ForkQuoteParams calldata params) external returns (uint256, uint256);
}

interface IForkStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
}

/// @dev Opt-in isolated fork tests. Quotes never settle balances or send public-chain transactions.
contract UniswapPoolQuoteForkTest is UniswapInstantLaunchForkTest {
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    function checkQuoteDeployment() internal view {
        assertEq(QUOTER.codehash, bytes32(0xd707b1da8cb165e5ea35a3b4450d971eb562ec171e23492aa117036b78a868f6));
        assertEq(STATE_VIEW.codehash, bytes32(0x7d9c591e0956fd89d98feb4ffcfe8bf1f7a62bd485edd979fa21d104b49878a6));
        assertEq(IForkQuoter(QUOTER).poolManager(), POOL_MANAGER);
    }

    function testQuoterBuyAndSellMatchActualLocalSettlementWithoutChangingQuoteState() public {
        checkQuoteDeployment();
        (ForkStandardToken token, uint256 id) = create();
        (ForkPoolKey memory key,) = IForkPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(id);
        bytes32 poolId = keccak256(abi.encode(key));
        (uint160 beforePrice,,,) = IForkStateView(STATE_VIEW).getSlot0(poolId);
        uint256 beforeTokens = token.balanceOf(POOL_MANAGER);
        uint256 beforeNative = POOL_MANAGER.balance;
        (uint256 output, uint256 gasUnits) = IForkQuoter(QUOTER).quoteExactInputSingle(ForkQuoteParams(key, true, 0.01 ether, ""));
        assertGt(output, 0);
        assertGt(gasUnits, 0);
        (uint160 afterPrice,,,) = IForkStateView(STATE_VIEW).getSlot0(poolId);
        assertEq(afterPrice, beforePrice);
        assertEq(token.balanceOf(POOL_MANAGER), beforeTokens);
        assertEq(POOL_MANAGER.balance, beforeNative);

        ForkSwapHarness router = new ForkSwapHarness(POOL_MANAGER);
        address trader = makeAddr("quote-trader");
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        router.trade{value: 0.01 ether}(key, true, 0.01 ether, beforePrice / 2);
        assertEq(token.balanceOf(trader), output);
        (uint256 sellOutput,) = IForkQuoter(QUOTER).quoteExactInputSingle(ForkQuoteParams(key, false, uint128(output), ""));
        assertGt(sellOutput, 0);
        uint256 beforeExit = trader.balance;
        vm.startPrank(trader);
        token.approve(address(router), output);
        router.trade(key, false, output, beforePrice);
        vm.stopPrank();
        assertEq(trader.balance - beforeExit, sellOutput);
        assertEq(token.balanceOf(trader), 0);
    }

    function testQuoterRejectsPartialFillWhenNoNativeLiquidityExists() public {
        checkQuoteDeployment();
        (, uint256 id) = create();
        (ForkPoolKey memory key,) = IForkPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(id);
        bytes32 poolId = keccak256(abi.encode(key));
        // A fresh single-sided token pool cannot fill a token-to-ETH sell.
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("UnexpectedRevertBytes(bytes)")), abi.encodeWithSelector(bytes4(keccak256("NotEnoughLiquidity(bytes32)")), poolId)));
        IForkQuoter(QUOTER).quoteExactInputSingle(ForkQuoteParams(key, false, 1 ether, ""));
    }

    function testQuoterRejectsExactOutputBeyondAvailableSupply() public {
        checkQuoteDeployment();
        (, uint256 id) = create();
        (ForkPoolKey memory key,) = IForkPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(id);
        bytes32 poolId = keccak256(abi.encode(key));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("UnexpectedRevertBytes(bytes)")), abi.encodeWithSelector(bytes4(keccak256("NotEnoughLiquidity(bytes32)")), poolId)));
        IForkQuoter(QUOTER).quoteExactOutputSingle(ForkQuoteParams(key, true, uint128(1_000_000_001 ether), ""));
    }
}
