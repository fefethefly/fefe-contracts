// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommodityAdapterFixture, CommodityTestToken, CommodityTestFeed} from "./CommoditySwapAdapterV3.t.sol";
import {MarketSwapDispatcherV3, IMarketRouteAdapterV3} from "../src/v3/uniswap/MarketSwapDispatcherV3.sol";
import {CommodityOracleGuardV3} from "../src/v3/uniswap/CommodityOracleGuardV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, V4} from "../src/v3/uniswap/V4Types.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";

contract DispatcherTestMarket is IMarketRouteAdapterV3 {
    CommodityTestFeed public mutationFeed;

    function setMutation(CommodityTestFeed feed_) external {
        mutationFeed = feed_;
    }
    mapping(bytes32 => bool) private routes;
    uint8 public mode;
    bool public reentryBlocked;

    function key(address a, address b) private pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }

    function setRoute(address a, address b) external {
        routes[key(a, b)] = true;
        routes[key(b, a)] = true;
    }

    function hasRoute(address a, address b) external view returns (bool) {
        return routes[key(a, b)];
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function swapExactIn(address a, address b, uint256 amount, uint256, address recipient)
        external
        payable
        returns (uint256 out)
    {
        require(mode != 4, "venue failure");
        uint256 spent = mode == 1 ? amount / 2 : amount;
        if (a != address(0)) IERC20(a).transferFrom(msg.sender, address(this), spent);
        if (mode == 5) {
            try MarketSwapDispatcherV3(msg.sender).swapExactIn(a, b, amount, 1, recipient) {
                reentryBlocked = false;
            } catch {
                reentryBlocked = true;
            }
        }
        out = amount;
        if (b == address(0)) {
            (bool ok,) = recipient.call{value: out}("");
            require(ok);
        } else {
            IERC20(b).transfer(recipient, out);
        }
        if (mode == 6) mutationFeed.setPaused(true);
        if (mode == 2) out++;
        if (mode == 3) out = 0;
    }
    receive() external payable {}
}

/// Settlement-only mock: exercises the real V4 adapter ABI, not real pool pricing or hooks.
contract DispatcherTestPoolManager {
    address private active;
    address private synced;
    uint256 private beforeBalance;

    function unlock(bytes calldata data) external returns (bytes memory) {
        require(active == address(0));
        active = msg.sender;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        active = address(0);
        return result;
    }

    function swap(PoolKey memory, SwapParams memory params, bytes calldata) external view returns (int256) {
        require(msg.sender == active);
        int128 amount = int128(-params.amountSpecified);
        return params.zeroForOne ? V4.toBalanceDelta(-amount, amount) : V4.toBalanceDelta(amount, -amount);
    }

    function sync(address token) external {
        require(msg.sender == active);
        synced = token;
        beforeBalance = IERC20(token).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(msg.sender == active);
        if (msg.value > 0) return msg.value;
        paid = IERC20(synced).balanceOf(address(this)) - beforeBalance;
    }

    function take(address asset, address recipient, uint256 amount) external {
        require(msg.sender == active);
        if (asset == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok);
        } else {
            IERC20(asset).transfer(recipient, amount);
        }
    }
    receive() external payable {}
}

