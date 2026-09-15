// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {BarkToken} from "../src/BarkToken.sol";
import {IGraduationHandler} from "../src/interfaces.sol";

contract MockGradHandler is IGraduationHandler {
    address public constant POOL = address(0xB00);
    uint256 public gradCalls;
    address public lastToken;
    uint256 public lastTokenLiquidity;
    uint256 public lastEth;

    function graduate(address token, uint256 tokenLiquidity) external payable override returns (address) {
        gradCalls++;
        lastToken = token;
        lastTokenLiquidity = tokenLiquidity;
        lastEth = msg.value;
        return POOL;
    }
}

/// @dev Phase 2 骨架测试:曲线数学 / 反貔貅 / 分成 / 毕业 / 公平发射 / 无特权
contract BondingCurveTest is Test {
    BondingFactory factory;
    MockGradHandler handler;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BarkToken token;
    BondingCurve curve;

    function setUp() public {
        handler = new MockGradHandler();
        factory = new BondingFactory(treasury, handler);
        (address t, address c,) = _create(BarkToken.Template.None, 0);
        token = BarkToken(t);
        curve = BondingCurve(payable(c));
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _create(BarkToken.Template tpl, uint16 taxBps)
        internal
        returns (address t, address c, address r)
    {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        return factory.createToken{value: 0.001 ether}("Test Meme", "TEST", tpl, taxBps, address(0), address(0), address(0));
    }

    // ─── 公平发射 ───────────────────────────────────────
    function test_FairLaunch_FullSupplyToCurve_NoCreatorAllocation() public view {
        assertEq(token.balanceOf(address(curve)), token.totalSupply());
        assertEq(token.balanceOf(creator), 0, "creator no allocation");
        assertEq(token.balanceOf(address(factory)), 0, "factory no allocation");
        assertEq(treasury.balance, 0.001 ether, "creation fee to treasury");
    }

    // ─── 曲线交易 ───────────────────────────────────────
    function test_Buy_ReceiveTokens_PriceRises() public {
        uint256 out1 = curve.quoteBuy(0.99 ether); // 1% 费后净额参与定价
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 out2 = curve.quoteBuy(0.99 ether);
        assertGt(out1, 0);
        assertGt(out1, out2, "price must rise: same ETH buys fewer tokens");
        assertEq(token.balanceOf(alice), out1);
    }

    function test_Sell_AlwaysWorks_AfterBuy_AntiHoneypot() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 bal = token.balanceOf(alice);

        // 立即可卖(无锁、无暂停、无权限)—— 反貔貅核心不变量
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(curve), bal);
        uint256 ethOut = curve.sell(bal, 0);
        vm.stopPrank();
        assertGt(ethOut, 0);
        assertEq(alice.balance - ethBefore, ethOut);
    }

    function test_Fees_Split50_50_CreatorAndTreasury() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0); // fee 0.01 ETH

        assertEq(curve.creatorEarned(), 0.005 ether, "creator 50% of fee");
        assertEq(curve.treasuryEarned(), 0.005 ether, "treasury 50% of fee");

        uint256 cBefore = creator.balance;
        curve.claimCreator();
        assertEq(creator.balance - cBefore, 0.005 ether, "creator claims ETH, no lock");

        uint256 tBefore = treasury.balance;
        curve.claimTreasury();
        assertEq(treasury.balance - tBefore, 0.005 ether);
    }

    /// 对账不变量:余额 = 支撑储备 + 应付创作者 + 应付平台(无凭空增发)
    function test_Invariant_BackingCoversAllObligations() public {
        vm.startPrank(alice);
        curve.buy{value: 5 ether}(0);
        uint256 bal = token.balanceOf(alice);
        token.approve(address(curve), bal);
        curve.sell(bal / 2, 0);
        vm.stopPrank();

        assertEq(
            address(curve).balance,
            curve.backingReserve() + curve.creatorEarned() + curve.treasuryEarned(),
            "reserve reconciliation"
        );
    }

    // ─── 毕业 ───────────────────────────────────────────
    function test_Graduation_AtomicMigrationToPool() public {
        vm.prank(alice);
        curve.buy{value: 26 ether}(0); // 净 25.74 ETH ≥ 阈值 25

        uint256 expectedEth = curve.backingReserve();
        uint256 expectedTokens = token.balanceOf(address(curve));

        address newPool = curve.graduate();

        assertEq(newPool, handler.POOL());
        assertTrue(curve.graduated());
        assertEq(handler.gradCalls(), 1);
        assertEq(handler.lastEth(), expectedEth, "all backing ETH migrates");
        assertEq(handler.lastTokenLiquidity(), expectedTokens);
        assertEq(token.balanceOf(newPool), expectedTokens, "all tokens migrate to pool");
        // 毕业只迁走支撑储备;已计提手续费留待 claim
        assertEq(address(curve).balance, curve.creatorEarned() + curve.treasuryEarned(), "only fees remain");
        assertEq(curve.backingReserve(), 0, "no backing left");
    }

    function test_Graduation_RevertsBelowThreshold() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        vm.expectRevert(BondingCurve.BELOW_THRESHOLD.selector);
        curve.graduate();
    }

    function test_AfterGraduation_TradingStops() public {
        vm.startPrank(alice);
        curve.buy{value: 26 ether}(0);
        curve.graduate();
        vm.expectRevert(BondingCurve.GRADUATED.selector);
        curve.buy{value: 0.1 ether}(0);
        vm.stopPrank();
    }

    // ─── 工厂护栏 ───────────────────────────────────────
    function test_Revert_TaxAboveCap() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(BondingFactory.TAX_TOO_HIGH.selector);
        factory.createToken{value: 0.001 ether}("X", "X", BarkToken.Template.Creator, 301, address(0), address(0), address(0));
    }

    function test_Revert_CreationFeeRequired() public {
        vm.prank(creator);
        vm.expectRevert(BondingFactory.FEE_REQUIRED.selector);
        factory.createToken("X", "X", BarkToken.Template.None, 0, address(0), address(0), address(0));
    }

    function test_Bind_LockedAfterCreation() public {
        vm.expectRevert(BarkToken.BIND_LOCKED.selector);
        token.bind(address(0), address(0)); // 已 seal,任何人(含此处测试合约)不可再绑
    }
}
