// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CommodityAdapterFixture} from "./CommoditySwapAdapterV3.t.sol";
import {DispatcherTestPoolManager} from "./MarketSwapDispatcherV3.t.sol";
import {CommodityLaunchpadV3} from "../src/v3/CommodityLaunchpadV3.sol";
import {CommodityDirectRewardLaunchpadV3} from "../src/v3/CommodityDirectRewardLaunchpadV3.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {CommodityOracleGuardV3} from "../src/v3/uniswap/CommodityOracleGuardV3.sol";
import {MarketSwapDispatcherV3, IMarketRouteAdapterV3} from "../src/v3/uniswap/MarketSwapDispatcherV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {IPoolManager, V4} from "../src/v3/uniswap/V4Types.sol";

contract CommodityLaunchpadV3Test is CommodityAdapterFixture {
    CommodityLaunchpadV3 pad;
    UniswapV4GraduationHandlerV3 handler;
    UniswapV4SwapAdapterV3 v4;
    MarketSwapDispatcherV3 dispatcher;
    BarkHookV3 hook;
    address treasury = address(0x777);
    uint256 creationFee;

    function policies() internal view returns (CommodityLaunchpadV3.QuotePolicy[] memory p) {
        p = new CommodityLaunchpadV3.QuotePolicy[](2);
        p[0] = CommodityLaunchpadV3.QuotePolicy(address(corn), 10 ether, 100 ether, 5 ether);
        p[1] = CommodityLaunchpadV3.QuotePolicy(address(coffee), 10 ether, 100 ether, 5 ether);
    }

    function setUp() public override {
        vm.chainId(4663);
        super.setUp();
        IPoolManager pm = IPoolManager(address(new DispatcherTestPoolManager()));
        handler = new UniswapV4GraduationHandlerV3(pm, treasury);
        v4 = new UniswapV4SwapAdapterV3(pm, address(this));
        v4.setHandler(handler);
        dispatcher = new MarketSwapDispatcherV3(adapter, IMarketRouteAdapterV3(address(v4)));
        pad = new CommodityLaunchpadV3(treasury, handler, dispatcher, policies());
        creationFee = pad.CREATION_FEE();
        hook = deployHook(pm);
        handler.bind(hook, address(pad));
        corn.mint(bob, 100 ether);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        corn.approve(address(pad), type(uint256).max);
        vm.stopPrank();
    }

    function deployHook(IPoolManager pm) internal returns (BarkHookV3) {
        bytes32 initHash = keccak256(abi.encodePacked(type(BarkHookV3).creationCode, abi.encode(pm, address(handler))));
        uint160 flags = V4.BEFORE_INITIALIZE_FLAG | V4.BEFORE_SWAP_FLAG | V4.AFTER_SWAP_FLAG
            | V4.BEFORE_SWAP_RETURNS_DELTA_FLAG | V4.AFTER_SWAP_RETURNS_DELTA_FLAG;
        for (uint256 i; i < 1_000_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (uint160(predicted) & V4.ALL_HOOK_MASK == flags) {
                return new BarkHookV3{salt: salt}(pm, address(handler));
            }
        }
        revert("test hook salt missing");
    }

    function params() internal view returns (LaunchpadV3.Launch memory p) {
        p.name = "From a seed";
        p.symbol = "SEED";
        p.quoteAsset = address(corn);
        p.virtualQuote = 10 ether;
        p.graduationQuote = 100 ether;
        p.buyTaxBps = 300;
        p.sellTaxBps = 500;
        p.split = FeeVaultV3.Split(3000, 6000, 0, 1000);
        p.basketTokens = new address[](1);
        p.basketTokens[0] = address(coffee);
        p.basketWeights = new uint16[](1);
        p.basketWeights[0] = 10000;
        p.salt = bytes32(uint256(42));
        p.firstBuyQuote = 1 ether;
        p.minFirstBuyOut = 1;
        p.deadline = block.timestamp + 60;
    }

    function create(LaunchpadV3.Launch memory p)
        internal
        returns (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault)
    {
        vm.prank(alice);
        (address t, address c, address v) = pad.create{value: creationFee}(p);
        return (MemeTokenV3(t), BondingCurveV3(payable(c)), FeeVaultV3(payable(v)));
    }

    function assertNoCreation() internal view {
        assertEq(pad.tokenCount(), 0);
        assertEq(treasury.balance, 0);
        assertEq(corn.balanceOf(alice), 100 ether);
    }

    function test_createBindsActualStackAndPredictsSenderOwnedAddress() public {
        pad.validateStack();
        LaunchpadV3.Launch memory p = params();
        address predicted = pad.predictToken(alice, p.salt);
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(p);
        assertEq(address(token), predicted);
        assertEq(address(vault.adapter()), address(dispatcher));
        assertEq(address(curve.gradHandler()), address(handler));
        assertEq(address(pad.oracleGuard()), address(guard));
        assertEq(pad.releasedAssetCount(), 2);
        assertEq(pad.TOKEN_INIT_CODE_HASH(), keccak256(type(MemeTokenV3).creationCode));
        assertEq(
            pad.policyHash(),
            keccak256(abi.encode(block.chainid, treasury, address(handler), address(dispatcher), policies()))
        );
        assertEq(treasury.balance, pad.CREATION_FEE());
        assertGt(token.balanceOf(alice), 0);
        assertEq(vault.lifetimeFees(), 0);
    }

    function test_creationToTradingFeeToCommodityRewardToClaim() public {
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(params());
        vm.startPrank(bob);
        corn.approve(address(curve), 1 ether);
        curve.buy(1 ether, 1, bob);
        vm.stopPrank();
        uint256 budget = vault.basketPending();
        assertEq(budget, 0.018 ether);
        uint256[] memory mins = new uint256[](1);
        mins[0] = budget;
        vault.buyBasket(mins);
        assertEq(token.totalDistributed(address(coffee)), budget);
        assertEq(vault.basketPending(), 0);
        uint256 beforeAlice = coffee.balanceOf(alice);
        vm.prank(alice);
        token.claimRewards();
        vm.prank(bob);
        token.claimRewards();
        uint256 claimed = token.totalClaimed(address(coffee));
        assertGt(coffee.balanceOf(alice), beforeAlice);
        assertGt(coffee.balanceOf(bob), 0);
        assertLe(claimed, budget);
        assertEq(coffee.balanceOf(address(token)), budget - claimed);
        assertEq(corn.allowance(address(dispatcher), address(adapter)), 0);
    }

    function test_quoteAndRewardMustBothBeExplicitlyReleased() public {
        LaunchpadV3.Launch memory p = params();
        p.quoteAsset = address(usdg);
        vm.expectRevert(CommodityLaunchpadV3.ASSET_NOT_RELEASED.selector);
        create(p);
        p = params();
        p.basketTokens[0] = address(usdg);
        vm.expectRevert(CommodityLaunchpadV3.ASSET_NOT_RELEASED.selector);
        create(p);
        assertNoCreation();
    }

    function test_fixedCurveAndFirstBuyCeilingCannotBeOverridden() public {
        LaunchpadV3.Launch memory p = params();
        p.virtualQuote++;
        vm.expectRevert(CommodityLaunchpadV3.CURVE_POLICY_MISMATCH.selector);
        create(p);
        p = params();
        p.graduationQuote++;
        vm.expectRevert(CommodityLaunchpadV3.CURVE_POLICY_MISMATCH.selector);
        create(p);
        p = params();
        p.firstBuyQuote = 5 ether + 1;
        vm.expectRevert(CommodityLaunchpadV3.FIRST_BUY_LIMIT.selector);
        create(p);
        assertNoCreation();
    }

    function test_pausedOrExpiredSourceStopsBeforeFeeOrTokenCreation() public {
        feed.setPaused(true);
        vm.expectRevert(CommodityOracleGuardV3.SOURCE_UNAVAILABLE.selector);
        create(params());
        feed.setPaused(false);
        vm.warp(block.timestamp + 300);
        vm.expectRevert(CommodityOracleGuardV3.STALE_OBSERVATION.selector);
        create(params());
        assertNoCreation();
    }

    function test_bindingToAnotherLaunchpadOrWrongChainIsRejected() public {
        CommodityLaunchpadV3 other = new CommodityLaunchpadV3(treasury, handler, dispatcher, policies());
        uint256 fee = other.CREATION_FEE();
        LaunchpadV3.Launch memory p = params();
        vm.prank(alice);
        vm.expectRevert(CommodityLaunchpadV3.STACK_NOT_BOUND.selector);
        other.create{value: fee}(p);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(CommodityLaunchpadV3.STACK_NOT_BOUND.selector);
        create(p);
        assertNoCreation();
    }

    function test_sameAssetRewardsNeedNoConversionRoute() public {
        LaunchpadV3.Launch memory p = params();
        p.basketTokens[0] = address(corn);
        (MemeTokenV3 token, BondingCurveV3 curve, FeeVaultV3 vault) = create(p);
        vm.startPrank(bob);
        corn.approve(address(curve), 1 ether);
        curve.buy(1 ether, 1, bob);
        vm.stopPrank();
        uint256[] memory mins = new uint256[](1);
        mins[0] = vault.basketPending();
        vault.buyBasket(mins);
        assertEq(token.totalDistributed(address(corn)), mins[0]);
    }

    function test_failedFirstBuyRollsBackAllContractsFeeAndAllowance() public {
        LaunchpadV3.Launch memory p = params();
        p.minFirstBuyOut = type(uint256).max;
        address predicted = pad.predictToken(alice, p.salt);
        vm.expectRevert();
        create(p);
        assertNoCreation();
        assertEq(predicted.code.length, 0);
        assertEq(corn.balanceOf(address(pad)), 0);
    }

    function test_constructorRejectsDuplicatePolicyBadCapsAndTreasury() public {
        CommodityLaunchpadV3.QuotePolicy[] memory p = policies();
        p[1] = p[0];
        vm.expectRevert(CommodityLaunchpadV3.BAD_RELEASE_CONFIG.selector);
        new CommodityLaunchpadV3(treasury, handler, dispatcher, p);
        p = policies();
        p[0].maxFirstBuy = p[0].graduationQuote + 1;
        vm.expectRevert(CommodityLaunchpadV3.BAD_RELEASE_CONFIG.selector);
        new CommodityLaunchpadV3(treasury, handler, dispatcher, p);
        vm.expectRevert(CommodityLaunchpadV3.BAD_RELEASE_CONFIG.selector);
        new CommodityLaunchpadV3(address(99), handler, dispatcher, policies());
    }

    function installDirect() internal returns (LaunchpadV3.Launch memory p) {
        IPoolManager pm = IPoolManager(address(new DispatcherTestPoolManager()));
        handler = new UniswapV4GraduationHandlerV3(pm, treasury);
        v4 = new UniswapV4SwapAdapterV3(pm, address(this));
        v4.setHandler(handler);
        dispatcher = new MarketSwapDispatcherV3(adapter, IMarketRouteAdapterV3(address(v4)));
        pad = new CommodityDirectRewardLaunchpadV3(treasury, handler, dispatcher, policies());
        hook = deployHook(pm);
        handler.bind(hook, address(pad));
        vm.prank(alice);
        corn.approve(address(pad), type(uint256).max);
        p = params();
        p.basketTokens[0] = address(corn);
        p.split = FeeVaultV3.Split(3000, 7000, 0, 0);
    }
}
