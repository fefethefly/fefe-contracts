// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {IGraduationHandlerV3, ISwapAdapterV3, NATIVE} from "../src/v3/InterfacesV3.sol";

contract StockV3 is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Mints `tokenOut` 1:1 against whatever is paid in. Meme → quote returns 1/1000 (pretend price).
contract AdapterV3 is ISwapAdapterV3 {
    address public meme;
    uint256 public calls;

    function setMeme(address m) external {
        meme = m;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        payable
        returns (uint256 out)
    {
        ++calls;
        if (tokenIn == NATIVE) require(msg.value == amountIn, "value");
        else IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (tokenIn == meme) {
            out = amountIn / 1000;
            if (tokenOut == NATIVE) payable(recipient).transfer(out);
            else StockV3(tokenOut).mint(recipient, out);
        } else if (tokenOut == meme) {
            out = amountIn * 1000;
            IERC20(meme).transfer(recipient, out);
        } else {
            out = amountIn;
            StockV3(tokenOut).mint(recipient, out);
        }
    }

    receive() external payable {}
}

contract GradV3 is IGraduationHandlerV3 {
    address public pool = address(0xbeef);
    uint256 public quoteReceived;
    uint256 public tokenReceived;
    address public lastToken;

    function graduate(address token, address quote, uint256, uint256 tokenAmount)
        external
        payable
        returns (address, bool)
    {
        lastToken = token;
        quoteReceived = quote == NATIVE ? msg.value : IERC20(quote).balanceOf(address(this));
        tokenReceived = tokenAmount;
        require(IERC20(token).balanceOf(address(this)) == tokenAmount, "tokens");
        IERC20(token).transfer(pool, tokenAmount);
        return (pool, true);
    }
}

contract LaunchpadV3Test is Test {
    LaunchpadV3 pad;
    GradV3 grad;
    AdapterV3 adapter;
    StockV3 nvda;
    StockV3 tsla;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        grad = new GradV3();
        adapter = new AdapterV3();
        nvda = new StockV3("NVDA");
        tsla = new StockV3("TSLA");
        pad = new LaunchpadV3(treasury, grad, adapter);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function baseParams() internal view returns (LaunchpadV3.Launch memory p) {
        address[] memory basket = new address[](2);
        basket[0] = address(nvda);
        basket[1] = address(tsla);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        p = LaunchpadV3.Launch({
            name: "Ocean Club",
            symbol: "OCEAN",
            quoteAsset: NATIVE,
            virtualQuote: 1 ether,
            graduationQuote: 10 ether,
            buyTaxBps: 300,
            sellTaxBps: 500,
            protocolFeeBps: 100,
            split: FeeVaultV3.Split({creatorBps: 4000, basketBps: 3000, jackpotBps: 2000, burnBps: 1000}),
            basketTokens: basket,
            basketWeights: weights,
            antiSnipeSeconds: 60,
            antiSnipeMaxWalletBps: 200, // 2% of supply per wallet
            antiSnipeTaxBps: 2000, // 20% at t=0
            jackpotEveryN: 3,
            jackpotMinBuy: 0.01 ether,
            salt: bytes32(uint256(7)),
            firstBuyQuote: 0,
            minFirstBuyOut: 0,
            deadline: block.timestamp + 1 hours
        });
    }

    function launch(LaunchpadV3.Launch memory p, uint256 value)
        internal
        returns (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v)
    {
        vm.prank(creator);
        (address token, address curve, address vault) = pad.create{value: value}(p);
        t = MemeTokenV3(token);
        c = BondingCurveV3(payable(curve));
        v = FeeVaultV3(payable(vault));
        adapter.setMeme(token);
    }

    // ─── Creation ──────────────────────────────────────────────────────────────
    function test_create_predictsAddress_and_firstBuyTaxFree() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.firstBuyQuote = 1 ether;
        address predicted = pad.predictToken(creator, p.salt);
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE() + 1 ether);
        assertEq(address(t), predicted, "CA reserved by (creator, salt)");
        assertEq(t.name(), "Ocean Club");
        assertEq(t.symbol(), "OCEAN");
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(treasury.balance, pad.CREATION_FEE());
        assertEq(c.treasuryEarned(), 0.01 ether, "1% protocol fee on first buy");
        assertEq(v.lifetimeFees(), 0, "creator first buy pays no tax");
        assertGt(t.balanceOf(creator), 0);
        assertEq(c.backingReserve(), 1 ether - 0.01 ether);
        // Same salt from another wallet lands elsewhere.
        assertTrue(pad.predictToken(alice, p.salt) != predicted);
        (address tok,,, address cr, address q,) = pad.deployments(address(t));
        assertEq(tok, address(t));
        assertEq(cr, creator);
        assertEq(q, NATIVE);
        assertEq(pad.tokenCount(), 1);
    }

    /// Cross-check with web/lib/world/launch-v3.ts (viem): same effective salt, same init code hash → same address.
    function test_predictToken_matchesClientLibrary() public {
        address alice_ = 0x00000000000000000000000000000000000000A1;
        bytes32 salt = bytes32(uint256(0x0707070707070707070707070707070707070707070707070707070707070707));
        assertEq(pad.effectiveSalt(alice_, salt), 0xd3dd129c514a6a0128cec53a06196f5e1d5b683b6bf2501c602ec0ab7a3da08e);
        // The client pins the init code hash of this exact build; if this fails, update MEME_TOKEN_V3_INIT_CODE_HASH.
        assertEq(pad.TOKEN_INIT_CODE_HASH(), 0xe4728de2b816ef4d8da9b5b99830e7fc8917585f575c65b682f492bbb73d17ea);
        vm.etch(0x1000000000000000000000000000000000000001, address(pad).code);
        // predictToken depends on address(this); a padded pad at the client's fixture address must match viem.
        LaunchpadV3 fixture = LaunchpadV3(0x1000000000000000000000000000000000000001);
        assertEq(fixture.predictToken(alice_, salt), 0x9Fe0731bbB9B369091B8f79aAE8d1433C6e26872);
    }

    function test_create_rejectsBadConfigs() public {
        uint256 fee = pad.CREATION_FEE();
        LaunchpadV3.Launch memory         p = baseParams();
        p.buyTaxBps = 1001;
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_TAX.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        p.protocolFeeBps = 101;
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_TAX.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        p.split.burnBps = 2000; // sums to 11000
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_SPLIT.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        p.jackpotEveryN = 0; // but jackpotBps > 0
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_JACKPOT.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        p.antiSnipeSeconds = 0; // but penalty configured
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_ANTI_SNIPE.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        p.basketTokens = new address[](0);
        p.basketWeights = new uint16[](0); // basketBps > 0 without a basket
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_BASKET.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.BAD_VALUE.selector);
        pad.create{value: fee + 1}(p);

        p = baseParams();
        p.deadline = block.timestamp - 1;
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.EXPIRED.selector);
        pad.create{value: fee}(p);

        p = baseParams();
        p.quoteAsset = alice; // not a contract
        vm.prank(creator);
        vm.expectRevert(LaunchpadV3.INVALID_QUOTE.selector);
        pad.create{value: fee}(p);
    }

    // ─── Taxes ─────────────────────────────────────────────────────────────────
    function test_buyTax_splitsFourWays_and_sellTax() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        (uint256 expectedOut,,,) = c.quoteBuy(1 ether, alice);
        vm.prank(alice);
        uint256 out = c.buy{value: 1 ether}(1 ether, expectedOut, address(0));
        assertEq(out, expectedOut, "view quote equals execution");
        assertEq(t.balanceOf(alice), out);
        uint256 tax = 0.03 ether;
        assertEq(v.lifetimeFees(), tax);
        assertEq(v.creatorEarned(), (tax * 4000) / 10_000);
        assertEq(v.basketPending(), (tax * 3000) / 10_000);
        assertEq(v.jackpotPot(), (tax * 2000) / 10_000);
        assertEq(v.burnPending(), tax - (tax * 9000) / 10_000);
        assertEq(address(v).balance, tax, "vault holds exactly the tax");
        assertEq(c.treasuryEarned(), 0.01 ether);
        assertEq(c.backingReserve(), 1 ether - 0.04 ether);

        // Sell half back: 5% sell tax on gross, 1% protocol.
        uint256 half = out / 2;
        (uint256 net, uint256 pf, uint256 st) = c.quoteSell(half);
        vm.startPrank(alice);
        t.approve(address(c), half);
        uint256 got = c.sell(half, net);
        vm.stopPrank();
        assertEq(got, net);
        assertEq(st, ((net + pf + st) * 500) / 10_000);
        assertEq(v.lifetimeFees(), tax + st);
        assertEq(c.treasuryEarned(), 0.01 ether + pf);

        c.claimTreasury();
        assertEq(treasury.balance, pad.CREATION_FEE() + 0.01 ether + pf);
        vm.prank(bob);
        v.claimCreator();
        assertEq(creator.balance, 100 ether - pad.CREATION_FEE() + ((tax + st) * 4000) / 10_000);
    }

    // ─── Anti-snipe ────────────────────────────────────────────────────────────
    function test_antiSnipe_capAndDecayingPenalty() public {
        LaunchpadV3.Launch memory p = baseParams();
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        assertEq(c.penaltyBps(), 2000, "full penalty at launch");
        assertTrue(c.inAntiSnipeWindow());

        // 2% cap: 20M tokens. A 1 ETH buy against 1 ETH virtual would take ~half the supply.
        vm.prank(alice);
        vm.expectRevert(BondingCurveV3.SNIPE_CAP.selector);
        c.buy{value: 1 ether}(1 ether, 0, address(0));

        // Small buy passes; penalty goes to the community bucket (jackpot pot), never the creator.
        uint256 potBefore = v.jackpotPot();
        uint256 creatorBefore = v.creatorEarned();
        vm.prank(alice);
        uint256 out = c.buy{value: 0.01 ether}(0.01 ether, 0, address(0));
        assertLe(out, (t.FIXED_SUPPLY() * 200) / 10_000);
        uint256 penalty = (0.01 ether * 2000) / 10_000;
        uint256 tax = (0.01 ether * 300) / 10_000;
        assertEq(v.jackpotPot() - potBefore, penalty + (tax * 2000) / 10_000);
        assertEq(v.creatorEarned() - creatorBefore, (tax * 4000) / 10_000);
        assertEq(c.boughtInWindow(alice), out);

        // Half way through the window the penalty is half.
        vm.warp(block.timestamp + 30);
        assertEq(c.penaltyBps(), 1000);
        vm.warp(block.timestamp + 30);
        assertEq(c.penaltyBps(), 0);
        assertFalse(c.inAntiSnipeWindow());
        // Cap lifted: the big buy now succeeds.
        vm.prank(alice);
        c.buy{value: 1 ether}(1 ether, 0, address(0));
    }

    function test_antiSnipe_capIsPerRecipientAcrossBuys() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeMaxWalletBps = 100; // 1%
        (, BondingCurveV3 c,) = launch(p, pad.CREATION_FEE());
        vm.startPrank(alice);
        c.buy{value: 0.005 ether}(0.005 ether, 0, address(0));
        c.buy{value: 0.004 ether}(0.004 ether, 0, address(0));
        vm.expectRevert(BondingCurveV3.SNIPE_CAP.selector);
        c.buy{value: 0.01 ether}(0.01 ether, 0, address(0));
        vm.stopPrank();
    }

    // ─── Jackpot ───────────────────────────────────────────────────────────────
    function test_jackpot_everyThirdQualifyingBuyWinsPot() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        (, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.prank(alice);
        c.buy{value: 0.5 ether}(0.5 ether, 0, address(0));
        vm.prank(alice);
        c.buy{value: 0.001 ether}(0.001 ether, 0, address(0)); // below min: does not count
        vm.prank(bob);
        c.buy{value: 0.5 ether}(0.5 ether, 0, address(0));
        assertEq(c.buyCount(), 2);
        uint256 pot = v.jackpotPot();
        assertGt(pot, 0);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        c.buy{value: 0.2 ether}(0.2 ether, 0, address(0));
        assertEq(c.buyCount(), 3);
        assertEq(v.jackpotPot(), 0, "pot emptied");
        uint256 taxOnWin = (0.2 ether * 300 * 2000) / 10_000 / 10_000;
        assertEq(bob.balance, bobBefore - 0.2 ether + pot + taxOnWin, "winner receives pot incl. its own share");
        assertEq(v.lifetimeJackpots(), pot + taxOnWin);
    }

    function test_jackpot_deferredWhenWinnerRejectsEth() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        p.jackpotEveryN = 2;
        (, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        RejectEth r = new RejectEth();
        vm.deal(address(r), 1 ether);
        vm.prank(alice);
        c.buy{value: 0.5 ether}(0.5 ether, 0, address(0));
        r.buy(c, 0.5 ether);
        assertGt(v.jackpotOwed(address(r)), 0);
        assertEq(v.totalJackpotOwed(), v.jackpotOwed(address(r)));
        r.allow();
        uint256 owed = v.jackpotOwed(address(r));
        r.claim(v);
        assertEq(address(r).balance, 0.5 ether + owed);
        assertEq(v.totalJackpotOwed(), 0);
    }

    // ─── Basket dividends ──────────────────────────────────────────────────────
    function test_basket_streamsStocksToHoldersProRata() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.prank(alice);
        c.buy{value: 1 ether}(1 ether, 0, address(0));
        vm.prank(bob);
        c.buy{value: 1 ether}(1 ether, 0, address(0));
        uint256 pendingQuote = v.basketPending();
        assertGt(pendingQuote, 0);
        uint256[] memory minOuts = new uint256[](2);
        v.buyBasket(minOuts);
        assertEq(v.basketPending(), 0);
        assertEq(v.lifetimeBasketBought(), pendingQuote);
        uint256 nvdaTotal = (pendingQuote * 6000) / 10_000;
        uint256 tslaTotal = pendingQuote - nvdaTotal;
        assertEq(nvda.balanceOf(address(t)), nvdaTotal, "60% leg");
        assertEq(tsla.balanceOf(address(t)), tslaTotal, "40% leg");
        assertEq(t.dividendSupply(), t.balanceOf(alice) + t.balanceOf(bob), "curve/vault excluded");

        uint256 aliceShare = (nvdaTotal * t.balanceOf(alice)) / t.dividendSupply();
        assertApproxEqAbs(t.pending(alice, address(nvda)), aliceShare, 2);
        assertEq(t.pending(address(c), address(nvda)), 0, "curve earns nothing");

        vm.prank(alice);
        t.claimRewards();
        assertApproxEqAbs(nvda.balanceOf(alice), aliceShare, 2);
        assertEq(t.pending(alice, address(nvda)), 0);
        vm.prank(alice);
        vm.expectRevert(MemeTokenV3.NOTHING_TO_CLAIM.selector);
        t.claimRewards();

        // Transfer after the snapshot: bob's accrued stays with bob, alice earns on new balance only.
        uint256 bobPending = t.pending(bob, address(tsla));
        uint256 halfBob = t.balanceOf(bob) / 2;
        vm.prank(bob);
        t.transfer(alice, halfBob);
        assertEq(t.pending(bob, address(tsla)), bobPending, "history is settled, not moved");
        vm.prank(bob);
        t.claimRewards();
        assertEq(tsla.balanceOf(bob), bobPending);
        // Total claimable never exceeds what was notified.
        assertLe(
            nvda.balanceOf(alice) + t.pending(bob, address(nvda)) + t.pending(alice, address(nvda)), nvdaTotal
        );
    }

    function test_basket_rewardHeldWhenNoHolders() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        (MemeTokenV3 t,,) = launch(p, pad.CREATION_FEE());
        nvda.mint(address(t), 5 ether);
        vm.prank(address(t.taxSink()));
        t.notifyReward(address(nvda), 5 ether);
        assertEq(t.unallocated(address(nvda)), 5 ether, "waits for a holder");
        assertEq(t.dividendSupply(), 0);
    }

    // ─── Burn ──────────────────────────────────────────────────────────────────
    function test_buybackAndBurn_preGraduation() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.prank(alice);
        c.buy{value: 2 ether}(2 ether, 0, address(0));
        uint256 burnQuote = v.burnPending();
        uint256 supplyBefore = t.totalSupply();
        uint256 feesBefore = v.lifetimeFees();
        uint256 potBefore = v.jackpotPot();
        v.buybackAndBurn(0);
        assertEq(v.burnPending(), 0);
        assertLt(t.totalSupply(), supplyBefore, "supply shrank");
        assertEq(t.balanceOf(address(v)), 0);
        assertEq(v.lifetimeFees(), feesBefore, "vault buys are tax exempt");
        assertEq(v.jackpotPot(), potBefore, "vault buys never count toward the jackpot");
        assertEq(v.lifetimeBurned(), supplyBefore - t.totalSupply());
        assertEq(c.backingReserve(), 2 ether - 0.02 ether - 0.06 ether + burnQuote - burnQuote / 100);
    }

    // ─── Graduation ────────────────────────────────────────────────────────────
    function test_graduation_crosserWinsPot_poolBecomesMarket_postGradTaxSettles() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        p.graduationQuote = 3 ether;
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.prank(alice);
        c.buy{value: 2 ether}(2 ether, 0, address(0));
        assertFalse(c.graduated());
        uint256 pot = v.jackpotPot();
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        c.buy{value: 1.5 ether}(1.5 ether, 0, address(0));
        assertTrue(c.graduated());
        assertEq(c.pool(), grad.pool());
        assertTrue(t.isMarket(grad.pool()));
        assertTrue(t.exempt(address(grad)));
        assertEq(v.jackpotPot(), 0, "graduation bonus paid");
        uint256 bobTaxShare = (1.5 ether * 300 * 2000) / 10_000 / 10_000;
        assertEq(bob.balance, bobBefore - 1.5 ether + pot + bobTaxShare);
        assertEq(c.backingReserve(), 0, "all backing moved to the pool");
        assertEq(grad.quoteReceived(), 2 ether + 1.5 ether - 0.035 ether - (3.5 ether * 300) / 10_000);
        assertEq(t.balanceOf(grad.pool()), grad.tokenReceived());
        assertEq(c.progressBps(), 0);

        vm.prank(alice);
        vm.expectRevert(BondingCurveV3.GRADUATED.selector);
        c.buy{value: 1 ether}(1 ether, 0, address(0));

        // AMM trade simulation: pool → alice is a buy (3%), alice → pool a sell (5%). Tax in meme.
        address pool = grad.pool();
        uint256 aliceBefore = t.balanceOf(alice);
        vm.prank(pool);
        t.transfer(alice, 1000 ether);
        assertEq(t.balanceOf(alice), aliceBefore + 970 ether);
        assertEq(v.memePending(), 30 ether);
        vm.prank(alice);
        t.transfer(pool, 1000 ether);
        assertEq(v.memePending(), 80 ether);
        // Wallet to wallet is never taxed.
        vm.prank(alice);
        t.transfer(bob, 100 ether);
        assertEq(v.memePending(), 80 ether);

        uint256 supply = t.totalSupply();
        vm.deal(address(adapter), 10 ether);
        v.settleTax(0);
        assertEq(v.memePending(), 0);
        assertEq(t.totalSupply(), supply - 8 ether, "10% burn share burned directly");
        uint256 quoteOut = 72 ether / 1000; // adapter pretend price
        assertEq(v.creatorEarned(), (quoteOut * 4000) / 9000 + _creatorShareOf(v, 0));
        assertEq(address(v).balance, v.creatorEarned() + v.basketPending() + v.jackpotPot() + v.burnPending());
    }

    function _creatorShareOf(FeeVaultV3, uint256) internal pure returns (uint256) {
        // Creator share from the two curve buys: (2 + 1.5) ETH * 3% * 40%
        return ((3.5 ether * 300) / 10_000 * 4000) / 10_000;
    }

    function test_graduate_manualAfterDonation() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.graduationQuote = 1 ether;
        (, BondingCurveV3 c,) = launch(p, pad.CREATION_FEE());
        vm.expectRevert(BondingCurveV3.BELOW_THRESHOLD.selector);
        c.graduate();
        vm.prank(alice);
        (bool ok,) = address(c).call{value: 1 ether}("");
        assertTrue(ok);
        c.graduate();
        assertTrue(c.graduated());
        vm.expectRevert(BondingCurveV3.ALREADY_GRADUATED.selector);
        c.graduate();
    }

    // ─── Stock quote ───────────────────────────────────────────────────────────
    function test_stockQuote_createBuySell() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.quoteAsset = address(nvda);
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        p.virtualQuote = 100 ether; // 100 NVDA bias
        p.graduationQuote = 1000 ether;
        p.firstBuyQuote = 10 ether;
        nvda.mint(creator, 10 ether);
        nvda.mint(alice, 100 ether);
        vm.prank(creator);
        nvda.approve(address(pad), 10 ether);
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        assertEq(nvda.balanceOf(creator), 0);
        assertEq(c.backingReserve(), 10 ether - 0.1 ether);
        assertGt(t.balanceOf(creator), 0);

        vm.startPrank(alice);
        nvda.approve(address(c), 50 ether);
        uint256 out = c.buy(50 ether, 0, address(0));
        vm.stopPrank();
        assertEq(t.balanceOf(alice), out);
        assertEq(nvda.balanceOf(address(v)), (50 ether * 300) / 10_000, "tax paid in NVDA");
        assertEq(c.backingReserve(), 10 ether - 0.1 ether + 50 ether - 0.5 ether - 1.5 ether);

        vm.startPrank(alice);
        t.approve(address(c), out);
        (uint256 net,,) = c.quoteSell(out);
        c.sell(out, net);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 50 ether + net);

        // ETH sent to a stock-quoted curve is rejected.
        vm.prank(alice);
        vm.expectRevert(BondingCurveV3.BAD_VALUE.selector);
        c.buy{value: 1 ether}(1 ether, 0, address(0));

        // Basket leg that equals the quote is transferred, not swapped.
        uint256 calls = adapter.calls();
        uint256[] memory minOuts = new uint256[](2);
        v.buyBasket(minOuts);
        assertEq(adapter.calls(), calls + 1, "only the TSLA leg needs the adapter");
        assertGt(t.pending(alice, address(nvda)) + t.pending(creator, address(nvda)), 0);
    }

    // ─── Token guards ──────────────────────────────────────────────────────────
    function test_token_initializeOnce_andAuthority() public {
        LaunchpadV3.Launch memory p = baseParams();
        (MemeTokenV3 t,,) = launch(p, pad.CREATION_FEE());
        address[] memory none = new address[](0);
        vm.prank(address(pad));
        vm.expectRevert(MemeTokenV3.ALREADY_INITIALIZED.selector);
        t.initialize("x", "XX", 0, 0, address(1), address(2), none, none);
        vm.prank(alice);
        vm.expectRevert(MemeTokenV3.NOT_AUTHORIZED.selector);
        t.setMarket(alice, true);
        vm.prank(alice);
        vm.expectRevert(MemeTokenV3.NOT_AUTHORIZED.selector);
        t.setExempt(alice, true);
        vm.expectRevert(MemeTokenV3.UNKNOWN_REWARD.selector);
        t.notifyReward(address(0x1234), 1);
    }

    function test_vault_curveOnlyHooks() public {
        LaunchpadV3.Launch memory p = baseParams();
        (, , FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.expectRevert(FeeVaultV3.ONLY_CURVE.selector);
        v.onFee{value: 1}(1);
        vm.expectRevert(FeeVaultV3.ONLY_CURVE.selector);
        v.payJackpot(alice);
        vm.expectRevert(FeeVaultV3.ONLY_TOKEN.selector);
        v.onTax(1);
        vm.expectRevert(FeeVaultV3.ALREADY_BOUND.selector);
        vm.prank(address(pad));
        v.setCurve(alice);
    }

    /// Random buys and sells never break the two balance invariants.
    function testFuzz_accountingInvariants(uint96[6] memory buys, uint8 sellPct) public {
        LaunchpadV3.Launch memory p = baseParams();
        p.graduationQuote = 1_000 ether;
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.warp(block.timestamp + 61); // outside the anti-snipe window so the cap does not bite
        address[2] memory traders = [alice, bob];
        for (uint256 i; i < buys.length; ++i) {
            uint256 amount = bound(uint256(buys[i]), 0.001 ether, 5 ether);
            address who = traders[i % 2];
            vm.prank(who);
            c.buy{value: amount}(amount, 0, address(0));
            uint256 bal = t.balanceOf(who);
            uint256 toSell = (bal * bound(uint256(sellPct), 0, 100)) / 100;
            if (toSell > 0) {
                (uint256 net,,) = c.quoteSell(toSell);
                if (net > 0) {
                    vm.startPrank(who);
                    t.approve(address(c), toSell);
                    c.sell(toSell, net);
                    vm.stopPrank();
                }
            }
            assertEq(
                address(v).balance,
                v.creatorEarned() + v.basketPending() + v.jackpotPot() + v.burnPending() + v.totalJackpotOwed(),
                "vault buckets equal balance"
            );
            assertEq(address(c).balance, c.backingReserve() + c.treasuryEarned(), "curve buckets equal balance");
            assertEq(t.dividendSupply(), t.balanceOf(alice) + t.balanceOf(bob) + t.balanceOf(creator));
        }
    }

    function testFuzz_dividendsNeverExceedNotified(uint96 a, uint96 b, uint96 reward) public {
        LaunchpadV3.Launch memory p = baseParams();
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        (MemeTokenV3 t, BondingCurveV3 c,) = launch(p, pad.CREATION_FEE());
        uint256 buyA = bound(uint256(a), 0.001 ether, 3 ether);
        uint256 buyB = bound(uint256(b), 0.001 ether, 3 ether);
        uint256 amount = bound(uint256(reward), 1 gwei, 1_000_000 ether);
        vm.prank(alice);
        c.buy{value: buyA}(buyA, 0, address(0));
        vm.prank(bob);
        c.buy{value: buyB}(buyB, 0, address(0));
        nvda.mint(address(t), amount);
        vm.prank(address(t.taxSink()));
        t.notifyReward(address(nvda), amount);
        uint256 total = t.pending(alice, address(nvda)) + t.pending(bob, address(nvda));
        assertLe(total, amount);
        assertGe(total + 2, amount, "dust only");
        vm.prank(alice);
        t.claimRewards();
        vm.prank(bob);
        t.claimRewards();
        assertLe(nvda.balanceOf(alice) + nvda.balanceOf(bob), amount);
    }

    function test_noTaxNoBasketNoJackpot_minimalLaunch() public {
        LaunchpadV3.Launch memory p = baseParams();
        p.buyTaxBps = 0;
        p.sellTaxBps = 0;
        p.split = FeeVaultV3.Split({creatorBps: 10_000, basketBps: 0, jackpotBps: 0, burnBps: 0});
        p.basketTokens = new address[](0);
        p.basketWeights = new uint16[](0);
        p.antiSnipeSeconds = 0;
        p.antiSnipeMaxWalletBps = 0;
        p.antiSnipeTaxBps = 0;
        p.jackpotEveryN = 0;
        (MemeTokenV3 t, BondingCurveV3 c, FeeVaultV3 v) = launch(p, pad.CREATION_FEE());
        vm.prank(alice);
        c.buy{value: 1 ether}(1 ether, 0, address(0));
        assertEq(v.lifetimeFees(), 0);
        assertEq(t.rewardTokenCount(), 0);
        assertEq(c.backingReserve(), 0.99 ether);
    }

    function test_communityDefault_protocolTwenty_andOfficialZeroSplit() public {
        LaunchpadV3.Launch memory community = baseParams();
        community.buyTaxBps = 80;
        community.sellTaxBps = 80;
        community.protocolFeeBps = 20;
        community.antiSnipeSeconds = 0;
        community.antiSnipeMaxWalletBps = 0;
        community.antiSnipeTaxBps = 0;
        community.split = FeeVaultV3.Split({creatorBps: 10000, basketBps: 0, jackpotBps: 0, burnBps: 0});
        community.basketTokens = new address[](0);
        community.basketWeights = new uint16[](0);
        community.jackpotEveryN = 0;
        (, BondingCurveV3 cc, FeeVaultV3 cv) = launch(community, pad.CREATION_FEE());
        assertEq(cc.PROTOCOL_FEE_BPS(), 20);
        vm.prank(alice);
        cc.buy{value: 1 ether}(1 ether, 0, alice);
        assertEq(cc.treasuryEarned(), 0.002 ether);
        assertEq(cv.lifetimeFees(), 0.008 ether);
        assertEq(cv.creatorEarned(), 0.008 ether);

        LaunchpadV3.Launch memory official = baseParams();
        official.name = "FEFE";
        official.symbol = "FEFE";
        official.buyTaxBps = 100;
        official.sellTaxBps = 100;
        official.protocolFeeBps = 0;
        official.antiSnipeSeconds = 0;
        official.antiSnipeMaxWalletBps = 0;
        official.antiSnipeTaxBps = 0;
        official.split = FeeVaultV3.Split({creatorBps: 0, basketBps: 5000, jackpotBps: 0, burnBps: 5000});
        official.basketTokens = new address[](1);
        official.basketTokens[0] = address(nvda);
        official.basketWeights = new uint16[](1);
        official.basketWeights[0] = 10000;
        official.jackpotEveryN = 0;
        official.salt = bytes32(uint256(8));
        official.firstBuyQuote = 1 ether;
        (MemeTokenV3 ot, BondingCurveV3 oc, FeeVaultV3 ov) = launch(official, pad.CREATION_FEE() + 1 ether);
        assertEq(ot.symbol(), "FEFE");
        assertEq(oc.PROTOCOL_FEE_BPS(), 0);
        assertEq(oc.treasuryEarned(), 0);
        assertEq(ov.lifetimeFees(), 0, "creator first buy pays no tax");
        vm.prank(alice);
        oc.buy{value: 1 ether}(1 ether, 0, alice);
        assertEq(oc.treasuryEarned(), 0, "official book does not feed FefeSink");
        assertEq(ov.lifetimeFees(), 0.01 ether);
        assertEq(ov.creatorEarned(), 0);
        assertEq(ov.basketPending(), 0.005 ether);
        assertEq(ov.burnPending(), 0.005 ether);
    }
}

contract RejectEth {
    bool public accept;

    function buy(BondingCurveV3 c, uint256 amount) external {
        c.buy{value: amount}(amount, 0, address(0));
    }

    function allow() external {
        accept = true;
    }

    function claim(FeeVaultV3 v) external {
        v.claimJackpot();
    }

    receive() external payable {
        require(accept, "no");
    }
}
