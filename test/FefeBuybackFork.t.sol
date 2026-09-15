// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FefeSink} from "../src/v3/FefeSink.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {FefeBuybackHookV3} from "../src/v3/uniswap/FefeBuybackHookV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {IPoolManager, PoolKey, SwapParams, V4} from "../src/v3/uniswap/V4Types.sol";

interface IFefeV4Quoter {
    struct Params {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(Params memory params) external returns (uint256 amountOut, uint256 gasEstimate);
}

/// Opt-in tests against a CLI-pinned RH mainnet fork. No broadcasts or signing keys.
contract FefeBuybackLiveForkTest is Test {
    address constant OFFICIAL = 0x0814068a2e65efeEE2d78F9cc537370D1B62f76b;
    address constant PAD = 0x3Cb03A559F83f8fF59af48C043491A3728FdD396;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    FefeSink sink;
    UniswapV4SwapAdapterV3 adapter;
    FefeBuybackHookV3 hook;
    MemeTokenV3 fefe;
    BondingCurveV3 curve;
    address operator;
    bool stage;

    function setUp() public {
        if (!vm.envOr("BARK_RUN_FEFE_BUYBACK_FORK", false)) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "explicit RH mainnet fork required");
        assertEq(PM.codehash, 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626);
        sink = FefeSink(payable(LaunchpadV3(PAD).treasury()));
        fefe = MemeTokenV3(OFFICIAL);
        curve = BondingCurveV3(payable(fefe.curve()));
        adapter = UniswapV4SwapAdapterV3(payable(address(sink.adapter())));
        operator = adapter.routeAdmin();
        assertEq(sink.fefe(), OFFICIAL);
        assertFalse(curve.graduated(), "this live regression pins the curve stage");
        hook = _deployBuyback(OFFICIAL, PAD, operator);
    }

    function _salt(bytes memory init, uint160 flags) internal view returns (bytes32) {
        bytes32 hash = keccak256(init);
        for (uint256 i; i < 300_000; ++i) {
            address at =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if ((uint160(at) & V4.ALL_HOOK_MASK) == flags) return bytes32(i);
        }
        revert("no hook salt");
    }

    function _deployBuyback(address token, address pad, address op) internal returns (FefeBuybackHookV3 h) {
        bytes memory init = abi.encodePacked(type(FefeBuybackHookV3).creationCode, abi.encode(token, pad, op));
        bytes32 salt = _salt(init, (1 << 13) | (1 << 11) | (1 << 7) | (1 << 3));
        h = new FefeBuybackHookV3{salt: salt}(token, pad, op);
    }

    function _install() internal {
        vm.startPrank(operator);
        IPoolManager(PM).initialize(hook.keyFor(address(0)), uint160(1 << 96));
        IPoolManager(PM).initialize(hook.keyFor(NVDA), uint160(1 << 96));
        adapter.setRoute(address(0), address(fefe), hook.keyFor(address(0)));
        adapter.setRoute(NVDA, address(fefe), hook.keyFor(NVDA));
        vm.stopPrank();
    }

    function _run(address source, uint256 amount, uint256 minQuote, uint256 minFefe) internal returns (uint256) {
        vm.prank(operator);
        return hook.execute(source, amount, minQuote, minFefe, stage, block.timestamp + 60);
    }

    function _quoteByRevertedSnapshot(address source, uint256 amount) internal returns (uint256 out, uint256 quoteIn) {
        uint256 backing = curve.backingReserve();
        uint256 supply = fefe.totalSupply();
        uint256 sourceBalance = source == address(0) ? address(sink).balance : IERC20(source).balanceOf(address(sink));
        vm.prank(operator);
        try hook.preview(source, amount, stage) {
            revert("preview unexpectedly returned");
        } catch (bytes memory reason) {
            assertEq(reason.length, 68);
            assertEq(bytes4(reason), FefeBuybackHookV3.BuybackPreview.selector);
            assembly {
                quoteIn := mload(add(reason, 36))
                out := mload(add(reason, 68))
            }
        }
        assertEq(curve.backingReserve(), backing);
        assertEq(fefe.totalSupply(), supply);
        assertEq(source == address(0) ? address(sink).balance : IERC20(source).balanceOf(address(sink)), sourceBalance);
    }

    function testForkExistingSinkETHActuallyBuysAndBurns() public {
        uint256 amount = address(sink).balance;
        assertGt(amount, 0, "use existing sink funds, do not inject an ETH balance");
        vm.expectRevert(UniswapV4SwapAdapterV3.NO_ROUTE.selector);
        sink.harvest(address(0), NVDA, 1);
        _install();
        (uint256 expected, uint256 minQuote) = _quoteByRevertedSnapshot(address(0), amount);
        uint256 supply = fefe.totalSupply();
        uint256 backing = curve.backingReserve();
        uint256 burned = _run(address(0), amount, minQuote, expected);
        assertEq(burned, expected);
        assertEq(supply - fefe.totalSupply(), burned);
        assertEq(address(sink).balance, 0);
        assertEq(fefe.balanceOf(address(sink)), 0);
        assertGt(curve.backingReserve(), backing);
        assertEq(IERC20(NVDA).balanceOf(address(hook)), 0);
        assertEq(fefe.balanceOf(address(hook)), 0);
        assertEq(IERC20(NVDA).allowance(address(hook), address(curve)), 0);
        emit log_named_uint("live source ETH wei", amount);
        emit log_named_uint("live FEFE burned raw", burned);
    }

