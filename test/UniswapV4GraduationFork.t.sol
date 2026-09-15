// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, V4} from "../src/v3/uniswap/V4Types.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";

/// Test-only trader that settles a single v4 swap for an EOA (any router would do the same).
contract ForkTrader is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function trade(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external payable returns (int256) {
        uint256 before = address(this).balance - msg.value;
        int256 delta = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountSpecified, msg.sender)), (int256));
        uint256 refund = address(this).balance - before;
        if (refund > 0) payable(msg.sender).transfer(refund);
        return delta;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (PoolKey memory key, bool zeroForOne, int256 amount, address trader) =
            abi.decode(data, (PoolKey, bool, int256, address));
        int256 delta = pm.swap(
            key, SwapParams(zeroForOne, amount, zeroForOne ? V4.MIN_SQRT_PRICE + 1 : V4.MAX_SQRT_PRICE - 1), ""
        );
        _settle(key.currency0, V4.amount0(delta), trader);
        _settle(key.currency1, V4.amount1(delta), trader);
        return abi.encode(delta);
    }

    function _settle(address currency, int128 d, address trader) internal {
        if (d < 0) {
            uint256 owed = uint128(-d);
            if (currency == NATIVE) {
                pm.settle{value: owed}();
            } else {
                pm.sync(currency);
                require(IERC20(currency).transferFrom(trader, address(pm), owed));
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(currency, trader, uint128(d));
        }
    }

    receive() external payable {}
}

/**
 * End-to-end on a pinned Robinhood Chain fork: create → buy to graduation → real Uniswap v4
 * pool with BarkHookV3 → trade both directions through a plain router → hook fees land in
 * the vault in ETH → basket buys real NVDA through the live ETH/NVDA pool → buyback burns →
 * locked-LP fees flow to the treasury.
 *
 *   BARK_RUN_UNISWAP_FORK=true forge test --match-contract UniswapV4GraduationForkTest \
 *     --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((HEAD-30)) \
 *     --evm-version cancun --compute-units-per-second 40 --fork-retries 3 -vv
 *
 * Pin a recent block: the public RPC only keeps recent state and answers older blocks with
 * "metadata is not found". Last green run: block 56424339 (2026-09-07).
 */
