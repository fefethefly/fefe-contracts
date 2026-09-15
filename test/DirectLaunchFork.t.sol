// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DirectLaunchpadV3} from "../src/v3/DirectLaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, V4} from "../src/v3/uniswap/V4Types.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";

contract DirectQuoteMock is ERC20 {
    constructor() ERC20("Quote", "QUOTE") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Test-only trader that settles a single v4 swap for an EOA (identical to the graduation fork test).
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
 * End-to-end on a pinned Robinhood Chain fork: direct launch builds a real v4 pool with
 * BarkHookV3, 100% of supply locked as a single-sided position, no LP fee, no protocol
 * share — then a buy/sell round trip shows the creator tax flowing to the vault.
 *
 *   BARK_RUN_UNISWAP_FORK=true forge test --match-contract DirectLaunchForkTest \
 *     --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((HEAD-30)) \
 *     --evm-version cancun --compute-units-per-second 40 --fork-retries 3 -vv
 */
contract DirectLaunchForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // Any code-bearing token works as a basket placeholder; no route is exercised here.
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    UniswapV4GraduationHandlerV3 handler;
    BarkHookV3 hook;
    UniswapV4SwapAdapterV3 adapter;
    DirectLaunchpadV3 pad;
    ForkTrader trader;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

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
        pad = new DirectLaunchpadV3(handler, adapter);
        handler.bindHook(hook);
        handler.bindDirect(address(pad));
        trader = new ForkTrader(pm);
        vm.deal(creator, 10 ether);
        vm.deal(alice, 10 ether);
    }

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

    function params() internal view returns (DirectLaunchpadV3.DirectLaunch memory p) {
        address[] memory basket = new address[](1);
        basket[0] = NVDA;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        p = DirectLaunchpadV3.DirectLaunch({
            name: "Direct Ocean",
            symbol: "DOCEAN",
            quoteAsset: NATIVE,
            virtualQuote: 1 ether,
            buyTaxBps: 100,
            sellTaxBps: 100,
            split: FeeVaultV3.Split({creatorBps: 5000, basketBps: 3000, jackpotBps: 0, burnBps: 2000}),
            basketTokens: basket,
            basketWeights: weights,
            salt: bytes32(uint256(7)),
            deadline: block.timestamp + 1 hours
        });
    }

    function launch() internal returns (MemeTokenV3 t, FeeVaultV3 v, PoolKey memory key) {
        vm.prank(creator);
        (address token, address vault,) = pad.create(params());
        t = MemeTokenV3(token);
        v = FeeVaultV3(payable(vault));
        key = handler.poolKeyOf(token);
    }

    function testFork_directLaunchBuildsLockedPool_withWholeSupply() public {
        (MemeTokenV3 t,, PoolKey memory key) = launch();
        // 100% of supply is in the pool or burned; the creator and handler hold nothing.
        assertEq(t.balanceOf(creator), 0);
        assertEq(t.balanceOf(address(handler)), 0);
        assertEq(t.balanceOf(POOL_MANAGER) + t.balanceOf(address(0xdead)), t.FIXED_SUPPLY());
        assertTrue(handler.pooled(address(t)));
        assertEq(key.currency0, NATIVE);
        assertEq(key.currency1, address(t));
        assertEq(key.hooks, address(hook));
        assertEq(key.fee, 0);
        assertTrue(t.exempt(POOL_MANAGER), "pool excluded from dividends");
        assertFalse(t.isMarket(POOL_MANAGER), "no token-level transfer tax");
        // LP fee is 0: the locked position accrues nothing collectible.
        (uint256 f0, uint256 f1) = handler.collectFees(address(t));
        assertEq(f0 + f1, 0);
    }

    function testFork_buySell_creatorTaxToVault_protocolShareZero() public {
        (MemeTokenV3 t, FeeVaultV3 v, PoolKey memory key) = launch();
        uint256 lifetimeBefore = v.lifetimeFees();
        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = v.creatorEarned();

        vm.prank(alice);
        trader.trade{value: 0.01 ether}(key, true, -0.01 ether);
        assertGt(t.balanceOf(alice), 0, "alice received tokens");

        uint256 fee = v.lifetimeFees() - lifetimeBefore;
        assertEq(fee, 0.01 ether * 100 / 10_000, "1% buy tax in ETH");
        assertEq(treasury.balance, treasuryBefore, "protocol share is 0 (we take nothing)");
        assertEq(v.creatorEarned() - creatorBefore, fee / 2, "creator split is 50%");
        assertGt(v.basketPending(), 0, "basket split funded");
        assertGt(v.burnPending(), 0, "buyback split funded");
        // Vault invariant: buckets == balance.
        assertEq(
            v.creatorEarned() + v.basketPending() + v.burnPending(), address(v).balance, "vault buckets balanced"
        );

        // Exit: sell everything back. Sell tax is also 1% on gross ETH out.
        vm.startPrank(alice);
        t.approve(address(trader), type(uint256).max);
        uint256 ethBefore = alice.balance;
        trader.trade(key, false, -int256(t.balanceOf(alice)));
        vm.stopPrank();
        assertGt(alice.balance, ethBefore, "alice exits with ETH");
        assertEq(t.balanceOf(alice), 0);

        // Creator can claim their share.
        uint256 owed = v.creatorEarned();
        assertGt(owed, 0);
        vm.prank(creator);
        v.claimCreator();
        assertEq(v.creatorEarned(), 0);
    }
    function testFork_buybackUsesAdapterFromLaunch() public {
        (MemeTokenV3 t, FeeVaultV3 v, PoolKey memory key) = launch();
        assertEq(v.curve(), address(handler));
        vm.prank(alice);
        trader.trade{value: 0.01 ether}(key, true, -0.01 ether);
        uint256 supply = t.totalSupply();
        v.buybackAndBurn(1);
        assertGt(v.lifetimeBurned(), 0);
        assertLt(t.totalSupply(), supply);
        assertEq(address(adapter).balance, 0);
    }

    function testFork_zeroTaxNativeRoundTrip() public {
        DirectLaunchpadV3.DirectLaunch memory p = params();
        p.buyTaxBps = 0;
        p.sellTaxBps = 0;
        vm.prank(creator);
        (address token, address vault,) = pad.create(p);
        PoolKey memory key = handler.poolKeyOf(token);
        vm.startPrank(alice);
        trader.trade{value: 0.01 ether}(key, true, -0.01 ether);
        IERC20(token).approve(address(trader), type(uint256).max);
        trader.trade(key, false, -int256(IERC20(token).balanceOf(alice)));
        vm.stopPrank();
        assertEq(FeeVaultV3(payable(vault)).lifetimeFees(), 0);
        assertEq(treasury.balance, 0);
    }

    function _erc20RoundTrip(address quote, bool tokenIsZero) internal {
        DirectQuoteMock implementation = new DirectQuoteMock();
        vm.etch(quote, address(implementation).code);
        DirectQuoteMock q = DirectQuoteMock(quote);
        DirectLaunchpadV3.DirectLaunch memory p = params();
        p.quoteAsset = quote;
        p.virtualQuote = 5000 ether;
        uint256 beforeBalance = q.balanceOf(POOL_MANAGER);
        vm.prank(creator);
        (address token, address vault,) = pad.create(p);
        PoolKey memory key = handler.poolKeyOf(token);
        assertEq(key.currency0 == token, tokenIsZero);
        assertEq(q.balanceOf(POOL_MANAGER), beforeBalance, "launch requires no quote funding");
        assertEq(IERC20(token).balanceOf(POOL_MANAGER) + IERC20(token).balanceOf(address(0xdead)), 1e27);
        assertLt(IERC20(token).balanceOf(address(0xdead)), 1e10, "only integer rounding dust");
        q.mint(alice, 100 ether);
        vm.startPrank(alice);
        q.approve(address(trader), type(uint256).max);
        trader.trade(key, !tokenIsZero, -100 ether);
        (uint256 deferred,) = hook.pendingFees(V4.poolId(key));
        assertEq(deferred, 1 ether, "first fee is a funded manager claim");
        hook.settleFees(V4.poolId(key));
        (deferred,) = hook.pendingFees(V4.poolId(key));
        assertEq(deferred, 0);
        assertGt(IERC20(token).balanceOf(alice), 0);
        IERC20(token).approve(address(trader), type(uint256).max);
        trader.trade(key, tokenIsZero, -int256(IERC20(token).balanceOf(alice)));
        vm.stopPrank();
        FeeVaultV3 v = FeeVaultV3(payable(vault));
        assertGt(q.balanceOf(alice), 0);
        assertGt(v.lifetimeFees(), 1 ether);
        assertEq(q.balanceOf(treasury), 0);
        assertEq(v.creatorEarned() + v.basketPending() + v.burnPending(), q.balanceOf(vault));
        v.buybackAndBurn(1);
        assertGt(v.lifetimeBurned(), 0);
        assertEq(q.balanceOf(address(adapter)), 0);
    }

    function testFork_erc20Quote_tokenCurrencyZero() public {
        _erc20RoundTrip(address(type(uint160).max - 1), true);
    }

    function testFork_erc20Quote_tokenCurrencyOne() public {
        _erc20RoundTrip(address(0x10000), false);
    }

}
