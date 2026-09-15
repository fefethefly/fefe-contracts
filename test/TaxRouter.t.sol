// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {BarkToken} from "../src/BarkToken.sol";
import {CreatorTax} from "../src/routers/CreatorTax.sol";
import {StockVaultTax, IExchangeRouter} from "../src/routers/StockVaultTax.sol";
import {IGraduationHandler} from "../src/interfaces.sol";

contract MockStock is ERC20 {
    constructor() ERC20("xNVDA", "xNVDA") {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// 1 meme = rate 个 stock(演示汇率)
contract MockDex is IExchangeRouter {
    MockStock public immutable stock;
    uint256 public immutable rate;

    constructor(MockStock stock_, uint256 rate_) {
        stock = stock_;
        rate = rate_;
    }

    function swapExactIn(address, address toToken, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 outAmount)
    {
        require(toToken == address(stock), "BAD_PAIR");
        outAmount = amountIn * rate;
        require(outAmount >= minOut, "SLIPPAGE");
        stock.mint(recipient, outAmount);
    }
}

contract NoopGradHandler is IGraduationHandler {
    function graduate(address, uint256) external payable override returns (address) {
        return address(0xB00);
    }
}

/// @dev 可编程代币三模板(F9):比例 / 免税 / 不可篡改 / 分红守恒
contract TaxRouterTest is Test {
    BondingFactory factory;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    MockStock stock;
    MockDex dex;
    address stockVault = makeAddr("stockVault");

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        factory = new BondingFactory(treasury, new NoopGradHandler());
        stock = new MockStock();
        dex = new MockDex(stock, 2);
        vm.deal(alice, 100 ether);
        vm.deal(creator, 1 ether);
    }

    function _createTax(BarkToken.Template tpl, uint16 taxBps)
        internal
        returns (BarkToken t, BondingCurve c, address r)
    {
        return _createTax(tpl, taxBps, address(0), address(0), address(0));
    }

    function _createTax(BarkToken.Template tpl, uint16 taxBps, address st, address sv, address dx)
        internal
        returns (BarkToken t, BondingCurve c, address r)
    {
        vm.prank(creator);
        (address token_, address curve_, address router_) =
            factory.createToken{value: 0.001 ether}("Meme", "MEME", tpl, taxBps, st, sv, dx);
        return (BarkToken(token_), BondingCurve(payable(curve_)), router_);
    }

    /// alice 从 curve 买入(曲线阶段免税)
    function _seedAlice(BarkToken t, BondingCurve c, uint256 eth) internal {
        vm.startPrank(alice);
        c.buy{value: eth}(0);
        vm.stopPrank();
    }

    // ─── 模板 1:创作者税 60/30/10 ──────────────────────
    function test_CreatorTax_Split60_30_10() public {
        (BarkToken t, BondingCurve c, address r) = _createTax(BarkToken.Template.Creator, 100);
        _seedAlice(t, c, 1 ether);

        uint256 curveBalBefore = t.balanceOf(address(c));
        vm.prank(alice);
        t.transfer(bob, 1000e18); // 税 1% = 10e18

        CreatorTax router = CreatorTax(r);
        assertEq(router.creatorEarned(), 6e18, "creator 60%");
        assertEq(t.balanceOf(address(c)) - curveBalBefore, 3e18, "curve +30%");
        assertEq(t.balanceOf(DEAD), 1e18, "burn 10%");
        assertEq(t.balanceOf(bob), 990e18);

        uint256 creatorBefore = t.balanceOf(creator);
        router.claimCreator();
        assertEq(t.balanceOf(creator) - creatorBefore, 6e18, "claim, no lock");
    }

    // ─── 模板 3:股票金库 50/25/25 + 回购囤股 ────────────
    function test_StockVault_SplitAndBuyback() public {
        (BarkToken t, BondingCurve c, address r) =
            _createTax(BarkToken.Template.StockVault, 100, address(stock), stockVault, address(dex));
        _seedAlice(t, c, 1 ether);

        uint256 curveBalBefore = t.balanceOf(address(c));
        vm.prank(alice);
        t.transfer(bob, 1000e18); // 税 10e18

        StockVaultTax router = StockVaultTax(r);
        assertEq(router.pendingBuyback(), 5e18, "vault pending 50%");
        assertEq(router.creatorEarned(), 2.5e18, "creator 25%");
        assertEq(t.balanceOf(address(c)) - curveBalBefore, 2.5e18, "curve 25%");

        // 任何人可执行回购:5e18 meme × 汇率2 = 10e18 股票进金库
        uint256 out = router.executeBuyback(9e18);
        assertEq(out, 10e18);
        assertEq(stock.balanceOf(stockVault), 10e18, "stock lands in vault");
        assertEq(router.totalStockAccumulated(), 10e18);
        assertEq(router.pendingBuyback(), 0);

        vm.expectRevert(StockVaultTax.NOTHING_PENDING.selector);
        router.executeBuyback(0);
    }

    // ─── 模板 2:持有者分红,按持仓比例且守恒 ────────────
    function test_HolderYield_ProportionalAndConserved() public {
        (BarkToken t, BondingCurve c,) = _createTax(BarkToken.Template.Holder, 100);
        _seedAlice(t, c, 1 ether);

        vm.startPrank(alice);
        t.transfer(bob, 400e18); // 第一笔税
        vm.stopPrank();

        vm.prank(bob);
        t.transfer(alice, 100e18); // 第二笔税(pending 按转后持仓累积)

        uint256 aBal = t.balanceOf(alice);
        uint256 bBal = t.balanceOf(bob);
        uint256 aPend = t.pendingYield(alice);
        uint256 bPend = t.pendingYield(bob);

        // 比例:pending ∝ 持仓(2% 容差,含舍入)
        assertApproxEqRel(aPend * bBal, bPend * aBal, 0.02e18, "yield proportional to balance");

        // 守恒:总领取 ≤ 税池存量;领取后差额精确等于已领取
        uint256 taxHeldBefore = t.balanceOf(address(t));
        vm.prank(alice);
        t.claimHolderYield();
        vm.prank(bob);
        t.claimHolderYield();
        assertApproxEqAbs(t.balanceOf(address(t)), taxHeldBefore - (aPend + bPend), 2, "conservation");
        assertGt(t.balanceOf(alice), aBal, "claimed credited");
    }

    // ─── 免税与无税 ─────────────────────────────────────
    function test_TransferToCurve_Untaxed() public {
        (BarkToken t, BondingCurve c,) = _createTax(BarkToken.Template.Creator, 100);
        _seedAlice(t, c, 1 ether);

        uint256 half = t.balanceOf(alice) / 2;
        uint256 curveBefore = t.balanceOf(address(c));
        vm.prank(alice);
        t.transfer(address(c), half); // to = curve 豁免
        assertEq(t.balanceOf(address(c)) - curveBefore, half, "exempt receiver: no tax");
    }

    function test_CurveTrades_Untaxed_VaultTemplateToo() public {
        (BarkToken t, BondingCurve c, address r) =
            _createTax(BarkToken.Template.StockVault, 100, address(stock), stockVault, address(dex));
        uint256 expectOut = c.quoteBuy(0.99 ether); // 1% 费后净额
        vm.startPrank(alice);
        c.buy{value: 1 ether}(0);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), expectOut, "curve buy untaxed");
        assertEq(StockVaultTax(r).pendingBuyback(), 0, "no tax accrued during curve trade");
    }

    function test_NoneTemplate_ZeroTax() public {
        (BarkToken t, BondingCurve c,) = _createTax(BarkToken.Template.None, 0);
        _seedAlice(t, c, 1 ether);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        t.transfer(bob, bal);
        assertEq(t.balanceOf(bob), bal, "no tax");
    }

    // ─── 不可篡改 ───────────────────────────────────────
    function test_Router_CurveImmutable_AfterBind() public {
        (,, address r) = _createTax(BarkToken.Template.Creator, 100);
        vm.expectRevert(CreatorTax.BIND_LOCKED.selector);
        CreatorTax(r).setCurve(address(0x123));
    }

    function test_StockParams_RequiredOnlyForVault() public {
        // 非金库模板传股票参数 → 拒绝
        vm.prank(creator);
        vm.expectRevert(BondingFactory.STOCK_ONLY_FOR_VAULT.selector);
        factory.createToken{value: 0.001 ether}("X", "X", BarkToken.Template.Creator, 100, address(stock), stockVault, address(dex));

        // 金库模板缺参数 → 拒绝
        vm.prank(creator);
        vm.expectRevert(BondingFactory.STOCK_PARAMS.selector);
        factory.createToken{value: 0.001 ether}("X", "X", BarkToken.Template.StockVault, 100, address(0), stockVault, address(dex));
    }
}