    function _communityParams(uint256 threshold) internal view returns (LaunchpadV3.Launch memory p) {
        p.name = "Fork community";
        p.symbol = "FORK";
        p.quoteAsset = NVDA;
        p.virtualQuote = 1 ether;
        p.graduationQuote = uint128(threshold);
        p.buyTaxBps = 80;
        p.sellTaxBps = 80;
        p.protocolFeeBps = 20;
        p.split = FeeVaultV3.Split(10000, 0, 0, 0);
        p.deadline = block.timestamp + 60;
    }

    function testForkRealCommunityProtocolFeeClaimThenBuyAndBurn() public {
        _install();
        vm.deal(address(this), 2 ether); // only local trader funding; NVDA is bought on the real pool
        uint256 nvda = adapter.swapExactIn{value: 0.01 ether}(address(0), NVDA, 0.01 ether, 1, address(this));
        LaunchpadV3.Launch memory p = _communityParams(nvda * 10);
        (, address community,) = LaunchpadV3(PAD).create{value: 0.0005 ether}(p);
        IERC20(NVDA).approve(community, nvda);
        BondingCurveV3(payable(community)).buy(nvda, 1, address(this));
        uint256 fee = nvda * 20 / 10000;
        assertEq(BondingCurveV3(payable(community)).treasuryEarned(), fee);
        uint256 before = IERC20(NVDA).balanceOf(address(sink));
        BondingCurveV3(payable(community)).claimTreasury();
        assertEq(IERC20(NVDA).balanceOf(address(sink)) - before, fee);
        uint256 amount = before + fee;
        (uint256 expected,,,) = curve.quoteBuy(amount, address(hook));
        uint256 supply = fefe.totalSupply();
        uint256 burned = _run(NVDA, amount, amount, expected);
        assertEq(supply - fefe.totalSupply(), burned);
        assertEq(IERC20(NVDA).balanceOf(address(sink)), 0);
        emit log_named_uint("community NVDA traded raw", nvda);
        emit log_named_uint("community NVDA protocol fee raw", fee);
        emit log_named_uint("community-funded FEFE burned raw", burned);
    }

    function testForkSlippageFailureRollsBackEveryLegAndCanRetry() public {
        _install();
        uint256 amount = address(sink).balance;
        (uint256 expected, uint256 quoteIn) = _quoteByRevertedSnapshot(address(0), amount);
        uint256 supply = fefe.totalSupply();
        uint256 backing = curve.backingReserve();
        vm.expectRevert();
        _run(address(0), amount, quoteIn, expected + 1);
        assertEq(address(sink).balance, amount);
        assertEq(fefe.totalSupply(), supply);
        assertEq(curve.backingReserve(), backing);
        vm.expectRevert();
        _run(address(0), amount, type(uint128).max, expected);
        assertEq(address(sink).balance, amount);
        assertEq(_run(address(0), amount, quoteIn, expected), expected);
    }

    function testForkUnboundedHarvestCannotBypassOperator() public {
        _install();
        uint256 amount = address(sink).balance;
        vm.expectRevert();
        sink.harvest(address(0), address(0), 0);
        vm.expectRevert();
        sink.harvest(address(0), NVDA, 0);
        assertEq(address(sink).balance, amount);
        vm.expectRevert(FefeBuybackHookV3.ONLY_OPERATOR.selector);
        hook.execute(address(0), amount, 1, 1, false, block.timestamp + 60);
        PoolKey memory key = hook.keyFor(address(0));
        vm.expectRevert(FefeBuybackHookV3.ONLY_POOL_MANAGER.selector);
        hook.beforeSwap(address(adapter), key, SwapParams(true, -int256(amount), 0), "");
        vm.prank(operator);
        vm.expectRevert(FefeBuybackHookV3.BAD_PLAN.selector);
        hook.execute(address(0), amount, 0, 1, false, block.timestamp + 60);
        vm.prank(operator);
        vm.expectRevert(FefeBuybackHookV3.BAD_PLAN.selector);
        hook.execute(address(0), amount, 1, 1, false, block.timestamp - 1);
        vm.prank(operator);
        vm.expectRevert(FefeBuybackHookV3.BAD_PLAN.selector);
        hook.execute(address(0), amount, 1, 1, true, block.timestamp + 60);
        vm.prank(operator);
        vm.expectRevert(FefeBuybackHookV3.BALANCE_CHANGED.selector);
        hook.execute(address(0), amount + 1, 1, 1, false, block.timestamp + 60);
    }