contract UniswapV4GraduationForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    // Most active ETH/NVDA pool at head 56,411,602: fee 500, tickSpacing 10, hookless (809 swaps / 300k blocks).
    uint24 constant NVDA_FEE = 500;
    int24 constant NVDA_TS = 10;

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    UniswapV4GraduationHandlerV3 handler;
    BarkHookV3 hook;
    UniswapV4SwapAdapterV3 adapter;
    LaunchpadV3 pad;
    ForkTrader trader;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        if (!vm.envOr("BARK_RUN_UNISWAP_FORK", false)) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "pass the pinned Robinhood fork");
        assertEq(
            POOL_MANAGER.codehash, bytes32(0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626)
        );
        handler = new UniswapV4GraduationHandlerV3(pm, treasury);
        hook = _deployHook();
        adapter = new UniswapV4SwapAdapterV3(pm, address(this));
        adapter.setHandler(handler);
        adapter.setRoute(NATIVE, NVDA, PoolKey(NATIVE, NVDA, NVDA_FEE, NVDA_TS, address(0)));
        pad = new LaunchpadV3(treasury, handler, adapter);
        handler.bind(hook, address(pad));
        trader = new ForkTrader(pm);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /// Mines a CREATE2 salt whose address carries exactly the hook's permission bits.
    function _deployHook() internal returns (BarkHookV3) {
        bytes memory initCode = abi.encodePacked(type(BarkHookV3).creationCode, abi.encode(pm, address(handler)));
        bytes32 initHash = keccak256(initCode);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if ((uint160(predicted) & V4.ALL_HOOK_MASK) == hook_flags()) {
                BarkHookV3 h = new BarkHookV3{salt: salt}(pm, address(handler));
                assertEq(address(h), predicted);
                return h;
            }
        }
        revert("no salt");
    }

    function hook_flags() internal pure returns (uint160) {
        return V4.BEFORE_INITIALIZE_FLAG | V4.BEFORE_SWAP_FLAG | V4.AFTER_SWAP_FLAG | V4.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | V4.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function params() internal view returns (LaunchpadV3.Launch memory p) {
        address[] memory basket = new address[](1);
        basket[0] = NVDA;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        p = LaunchpadV3.Launch({
            name: "Fork Ocean",
            symbol: "FOCEAN",
            quoteAsset: NATIVE,
            virtualQuote: 1 ether,
            graduationQuote: 2 ether,
            buyTaxBps: 300,
            sellTaxBps: 500,
            protocolFeeBps: 100,
            split: FeeVaultV3.Split({creatorBps: 5000, basketBps: 3000, jackpotBps: 1000, burnBps: 1000}),
            basketTokens: basket,
            basketWeights: weights,
            antiSnipeSeconds: 0,
            antiSnipeMaxWalletBps: 0,
            antiSnipeTaxBps: 0,
            jackpotEveryN: 10,
            jackpotMinBuy: 0,
            salt: bytes32(uint256(42)),
            firstBuyQuote: 0,
            minFirstBuyOut: 0,
            deadline: block.timestamp + 1 hours
        });
    }

    function launchAndGraduate() internal returns (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) {
        vm.prank(creator);
        (address token, address curve, address vault) = pad.create{value: pad.CREATION_FEE()}(params());
        t = MemeTokenV3(token);
        c = BondingCurveV3(payable(curve));
        v = FeeVaultV3(payable(vault));
        vm.prank(alice);
        c.buy{value: 1 ether}(1 ether, 0, alice);
        assertFalse(c.graduated());
        vm.prank(bob);
        c.buy{value: 1.5 ether}(1.5 ether, 0, bob);
        assertTrue(c.graduated(), "second buy crosses 2 ETH");
    }

    function testFork_graduationBuildsLockedV4Pool_andHookFeesFlowInEth() public {
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launchAndGraduate();
        assertEq(c.pool(), POOL_MANAGER);
        assertTrue(handler.pooled(address(t)));
        assertTrue(t.exempt(POOL_MANAGER), "pool manager excluded from dividends, not taxed on transfer");
        assertFalse(t.isMarket(POOL_MANAGER));
        PoolKey memory key = handler.poolKeyOf(address(t));
        assertEq(key.currency0, NATIVE);
        assertEq(key.currency1, address(t));
        assertEq(key.hooks, address(hook));
        // Curve keeps only the unclaimed 1% protocol fee; everything else sits in the PoolManager
        // (plus rounding dust swept to the treasury).
        assertEq(address(c).balance, c.treasuryEarned());
        assertEq(c.treasuryEarned(), 2.5 ether / 100);
        assertEq(t.balanceOf(address(c)), 0);
        assertEq(t.balanceOf(address(handler)), 0);
        assertEq(address(handler).balance, 0);
        assertGt(t.balanceOf(POOL_MANAGER), 0);

        _exactInBuy(t, v, key);
        _exactInSell(t, v, key);
        _exactOutBuy(t, v, key);
        _exactOutSell(t, v, key);
        // Vault invariant: buckets == balance.
        assertEq(
            v.creatorEarned() + v.basketPending() + v.jackpotPot() + v.burnPending() + v.totalJackpotOwed(),
            address(v).balance
        );
    }

    /// Exact-input buy with ETH: quote is the specified currency → beforeSwap fee = 3% of input.
    function _exactInBuy(MemeTokenV3 t, FeeVaultV3 v, PoolKey memory key) internal {
        uint256 creatorBefore = v.creatorEarned();
        uint256 lifetimeBefore = v.lifetimeFees();
        uint256 aliceTokens = t.balanceOf(alice);
        uint256 protocolBefore = treasury.balance;
        vm.prank(alice);
        trader.trade{value: 0.1 ether}(key, true, -0.1 ether);
        assertGt(t.balanceOf(alice), aliceTokens, "alice received tokens");
        uint256 fee = v.lifetimeFees() - lifetimeBefore;
        assertEq(fee, 0.1 ether * 300 / 10_000, "3% buy tax in ETH");
        assertEq(treasury.balance - protocolBefore, 0.1 ether * 100 / 10_000, "1% protocol share in ETH");
        assertEq(v.creatorEarned() - creatorBefore, fee / 2);
    }

    /// Exact-input sell of tokens: quote is unspecified → afterSwap fee = 5% of gross ETH out.
    function _exactInSell(MemeTokenV3 t, FeeVaultV3 v, PoolKey memory key) internal {
        uint256 sellAmount = t.balanceOf(alice) / 4;
        vm.startPrank(alice);
        t.approve(address(trader), sellAmount);
        uint256 ethBefore = alice.balance;
        uint256 lifetimeBefore = v.lifetimeFees();
        uint256 protocolBefore = treasury.balance;
        int256 delta = trader.trade(key, false, -int256(sellAmount));
        vm.stopPrank();
        // The router sees net output; both the vault tax and protocol share were removed.
        uint256 net = uint256(uint128(V4.amount0(delta)));
        assertGt(net, 0);
        uint256 fee = v.lifetimeFees() - lifetimeBefore;
        uint256 protocol = treasury.balance - protocolBefore;
        uint256 gross = net + fee + protocol;
        assertApproxEqAbs(fee, gross * 500 / 10_000, 1, "5% sell tax on gross ETH out");
        assertApproxEqAbs(protocol, gross * 100 / 10_000, 1, "1% protocol share on gross ETH out");
        assertEq(alice.balance - ethBefore, net, "trader receives the net amount");
    }

    /// Exact-output buy (want N tokens): quote unspecified → afterSwap fee on the ETH paid.
    function _exactOutBuy(MemeTokenV3, FeeVaultV3 v, PoolKey memory key) internal {
        uint256 lifetimeBefore = v.lifetimeFees();
        uint256 bobEth = bob.balance;
        uint256 protocolBefore = treasury.balance;
        vm.prank(bob);
        int256 delta = trader.trade{value: 1 ether}(key, true, int256(1_000_000 ether));
        assertEq(V4.amount1(delta), int128(int256(1_000_000 ether)));
        // Paid input includes the separate vault tax and protocol share.
        uint256 paid = uint256(uint128(-V4.amount0(delta)));
        uint256 fee = v.lifetimeFees() - lifetimeBefore;
        uint256 protocol = treasury.balance - protocolBefore;
        assertEq(fee, (paid - fee - protocol) * 300 / 10_000, "3% of the ETH the pool received");
        assertEq(protocol, (paid - fee - protocol) * 100 / 10_000, "1% protocol share of pool input");
        assertEq(bobEth - bob.balance, paid, "buyer pays pool input plus fee, rest refunded");
    }

    /// Exact-output sell (want X ETH): quote specified → beforeSwap fee, trader still nets exactly X.
    function _exactOutSell(MemeTokenV3 t, FeeVaultV3 v, PoolKey memory key) internal {
        vm.startPrank(bob);
        t.approve(address(trader), type(uint256).max);
        uint256 ethBefore = bob.balance;
        uint256 lifetimeBefore = v.lifetimeFees();
        uint256 protocolBefore = treasury.balance;
        trader.trade(key, false, int256(0.01 ether));
        vm.stopPrank();
        assertEq(bob.balance - ethBefore, 0.01 ether, "exact ETH out net of fee");
        assertEq(v.lifetimeFees() - lifetimeBefore, 0.01 ether * 500 / 10_000);
        assertEq(treasury.balance - protocolBefore, 0.01 ether * 100 / 10_000);
    }

    function testFork_basketBuysRealNvda_buybackBurns_lpFeesToTreasury() public {
        (MemeTokenV3 t,, FeeVaultV3 v) = launchAndGraduate();
        PoolKey memory key = handler.poolKeyOf(address(t));
        // Generate fees on the graduated pool.
        vm.prank(alice);
        trader.trade{value: 0.5 ether}(key, true, -0.5 ether);
        assertGt(v.basketPending(), 0);
        assertGt(v.burnPending(), 0);

        // Basket: ETH → NVDA through the live pool, streamed to holders as dividends.
        uint256[] memory minOuts = new uint256[](1);
        uint256 pendingBefore = v.basketPending();
        v.buyBasket(minOuts);
        assertEq(v.basketPending(), 0);
        uint256 nvdaInToken = IERC20(NVDA).balanceOf(address(t));
        assertGt(nvdaInToken, 0, "token contract holds NVDA for holders");
        assertGt(t.pending(alice, NVDA), 0, "alice accrues NVDA");
        assertEq(t.pending(POOL_MANAGER, NVDA), 0, "pool never earns dividends");
        vm.prank(alice);
        t.claimRewards();
        assertGt(IERC20(NVDA).balanceOf(alice), 0, "alice claims real NVDA");
        emit log_named_uint("ETH spent on basket", pendingBefore);
        emit log_named_uint("NVDA bought (1e18)", nvdaInToken);

        // Buyback: ETH → meme via the handler-resolved route, then burn.
        uint256 supplyBefore = t.totalSupply();
        v.buybackAndBurn(0);
        assertLt(t.totalSupply(), supplyBefore, "buyback burned supply");

        // Pool LP fee is 0; protocol share already went to treasury during swaps.
        uint256 tEth = treasury.balance;
        uint256 tTok = t.balanceOf(treasury);
        (uint256 f0, uint256 f1) = handler.collectFees(address(t));
        assertEq(f0 + f1, 0, "no extra LP fee on graduated pools");
        assertEq(treasury.balance, tEth);
        assertEq(t.balanceOf(treasury), tTok);
    }

    function testFork_hookRejectsForeignPools_andForeignRegistrations() public {
        PoolKey memory foreign = PoolKey(NATIVE, NVDA, 3000, 60, address(hook));
        vm.expectRevert();
        pm.initialize(foreign, uint160(1 << 96));
        vm.expectRevert(BarkHookV3.ONLY_HANDLER.selector);
        hook.register(foreign, address(this), NATIVE, 100, 100, 0, address(this));
    }
}
