// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LaunchpadV2} from "../src/v2/LaunchpadV2.sol";
import {BondingCurveV2} from "../src/v2/BondingCurveV2.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {LaunchRouter} from "../src/periphery/LaunchRouter.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {BarkToken} from "../src/BarkToken.sol";
import {CreatorTax} from "../src/routers/CreatorTax.sol";
import {StockVaultTax} from "../src/routers/StockVaultTax.sol";
import {IGraduationHandler} from "../src/interfaces.sol";
import {MockStock, MockDex} from "./TaxRouter.t.sol";

contract V2Grad is IGraduationHandler {
    function graduate(address, uint256) external payable returns (address) {
        return address(0xbeef);
    }
}

contract RejectFees {
    receive() external payable {
        revert();
    }
}

contract CreatorWalletV2 {
    BondingCurveV2 public curve;
    bool public rejectPayment;
    bool public reentered;
    bytes4 public callbackError;

    function launch(LaunchpadV2 pad, LaunchpadV2.Launch calldata p) external payable {
        (, address c,) = pad.create{value: msg.value}(p);
        curve = BondingCurveV2(payable(c));
    }

    function reject(bool value) external {
        rejectPayment = value;
    }

    receive() external payable {
        require(!rejectPayment, "REJECT_PAYMENT");
        bytes memory result;
        (reentered, result) = address(curve).call(abi.encodeCall(BondingCurveV2.claimCreator, ()));
        if (result.length >= 4) callbackError = bytes4(result);
    }
}

contract RejectGraduationV2 is IGraduationHandler {
    function graduate(address, uint256) external payable returns (address) {
        revert("GRADUATION_FAILED");
    }
}