    function testForkGraduationBoundaryRejectsBeforeSpending() public {
        _install();
        (, uint128 threshold,,,,,,,,) = curve.config();
        // Only this boundary test substitutes a reserve read; execution tests use real state.
        vm.mockCall(
            address(curve), abi.encodeWithSelector(curve.backingReserve.selector), abi.encode(uint256(threshold))
        );
        uint256 amount = address(sink).balance;
        uint256 supply = fefe.totalSupply();
        vm.expectRevert();
        _run(address(0), amount, 1, 1);
        assertEq(address(sink).balance, amount);
        assertEq(fefe.totalSupply(), supply);
        vm.clearMockedCalls();
    }

    function testForkAfterGraduationUsesTheOriginalGraduationPool() public {
        // A locally created official-style market proves transition behavior against the real PM.
        // The live official market remains ungraduated; no live storage is overwritten.
        UniswapV4SwapAdapterV3 a = new UniswapV4SwapAdapterV3(IPoolManager(PM), address(this));
        FefeSink collector = new FefeSink(address(this), a);
        UniswapV4GraduationHandlerV3 h = new UniswapV4GraduationHandlerV3(IPoolManager(PM), address(collector));
        bytes memory init = abi.encodePacked(type(BarkHookV3).creationCode, abi.encode(PM, address(h)));
        bytes32 salt = _salt(init, (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        BarkHookV3 marketHook = new BarkHookV3{salt: salt}(IPoolManager(PM), address(h));
        a.setHandler(h);
        a.setRoute(address(0), NVDA, PoolKey(address(0), NVDA, 500, 10, address(0)));
        LaunchpadV3 pad = new LaunchpadV3(address(collector), h, a);
        h.bind(marketHook, address(pad));
        vm.deal(address(this), 2 ether);
        uint256 nvda = a.swapExactIn{value: 0.01 ether}(address(0), NVDA, 0.01 ether, 1, address(this));
        LaunchpadV3.Launch memory p = _communityParams(nvda / 4);
        p.buyTaxBps = 100;
        p.sellTaxBps = 100;
        p.protocolFeeBps = 0;
        p.split = FeeVaultV3.Split(0, 5000, 0, 5000);
        p.basketTokens = new address[](1);
        p.basketTokens[0] = NVDA;
        p.basketWeights = new uint16[](1);
        p.basketWeights[0] = 10000;
        (address token, address c, address vault) = pad.create{value: 0.0005 ether}(p);
        collector.setFefe(token);
        sink = collector;
        adapter = a;
        fefe = MemeTokenV3(token);
        curve = BondingCurveV3(payable(c));
        operator = address(this);
        hook = _deployBuyback(token, address(pad), operator);
        _install();
        IERC20(NVDA).approve(c, nvda);
        curve.buy(nvda / 2, 1, address(this)); // graduation outside the PM unlock, the existing supported path
        assertTrue(curve.graduated());
        stage = true;
        PoolKey memory market = h.poolKeyOf(token);
        assertEq(market.hooks, address(marketHook));
        uint256 amount = address(sink).balance;
        (uint256 expected,) = _quoteByRevertedSnapshot(address(0), amount);
        uint256 supply = fefe.totalSupply();
        assertEq(_run(address(0), amount, 1, expected), expected);
        assertEq(supply - fefe.totalSupply(), expected);
        assertEq(address(sink).balance, 0);
        assertEq(fefe.balanceOf(address(hook)), 0);
        assertEq(IERC20(NVDA).balanceOf(address(hook)), 0);
        _assertLegacyVault(vault);
    }

    function _assertLegacyVault(address vault) internal {
        // The official market's own 50% burn bucket must still work through its
        // original permissionless vault entry; it is not a sink protocol-fee burn.
        FeeVaultV3 v = FeeVaultV3(payable(vault));
        assertGt(v.burnPending(), 0);
        uint256 pending = v.burnPending();
        uint256 lifetime = v.lifetimeBurned();
        uint256 beforeSupply = fefe.totalSupply();
        PoolKey memory buybackKey = hook.keyFor(NVDA);
        (uint256 vaultQuote,) = IFefeV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94)
            .quoteExactInputSingle(IFefeV4Quoter.Params(buybackKey, buybackKey.currency0 == NVDA, uint128(pending), ""));
        assertGt(vaultQuote, 0, "existing keeper V4 quote must remain available");
        v.buybackAndBurn(vaultQuote);
        assertGt(v.lifetimeBurned(), lifetime);
        assertEq(beforeSupply - fefe.totalSupply(), v.lifetimeBurned() - lifetime);
        assertLt(v.burnPending(), pending); // the buy itself has the configured market fee
        // Reverse quote conversion remains available for legacy adapter callers.
        uint256 tokens = fefe.balanceOf(address(this)) / 1000;
        fefe.approve(address(adapter), tokens);
        assertGt(adapter.swapExactIn(address(fefe), NVDA, tokens, 1, address(this)), 0);
    }

    receive() external payable {}
}
