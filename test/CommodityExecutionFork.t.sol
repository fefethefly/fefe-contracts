// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommodityOracleGuardV3, ICommodityPriceFeedV3} from "../src/v3/uniswap/CommodityOracleGuardV3.sol";
import {CommoditySwapAdapterV3, ICommodityV3Factory} from "../src/v3/uniswap/CommoditySwapAdapterV3.sol";
import {MarketSwapDispatcherV3, IMarketRouteAdapterV3} from "../src/v3/uniswap/MarketSwapDispatcherV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {IPoolManager, PoolKey, V4} from "../src/v3/uniswap/V4Types.sol";
import {CommodityLaunchpadV3} from "../src/v3/CommodityLaunchpadV3.sol";
import {CommodityDirectRewardLaunchpadV3} from "../src/v3/CommodityDirectRewardLaunchpadV3.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";

interface ICommodityForkQuoter {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function factory() external view returns (address);
    function quoteExactInputSingle(Params calldata p) external returns (uint256, uint160, uint32, uint256);
}

interface ICommodityForkV4Quoter {
    struct Params {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function poolManager() external view returns (address);
    function quoteExactInputSingle(Params calldata p) external returns (uint256 amountOut, uint256 gasEstimate);
}

/// Opt-in local fork only. deal() funds local fixture balances, never a real chain transaction.
contract CommodityExecutionForkTest is Test {
    address constant CORN = address(bytes20(hex"d45fbccbaec892c92f43015352ddd85d6bca56cd"));
    address constant COFFEE = address(bytes20(hex"ab81322a679236d8a55768e2f1bf0b08ae767dd3"));
    address constant CORN_POOL = address(bytes20(hex"577e1b5dd7ff1d331b5bf907fde0d829b082690e"));
    address constant COFFEE_POOL = address(bytes20(hex"3ddf350a66f33f8695c09c32823449ccea29b1f9"));
    address constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));
    address constant FACTORY = address(bytes20(hex"1f7d7550b1b028f7571e69a784071f0205fd2efa"));
    address constant FEED = address(bytes20(hex"3b784715e1ecfdc6a59707d5b05e5bc898159ab7"));
    address constant QUOTER = address(bytes20(hex"33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7"));
    address constant POOL_MANAGER = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
    bytes32 constant CORN_ID = 0xe13ef6be1094456bb8dc2a5a5fe7ef2f614a259568a0d3a0c88b18d3388a6383;
    bytes32 constant COFFEE_ID = 0xab11394d7ad07bf31041b2aede70b5a9927f62420a26a8e9d7107e553f118930;
    CommoditySwapAdapterV3 commodity;
    MarketSwapDispatcherV3 dispatcher;
    UniswapV4SwapAdapterV3 v4;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address creator = makeAddr("commodity-fork-creator");
    address alice = makeAddr("commodity-fork-alice");
    address bob = makeAddr("commodity-fork-bob");
    address treasury = makeAddr("commodity-fork-treasury");

    function setUp() public {
        if (!vm.envOr("LUMOB_RUN_COMMODITY_FORK", false)) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envUint("LUMOB_COMMODITY_FORK_BLOCK");
        assertGt(pinned, 0);
        // Own the fork selection: on Nitro the NUMBER opcode can expose the parent-chain
        // height, so comparing block.number with the requested L2 RPC height is incorrect.
        // No latest-block fallback and no vm.roll override of the chain's real semantics.
        uint256 forkId = vm.createSelectFork(
            vm.envOr("LUMOB_COMMODITY_FORK_RPC", string("https://rpc.mainnet.chain.robinhood.com")), pinned
        );
        assertEq(vm.activeFork(), forkId, "pinned fork must be selected");
        assertEq(vm.getChainId(), 4663, "Robinhood mainnet fork required");
        emit log_named_uint("Pinned L2 RPC block", pinned);
        emit log_named_uint("EVM block number", vm.getBlockNumber());
        assertGt(POOL_MANAGER.code.length, 0);
        assertEq(ICommodityForkQuoter(QUOTER).factory(), FACTORY);
        address[] memory assets = new address[](2);
        assets[0] = CORN;
        assets[1] = COFFEE;
        address[] memory pools = new address[](2);
        pools[0] = CORN_POOL;
        pools[1] = COFFEE_POOL;
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = CORN_ID;
        ids[1] = COFFEE_ID;
        // Research policy only: accept the observed one-hour source configuration,
        // while actual observations must still be younger than ten minutes.
        // Never rewrite the feed or warp time to make a stale source pass.
        CommodityOracleGuardV3 guard =
            new CommodityOracleGuardV3(4663, ICommodityPriceFeedV3(FEED), 3600, 600, assets, ids);
        // Validate the assets used by each operation. An unrelated stale candidate
        // must not prevent diagnostics of a healthy, separately scoped market.
        commodity = new CommoditySwapAdapterV3(4663, ICommodityV3Factory(FACTORY), USDG, 500, assets, pools, guard);
        v4 = new UniswapV4SwapAdapterV3(IPoolManager(POOL_MANAGER), address(this));
        dispatcher = new MarketSwapDispatcherV3(commodity, IMarketRouteAdapterV3(address(v4)));
    }

    function quote(address a, address b, uint256 amount) private returns (uint256 out) {
        (out,,,) = ICommodityForkQuoter(QUOTER).quoteExactInputSingle(ICommodityForkQuoter.Params(a, b, amount, 500, 0));
        assertGt(out, 0);
    }

    function minimum(address a, address b, uint256 amount) private returns (uint256) {
        uint256 out = quote(USDG, b, quote(a, USDG, amount));
        // 1% floor is confined to this small fork smoke, not permissionless keeper authorization.
        uint256 result = out * 99 / 100;
        assertGt(result, 0);
        return result;
    }

    function test_realCommodityPoolsRoundTripThroughDispatcher() public {
        deal(CORN, address(this), 1 ether);
        IERC20(CORN).approve(address(dispatcher), 1 ether);
        uint256 minOut = minimum(CORN, COFFEE, 1 ether);
        uint256 beforeCoffee = IERC20(COFFEE).balanceOf(address(this));
        uint256 out = dispatcher.swapExactIn(CORN, COFFEE, 1 ether, minOut, address(this));
        assertEq(IERC20(COFFEE).balanceOf(address(this)) - beforeCoffee, out);
        IERC20(COFFEE).approve(address(dispatcher), out);
        uint256 minBack = minimum(COFFEE, CORN, out);
        uint256 back = dispatcher.swapExactIn(COFFEE, CORN, out, minBack, address(this));
        assertGe(back, minBack);
        assertEq(IERC20(CORN).balanceOf(address(dispatcher)), 0);
        assertEq(IERC20(USDG).balanceOf(address(commodity)), 0);
        assertEq(IERC20(CORN).allowance(address(dispatcher), address(commodity)), 0);
    }

    function test_realPoolConversionFundsHolderClaims() public {
        MemeTokenV3 token = new MemeTokenV3();
        address[] memory rewards = new address[](1);
        rewards[0] = COFFEE;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        FeeVaultV3 vault = new FeeVaultV3(
            token,
            CORN,
            payable(address(this)),
            address(this),
            dispatcher,
            FeeVaultV3.Split(0, 10000, 0, 0),
            rewards,
            weights
        );
        vault.setCurve(address(this));
        token.initialize("Fork only", "FORK", 0, 0, address(this), address(vault), rewards, new address[](0));
        address holder = makeAddr("commodity-fork-holder");
        token.transfer(holder, 100 ether);
        deal(CORN, address(vault), 1 ether);
        vault.onFee(1 ether);
        uint256[] memory mins = new uint256[](1);
        mins[0] = minimum(CORN, COFFEE, 1 ether);
        vault.buyBasket(mins);
        uint256 funded = IERC20(COFFEE).balanceOf(address(token));
        assertGe(funded, mins[0]);
        assertEq(token.totalDistributed(COFFEE), funded);
        vm.prank(holder);
        token.claimRewards();
        uint256 claimed = token.totalClaimed(COFFEE);
        assertGt(claimed, 0);
        assertEq(IERC20(COFFEE).balanceOf(holder), claimed);
        assertEq(IERC20(COFFEE).balanceOf(address(token)), funded - claimed);
        assertEq(vault.basketPending(), 0);
    }

    function hookFor(UniswapV4GraduationHandlerV3 handler) private returns (BarkHookV3) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(BarkHookV3).creationCode, abi.encode(IPoolManager(POOL_MANAGER), address(handler)))
        );
        uint160 flags = V4.BEFORE_INITIALIZE_FLAG | V4.BEFORE_SWAP_FLAG | V4.AFTER_SWAP_FLAG
            | V4.BEFORE_SWAP_RETURNS_DELTA_FLAG | V4.AFTER_SWAP_RETURNS_DELTA_FLAG;
        for (uint256 i; i < 1_000_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (uint160(predicted) & V4.ALL_HOOK_MASK == flags) {
                return new BarkHookV3{salt: salt}(IPoolManager(POOL_MANAGER), address(handler));
            }
        }
        revert("hook salt missing");
    }

    function launch(address quoteAsset, address reward, bool direct)
        private
        returns (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault, UniswapV4GraduationHandlerV3 handler)
    {
        handler = new UniswapV4GraduationHandlerV3(IPoolManager(POOL_MANAGER), treasury);
        v4.setHandler(handler);
        CommodityLaunchpadV3.QuotePolicy[] memory policies =
            new CommodityLaunchpadV3.QuotePolicy[](reward == quoteAsset ? 1 : 2);
        policies[0] = CommodityLaunchpadV3.QuotePolicy(quoteAsset, 1 ether, 2 ether, 0.1 ether);
        if (reward != quoteAsset) policies[1] = CommodityLaunchpadV3.QuotePolicy(reward, 1 ether, 2 ether, 0.1 ether);
        CommodityLaunchpadV3 pad = direct
            ? CommodityLaunchpadV3(new CommodityDirectRewardLaunchpadV3(treasury, handler, dispatcher, policies))
            : new CommodityLaunchpadV3(treasury, handler, dispatcher, policies);
        handler.bind(hookFor(handler), address(pad));
        LaunchpadV3.Launch memory p;
        p.name = "Local fork lifecycle";
        p.symbol = "FORK";
        p.quoteAsset = quoteAsset;
        p.virtualQuote = 1 ether;
        p.graduationQuote = 2 ether;
        p.buyTaxBps = 300;
        p.sellTaxBps = 500;
        p.split = direct ? FeeVaultV3.Split(3000, 7000, 0, 0) : FeeVaultV3.Split(3000, 6000, 0, 1000);
        p.basketTokens = new address[](1);
        p.basketTokens[0] = reward;
        p.basketWeights = new uint16[](1);
        p.basketWeights[0] = 10000;
        p.firstBuyQuote = 0.1 ether;
        p.minFirstBuyOut = 1;
        p.deadline = block.timestamp + 60;
        uint256 fee = pad.CREATION_FEE();
        vm.deal(creator, fee);
        deal(quoteAsset, creator, 0.1 ether);
        vm.startPrank(creator);
        IERC20(quoteAsset).approve(address(pad), 0.1 ether);
        (address t, address c, address v) = pad.create{value: fee}(p);
        vm.stopPrank();
        token = MemeTokenV3(t);
        curve = BondingCurveV3(payable(c));
        vault = FeeVaultV3(payable(v));
        assertGt(token.balanceOf(creator), 0);
        assertEq(treasury.balance, fee);
        assertEq(IERC20(quoteAsset).allowance(creator, address(pad)), 0);
        assertEq(address(vault.adapter()), address(dispatcher));
    }

    function curveBuy(BondingCurveV3 curve, address buyer, uint256 amount) private {
        address quoteAsset = curve.quote();
        deal(quoteAsset, buyer, amount);
        (uint256 expected,,,) = curve.quoteBuy(amount, buyer);
        assertGt(expected, 0);
        vm.startPrank(buyer);
        IERC20(quoteAsset).approve(address(curve), amount);
        assertGe(curve.buy(amount, expected * 99 / 100, buyer), expected * 99 / 100);
        vm.stopPrank();
    }

    function v4Minimum(PoolKey memory key, address input, uint256 amount) private returns (uint256) {
        assertEq(ICommodityForkV4Quoter(V4_QUOTER).poolManager(), POOL_MANAGER);
        (uint256 out,) = ICommodityForkV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(ICommodityForkV4Quoter.Params(key, input == key.currency0, uint128(amount), ""));
        uint256 floor = out * 99 / 100;
        assertGt(floor, 0);
        return floor;
    }

    function marketTrades(MemeTokenV3 token, FeeVaultV3 vault, PoolKey memory key) private {
        address quoteAsset = vault.quote();
        uint256 floor = v4Minimum(key, quoteAsset, 0.1 ether);
        uint256 beforeFee = vault.lifetimeFees();
        deal(quoteAsset, alice, 0.1 ether);
        vm.startPrank(alice);
        IERC20(quoteAsset).approve(address(dispatcher), 0.1 ether);
        dispatcher.swapExactIn(quoteAsset, address(token), 0.1 ether, floor, alice);
        vm.stopPrank();
        assertEq(vault.lifetimeFees() - beforeFee, 0.003 ether);
        uint256 selling = token.balanceOf(alice) / 10;
        floor = v4Minimum(key, address(token), selling);
        uint256 beforeQuote = IERC20(quoteAsset).balanceOf(alice);
        beforeFee = vault.lifetimeFees();
        vm.startPrank(alice);
        token.approve(address(dispatcher), selling);
        uint256 received = dispatcher.swapExactIn(address(token), quoteAsset, selling, floor, alice);
        vm.stopPrank();
        assertEq(IERC20(quoteAsset).balanceOf(alice) - beforeQuote, received);
        assertGt(vault.lifetimeFees(), beforeFee);
        assertEq(IERC20(quoteAsset).balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(dispatcher)), 0);
    }

    function lifecycle(address quoteAsset, address reward, bool direct) private {
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault, UniswapV4GraduationHandlerV3 handler) =
            launch(quoteAsset, reward, direct);
        curveBuy(curve, alice, 1 ether);
        assertFalse(curve.graduated());
        curveBuy(curve, bob, 1.5 ether);
        assertTrue(curve.graduated());
        assertTrue(handler.pooled(address(token)));
        assertEq(curve.pool(), POOL_MANAGER);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(IERC20(quoteAsset).balanceOf(address(curve)), curve.treasuryEarned());
        PoolKey memory key = handler.poolKeyOf(address(token));
        marketTrades(token, vault, key);
        // V4 hook fees are already quote-denominated; do not manufacture meme tax.
        assertEq(vault.memePending(), 0);
        fundAndClaim(token, vault, reward);
        if (direct) {
            exitGraduatedHolder(token, vault, key, creator);
            exitGraduatedHolder(token, vault, key, alice);
            exitGraduatedHolder(token, vault, key, bob);
            assertEq(token.balanceOf(creator) + token.balanceOf(alice) + token.balanceOf(bob), 0);
            assertEq(vault.burnPending(), 0);
            vm.expectRevert(FeeVaultV3.NOTHING_PENDING.selector);
            vault.buybackAndBurn(1);
            vm.expectRevert(FeeVaultV3.NOTHING_PENDING.selector);
            vault.settleTax(1);
        } else {
            buyback(token, vault, key);
        }
        uint256 creatorPending = token.pending(creator, reward);
        uint256 beforeClaim = IERC20(reward).balanceOf(creator);
        assertGt(creatorPending, 0);
        vm.prank(creator);
        token.claimRewards();
        assertEq(IERC20(reward).balanceOf(creator) - beforeClaim, creatorPending);
        assertEq(
            IERC20(quoteAsset).balanceOf(address(vault)),
            vault.creatorEarned() + vault.basketPending() + vault.jackpotPot() + vault.burnPending()
                + vault.totalJackpotOwed()
        );
        collectFees(token, vault, handler, key);
        emit log_named_uint("actual reward claimed", token.totalClaimed(reward));
    }

    function exitGraduatedHolder(MemeTokenV3 token, FeeVaultV3 vault, PoolKey memory key, address holder) private {
        address quoteAsset = vault.quote();
        uint256 selling = token.balanceOf(holder);
        assertGt(selling, 0);
        uint256 owedBefore = token.pending(holder, quoteAsset);
        uint256 floor = v4Minimum(key, address(token), selling);
        uint256 beforeQuote = IERC20(quoteAsset).balanceOf(holder);
        vm.startPrank(holder);
        token.approve(address(dispatcher), selling);
        uint256 received = dispatcher.swapExactIn(address(token), quoteAsset, selling, floor, holder);
        vm.stopPrank();
        assertGe(received, floor);
        assertEq(IERC20(quoteAsset).balanceOf(holder) - beforeQuote, received);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.pending(holder, quoteAsset), owedBefore, "exit preserves allocated rewards");
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(IERC20(quoteAsset).balanceOf(address(dispatcher)), 0);
        emit log_named_address("fully exited holder", holder);
        emit log_named_uint("actual exit quote received", received);
    }

    function buyback(MemeTokenV3 token, FeeVaultV3 vault, PoolKey memory key) private {
        address quoteAsset = vault.quote();
        uint256 supply = token.totalSupply();
        uint256 budget = vault.burnPending();
        uint256 beforeFees = vault.lifetimeFees();
        vault.buybackAndBurn(v4Minimum(key, quoteAsset, budget));
        assertLt(token.totalSupply(), supply);
        // V4 applies the immutable buy tax to the buyback too. That new fee creates
        // a small new burn budget; it is not a failed consumption of the old budget.
        uint256 fee = vault.lifetimeFees() - beforeFees;
        assertEq(fee, budget * 300 / 10000);
        assertEq(vault.burnPending(), fee - fee * 3000 / 10000 - fee * 6000 / 10000);
        assertLt(vault.burnPending(), budget);
    }

    function fundAndClaim(MemeTokenV3 token, FeeVaultV3 vault, address reward) private {
        address quoteAsset = vault.quote();
        uint256 budget = vault.basketPending();
        uint256[] memory mins = new uint256[](1);
        mins[0] = reward == quoteAsset ? 1 : minimum(quoteAsset, reward, budget);
        vault.buyBasket(mins);
        uint256 funded = IERC20(reward).balanceOf(address(token));
        assertGe(funded, mins[0]);
        if (reward == quoteAsset) assertEq(funded, budget);
        assertEq(token.totalDistributed(reward), funded);
        assertEq(token.pending(POOL_MANAGER, reward), 0);
        assertEq(vault.basketPending(), 0);
        vm.prank(alice);
        token.claimRewards();
        vm.prank(bob);
        token.claimRewards();
        assertGt(token.totalClaimed(reward), 0);
        assertEq(IERC20(reward).balanceOf(address(token)), funded - token.totalClaimed(reward));
        emit log_named_address("quote asset", quoteAsset);
        emit log_named_address("reward asset", reward);
        emit log_named_uint("actual reward funded", funded);
    }

    function collectFees(MemeTokenV3 token, FeeVaultV3 vault, UniswapV4GraduationHandlerV3 handler, PoolKey memory key)
        private
    {
        address quoteAsset = vault.quote();
        uint256 beforeCreator = IERC20(quoteAsset).balanceOf(creator);
        uint256 creatorFee = vault.creatorEarned();
        vault.claimCreator();
        assertEq(IERC20(quoteAsset).balanceOf(creator) - beforeCreator, creatorFee);
        uint256 quoteFeesBefore = IERC20(quoteAsset).balanceOf(treasury);
        uint256 memeFeesBefore = token.balanceOf(treasury);
        (uint256 f0, uint256 f1) = handler.collectFees(address(token));
        assertGt(f0 + f1, 0);
        assertEq(IERC20(quoteAsset).balanceOf(treasury) - quoteFeesBefore, key.currency0 == quoteAsset ? f0 : f1);
        assertEq(token.balanceOf(treasury) - memeFeesBefore, key.currency0 == quoteAsset ? f1 : f0);
    }

    function test_realCoffeeLaunchGraduationTradingIncomeAndExit() public {
        lifecycle(COFFEE, COFFEE, false);
    }

    function test_realCoffeeLaunchWithCornConversionAndHolderClaims() public {
        lifecycle(COFFEE, CORN, false);
    }

    // Reduced 1/2/0.1 quote units validate the actual ZC path, not production 500/2000/100 economics.
    function test_realCornDirectRewardCandidateGraduationTradingIncomeAndExit() public {
        lifecycle(CORN, CORN, true);
    }

    function test_realDirectRewardCandidateGraduationTradingIncomeAndExit() public {
        lifecycle(COFFEE, COFFEE, true);
    }
}