contract LaunchpadV2Test is Test {
    LaunchpadV2 pad;
    V2Grad handler;
    address creator = makeAddr("actual creator");
    address trader = makeAddr("trader");
    address treasury = makeAddr("treasury");

    function setUp() public {
        handler = new V2Grad();
        pad = new LaunchpadV2(treasury, handler);
        vm.deal(creator, 100 ether);
        vm.deal(trader, 100 ether);
    }

    function plan(BarkToken.Template template) internal view returns (LaunchpadV2.Launch memory p) {
        p = LaunchpadV2.Launch(
            "Ocean Signal",
            "OCEAN",
            template,
            template == BarkToken.Template.None ? 0 : 100,
            address(0),
            address(0),
            address(0),
            0,
            block.timestamp + 300
        );
    }

    function create(BarkToken.Template template, uint256 firstBuy)
        internal
        returns (BarkToken t, BondingCurveV2 c, address r)
    {
        vm.prank(creator);
        (address a, address b, address route) = pad.create{value: 0.001 ether + firstBuy}(plan(template));
        return (BarkToken(a), BondingCurveV2(payable(b)), route);
    }

    function testLegacyForwarderOwnsFeesInsteadOfTheCaller() public {
        BondingFactory oldFactory = new BondingFactory(treasury, handler);
        LaunchRouter oldRouter = new LaunchRouter();
        vm.recordLogs();
        vm.prank(creator);
        oldRouter.tryCreate{value: 0.0011 ether}(
            address(oldFactory), "Legacy", "OLD", 1, 100, address(0), address(0), address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address curve;
        address route;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(oldRouter)
                    && logs[i].topics[0] == keccak256("Created(address,address,address,address)")
            ) (curve, route) = abi.decode(logs[i].data, (address, address));
        }
        assertEq(BondingCurve(payable(curve)).creator(), address(oldRouter));
        assertEq(CreatorTax(route).creator(), address(oldRouter));
        vm.expectRevert(BondingCurve.ETH_TRANSFER_FAIL.selector);
        BondingCurve(payable(curve)).claimCreator();
    }

    function testCreatorOwnsBothFeeStreamsAndReceivesFirstBuyWithoutSecondTax() public {
        uint256 paid = 0.01 ether;
        uint256 fee = paid / 100;
        uint256 expected = 1e27 * (paid - fee) / (0.5 ether + paid - fee);
        (BarkToken t, BondingCurveV2 c, address r) = create(BarkToken.Template.Creator, paid);
        assertEq(c.creator(), creator);
        assertEq(CreatorTax(r).creator(), creator);
        assertEq(t.balanceOf(creator), expected);
        assertEq(t.balanceOf(address(pad)), 0);
        assertEq(CreatorTax(r).creatorEarned(), 0);
        assertEq(c.creatorEarned(), fee / 2);
        uint256 before = creator.balance;
        c.claimCreator();
        assertEq(creator.balance - before, fee / 2);
        vm.prank(creator);
        t.transfer(trader, 10000);
        assertEq(CreatorTax(r).creatorEarned(), 60);
        uint256 tokenBefore = t.balanceOf(creator);
        CreatorTax(r).claimCreator();
        assertEq(t.balanceOf(creator) - tokenBefore, 60);
        assertEq(address(pad).balance, 0);
        assertEq(treasury.balance, 0.001 ether);
    }

    function testQuotesDoNotChangeWhenAccruedFeesAreClaimed() public {
        (BarkToken t, BondingCurveV2 c,) = create(BarkToken.Template.None, 1 ether);
        uint256 beforeBuy = c.quoteBuy(0.99 ether);
        uint256 beforeSell = c.quoteSell(t.balanceOf(creator) / 3);
        c.claimCreator();
        c.claimTreasury();
        assertEq(c.quoteBuy(0.99 ether), beforeBuy);
        assertEq(c.quoteSell(t.balanceOf(creator) / 3), beforeSell);
        vm.prank(trader);
        uint256 actual = c.buy{value: 1 ether}(beforeBuy);
        assertEq(actual, beforeBuy);
    }

    function testBuyWithUnclaimedFeesMatchesItsQuote() public {
        (, BondingCurveV2 c,) = create(BarkToken.Template.None, 1 ether);
        uint256 quote = c.quoteBuy(0.99 ether);
        vm.prank(trader);
        assertEq(c.buy{value: 1 ether}(quote), quote);
    }

    function testNoFirstBuyAllocatesAllSupplyToCurve() public {
        (BarkToken t, BondingCurveV2 c, address r) = create(BarkToken.Template.None, 0);
        assertEq(t.balanceOf(address(c)), t.totalSupply());
        assertEq(t.balanceOf(creator), 0);
        assertEq(r, address(0));
    }

    function testSlippageAndDeadlineRevertWholeLaunchWithoutTakingFee() public {
        LaunchpadV2.Launch memory p = plan(BarkToken.Template.Creator);
        p.minFirstBuyOut = type(uint256).max;
        vm.prank(creator);
        vm.expectRevert(BondingCurveV2.SLIPPAGE.selector);
        pad.create{value: 0.011 ether}(p);
        assertEq(treasury.balance, 0);
        assertEq(address(pad).balance, 0);
        p.minFirstBuyOut = 0;
        p.deadline = block.timestamp - 1;
        vm.prank(creator);
        vm.expectRevert(LaunchpadV2.EXPIRED.selector);
        pad.create{value: 0.001 ether}(p);
    }

    function testInvalidEconomicCombinationsAreRejected() public {
        LaunchpadV2.Launch memory p = plan(BarkToken.Template.Holder);
        vm.expectRevert(LaunchpadV2.INVALID_TEMPLATE.selector);
        pad.create{value: 0.001 ether}(p);
        p = plan(BarkToken.Template.None);
        p.taxBps = 100;
        vm.expectRevert(LaunchpadV2.INVALID_TAX.selector);
        pad.create{value: 0.001 ether}(p);
        p = plan(BarkToken.Template.Creator);
        p.stockToken = trader;
        vm.expectRevert(LaunchpadV2.INVALID_STOCK_PARAMS.selector);
        pad.create{value: 0.001 ether}(p);
        p = plan(BarkToken.Template.StockVault);
        vm.expectRevert(LaunchpadV2.INVALID_STOCK_PARAMS.selector);
        pad.create{value: 0.001 ether}(p);
    }

    function testStockDestinationIsExplicitAndCreatorIsNotLaunchpad() public {
        MockStock stock = new MockStock();
        MockDex dex = new MockDex(stock, 1);
        LaunchpadV2.Launch memory p = plan(BarkToken.Template.StockVault);
        p.stockToken = address(stock);
        p.dex = address(dex);
        p.stockRecipient = trader;
        vm.prank(creator);
        (,, address r) = pad.create{value: 0.001 ether}(p);
        assertEq(StockVaultTax(r).stockVault(), trader);
        assertEq(StockVaultTax(r).creator(), creator);
    }

    function testRejectedTreasuryPaymentRevertsLaunch() public {
        LaunchpadV2 rejected = new LaunchpadV2(address(new RejectFees()), handler);
        vm.prank(creator);
        vm.expectRevert(LaunchpadV2.TRANSFER_FAILED.selector);
        rejected.create{value: 0.001 ether}(plan(BarkToken.Template.None));
        assertEq(address(rejected).balance, 0);
    }

    function testCreatorCallbackCannotReenterClaimAndRejectedClaimRetainsLiability() public {
        CreatorWalletV2 wallet = new CreatorWalletV2();
        wallet.launch{value: 0.101 ether}(pad, plan(BarkToken.Template.None));
        BondingCurveV2 c = wallet.curve();
        uint256 claim = c.creatorEarned();
        wallet.reject(true);
        vm.expectRevert(BondingCurveV2.ETH_TRANSFER_FAIL.selector);
        c.claimCreator();
        assertEq(c.creatorEarned(), claim);
        wallet.reject(false);
        c.claimCreator();
        assertEq(address(wallet).balance, claim);
        assertFalse(wallet.reentered());
        assertEq(wallet.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(c.creatorEarned(), 0);
    }

    function testRevertedGraduationPreservesBackingTokensAndTrading() public {
        LaunchpadV2 other = new LaunchpadV2(treasury, new RejectGraduationV2());
        vm.prank(creator);
        (address t, address curve,) = other.create{value: 26.001 ether}(plan(BarkToken.Template.None));
        BondingCurveV2 c = BondingCurveV2(payable(curve));
        uint256 backing = c.backingReserve();
        uint256 held = BarkToken(t).balanceOf(curve);
        vm.expectRevert("GRADUATION_FAILED");
        c.graduate();
        assertEq(c.backingReserve(), backing);
        assertEq(BarkToken(t).balanceOf(curve), held);
        assertFalse(c.graduated());
        vm.startPrank(creator);
        BarkToken(t).approve(curve, 1 ether);
        c.sell(1 ether, 0);
        vm.stopPrank();
    }

    function testFuzzBackingSeparatesFeesAfterBuySell(uint96 paidRaw, uint16 fraction) public {
        uint256 paid = bound(uint256(paidRaw), 1e12, 10 ether);
        (BarkToken t, BondingCurveV2 c,) = create(BarkToken.Template.None, paid);
        uint256 sellAmount = t.balanceOf(creator) * bound(uint256(fraction), 1, 10000) / 10000;
        vm.startPrank(creator);
        t.approve(address(c), sellAmount);
        c.sell(sellAmount, 0);
        vm.stopPrank();
        assertEq(address(c).balance, c.backingReserve() + c.creatorEarned() + c.treasuryEarned());
        uint256 quote = c.quoteBuy(0.0099 ether);
        vm.prank(trader);
        assertEq(c.buy{value: 0.01 ether}(quote), quote);
    }
}