contract MarketSwapDispatcherV3Test is CommodityAdapterFixture {
    DispatcherTestMarket market;
    MarketSwapDispatcherV3 dispatcher;
    CommodityTestToken meme;

    function setUp() public override {
        super.setUp();
        market = new DispatcherTestMarket();
        dispatcher = new MarketSwapDispatcherV3(adapter, market);
        meme = new CommodityTestToken("MEME", 18);
        market.setRoute(address(corn), address(meme));
        market.setRoute(address(0), address(meme));
        meme.mint(address(market), 1000 ether);
        corn.mint(address(market), 1000 ether);
        meme.mint(alice, 100 ether);
        vm.deal(address(market), 1000 ether);
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        corn.approve(address(dispatcher), type(uint256).max);
        meme.approve(address(dispatcher), type(uint256).max);
        vm.stopPrank();
    }

    function trade(address a, address b, uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.prank(alice);
        return dispatcher.swapExactIn(a, b, amount, minOut, bob);
    }

    function test_selectionKeepsCommodityPriorityWithoutFailureFallback() public {
        market.setRoute(address(corn), address(coffee));
        coffee.mint(address(market), 100 ether);
        assertEq(dispatcher.selectedAdapter(address(corn), address(coffee)), address(adapter));
        assertEq(dispatcher.selectedAdapter(address(corn), address(meme)), address(market));
        assertEq(dispatcher.selectedAdapter(address(123), address(meme)), address(0));
        coffeePool.setMode(1);
        vm.expectRevert("second hop failed");
        trade(address(corn), address(coffee), 1 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(coffee.balanceOf(bob), 0);
    }

    function test_actualCommodityAdapterAndMarketAdapterClearOnlyTheirAllowances() public {
        assertEq(trade(address(corn), address(coffee), 2 ether, 2 ether), 2 ether);
        assertEq(corn.allowance(address(dispatcher), address(adapter)), 0);
        assertEq(corn.allowance(address(dispatcher), address(market)), 0);
        assertEq(trade(address(corn), address(meme), 3 ether, 3 ether), 3 ether);
        assertEq(corn.allowance(address(dispatcher), address(market)), 0);
        assertEq(corn.balanceOf(address(dispatcher)), 0);
        assertEq(meme.balanceOf(bob), 3 ether);
    }

    function test_nativeInputAndOutputPreserveDispatcherDust() public {
        vm.deal(address(dispatcher), 7);
        uint256 beforeBob = bob.balance;
        vm.prank(alice);
        assertEq(dispatcher.swapExactIn{value: 1 ether}(address(0), address(meme), 1 ether, 1 ether, bob), 1 ether);
        assertEq(trade(address(meme), address(0), 2 ether, 2 ether), 2 ether);
        assertEq(bob.balance - beforeBob, 2 ether);
        assertEq(address(dispatcher).balance, 7);
    }

    function test_pausedCommodityCannotEscapeThroughMemeMarketRoute() public {
        feed.setPaused(true);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        trade(address(corn), address(meme), 1 ether, 1);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        trade(address(meme), address(corn), 1 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(meme.balanceOf(alice), 100 ether);
    }

    function test_incompleteSpendAndDishonestOutputRevertBalancesAndApproval() public {
        corn.mint(address(dispatcher), 7);
        for (uint8 mode = 1; mode <= 4; mode++) {
            market.setMode(mode);
            vm.expectRevert();
            trade(address(corn), address(meme), 1 ether, 1);
            assertEq(corn.balanceOf(alice), 100 ether);
            assertEq(corn.balanceOf(address(dispatcher)), 7);
            assertEq(meme.balanceOf(bob), 0);
            assertEq(corn.allowance(address(dispatcher), address(market)), 0);
        }
    }

    function test_marketCallbackCannotReenterDispatcher() public {
        market.setMode(5);
        trade(address(corn), address(meme), 1 ether, 1);
        assertTrue(market.reentryBlocked());
    }

    function test_sourcePauseDuringMarketExecutionRollsBackWholeSwap() public {
        market.setMutation(feed);
        market.setMode(6);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        trade(address(corn), address(meme), 1 ether, 1);
        assertFalse(feed.paused());
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(meme.balanceOf(bob), 0);
    }

    function test_minOutProtectsRecipientEvenWhenVenueIgnoresIt() public {
        vm.expectRevert(MarketSwapDispatcherV3.SLIPPAGE.selector);
        trade(address(corn), address(meme), 1 ether, 2 ether);
        assertEq(corn.balanceOf(alice), 100 ether);
    }

    function test_invalidValueRecipientAndChainRejectWithoutTransfer() public {
        vm.expectRevert(MarketSwapDispatcherV3.BAD_VALUE.selector);
        trade(address(corn), address(meme), 1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(MarketSwapDispatcherV3.BAD_VALUE.selector);
        dispatcher.swapExactIn(address(corn), address(meme), 1 ether, 1, address(adapter));
        vm.prank(alice);
        vm.expectRevert(MarketSwapDispatcherV3.BAD_VALUE.selector);
        dispatcher.swapExactIn{value: 1}(address(corn), address(meme), 1 ether, 1, bob);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(MarketSwapDispatcherV3.WRONG_CHAIN.selector);
        trade(address(corn), address(meme), 1 ether, 1);
    }

    function test_realV4AdapterSettlementWorksThroughDispatcher() public {
        DispatcherTestPoolManager pm = new DispatcherTestPoolManager();
        UniswapV4SwapAdapterV3 v4 = new UniswapV4SwapAdapterV3(IPoolManager(address(pm)), address(this));
        (address lo, address hi) =
            address(corn) < address(meme) ? (address(corn), address(meme)) : (address(meme), address(corn));
        v4.setRoute(address(corn), address(meme), PoolKey(lo, hi, 500, 10, address(0)));
        MarketSwapDispatcherV3 router = new MarketSwapDispatcherV3(adapter, IMarketRouteAdapterV3(address(v4)));
        corn.mint(address(pm), 100 ether);
        meme.mint(address(pm), 100 ether);
        vm.startPrank(alice);
        corn.approve(address(router), 2 ether);
        meme.approve(address(router), 3 ether);
        assertEq(router.swapExactIn(address(corn), address(meme), 2 ether, 2 ether, bob), 2 ether);
        assertEq(router.swapExactIn(address(meme), address(corn), 3 ether, 3 ether, bob), 3 ether);
        vm.stopPrank();
        assertEq(corn.allowance(address(router), address(v4)), 0);
        assertEq(meme.allowance(address(router), address(v4)), 0);
        assertEq(corn.balanceOf(address(v4)), 0);
        assertEq(meme.balanceOf(address(v4)), 0);
    }

    function test_feeVaultThroughDispatcherToActualHolderClaim() public {
        MemeTokenV3 token = new MemeTokenV3();
        address[] memory rewards = new address[](1);
        rewards[0] = address(coffee);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        FeeVaultV3 vault = new FeeVaultV3(
            token,
            address(corn),
            payable(address(this)),
            address(this),
            dispatcher,
            FeeVaultV3.Split(0, 10000, 0, 0),
            rewards,
            weights
        );
        vault.setCurve(address(this));
        token.initialize("LUMOB", "LUM", 0, 0, address(this), address(vault), rewards, new address[](0));
        token.transfer(bob, 100 ether);
        corn.mint(address(vault), 10 ether);
        vault.onFee(10 ether);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 10 ether;
        feed.setPaused(true);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        vault.buyBasket(mins);
        assertEq(vault.basketPending(), 10 ether);
        assertEq(token.totalDistributed(address(coffee)), 0);
        feed.setPaused(false);
        vault.buyBasket(mins);
        feed.setPaused(true);
        vm.prank(bob);
        token.claimRewards();
        assertEq(coffee.balanceOf(bob), 10 ether);
        assertEq(token.totalClaimed(address(coffee)), 10 ether);
        assertEq(corn.balanceOf(address(dispatcher)), 0);
        assertEq(corn.allowance(address(dispatcher), address(adapter)), 0);
    }
}
