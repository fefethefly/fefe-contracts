// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapterV3, ITaxSinkV3, NATIVE} from "./InterfacesV3.sol";
import {MemeTokenV3} from "./MemeTokenV3.sol";

interface ICurveForVault {
    function graduated() external view returns (bool);
    function buy(uint256 quoteIn, uint256 minOut, address recipient) external payable returns (uint256);
}

/**
 * @title FeeVaultV3
 * @notice Per-token treasury for creator-configured taxes. Every unit of tax (quote asset
 * during the curve phase, meme tokens from AMM trades after graduation) is split four ways:
 *   creator   → claimable by the creator wallet
 *   basket    → swapped into the configured stock basket and streamed to holders
 *   jackpot   → paid out by the curve to every Nth buyer
 *   burn      → used to buy back the meme and burn it
 * Splits, basket and adapter are immutable. No owner. Every action is permissionless
 * except curve-only hooks.
 */
contract FeeVaultV3 is ITaxSinkV3, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ONLY_CURVE();
    error ONLY_TOKEN();
    error ONLY_LAUNCHPAD();
    error ALREADY_BOUND();
    error BAD_SPLIT();
    error BAD_BASKET();
    error NOTHING_PENDING();
    error NOTHING_TO_CLAIM();
    error SLIPPAGE();
    error TRANSFER_FAILED();
    error BAD_AMOUNT();

    struct Split {
        uint16 creatorBps;
        uint16 basketBps;
        uint16 jackpotBps;
        uint16 burnBps;
    }

    MemeTokenV3 public immutable token;
    address public immutable quote; // address(0) = ETH
    address payable public immutable creator;
    address public immutable launchpad;
    ISwapAdapterV3 public immutable adapter;
    Split public split;
    address[] public basketTokens;
    uint16[] public basketWeights;
    address public curve;

    // Quote-denominated buckets. Balance invariant: sum(buckets) + sum(jackpotOwed) == held quote.
    uint256 public creatorEarned;
    uint256 public basketPending;
    uint256 public jackpotPot;
    uint256 public burnPending;
    uint256 public totalJackpotOwed;
    mapping(address => uint256) public jackpotOwed;

    // Meme-denominated tax waiting to be settled (post graduation).
    uint256 public memePending;

    uint256 public lifetimeFees;
    uint256 public lifetimeBasketBought;
    uint256 public lifetimeBurned;
    uint256 public lifetimeJackpots;

    event FeeReceived(uint256 amount, uint256 toCreator, uint256 toBasket, uint256 toJackpot, uint256 toBurn);
    event CommunityFeeReceived(uint256 amount);
    event JackpotPaid(address indexed winner, uint256 amount, bool deferred);
    event CreatorClaimed(uint256 amount);
    event BasketBought(uint256 quoteSpent);
    event BasketLeg(address indexed stock, uint256 quoteIn, uint256 stockOut);
    event Burned(uint256 quoteSpent, uint256 tokensBurned);
    event TaxReceived(uint256 memeAmount);
    event TaxSettled(uint256 memeIn, uint256 memeBurned, uint256 quoteOut);

    constructor(
        MemeTokenV3 token_,
        address quote_,
        address payable creator_,
        address launchpad_,
        ISwapAdapterV3 adapter_,
        Split memory split_,
        address[] memory basketTokens_,
        uint16[] memory basketWeights_
    ) {
        if (uint256(split_.creatorBps) + split_.basketBps + split_.jackpotBps + split_.burnBps != 10_000) {
            revert BAD_SPLIT();
        }
        if (basketTokens_.length != basketWeights_.length || basketTokens_.length > 8) revert BAD_BASKET();
        if (split_.basketBps > 0 && basketTokens_.length == 0) revert BAD_BASKET();
        uint256 weightSum;
        for (uint256 i; i < basketWeights_.length; ++i) {
            if (basketTokens_[i].code.length == 0 || basketWeights_[i] == 0) revert BAD_BASKET();
            for (uint256 j; j < i; ++j) {
                if (basketTokens_[j] == basketTokens_[i]) revert BAD_BASKET();
            }
            weightSum += basketWeights_[i];
        }
        if (basketTokens_.length > 0 && weightSum != 10_000) revert BAD_BASKET();
        token = token_;
        quote = quote_;
        creator = creator_;
        adapter = adapter_;
        split = split_;
        basketTokens = basketTokens_;
        basketWeights = basketWeights_;
        launchpad = launchpad_;
    }

    function setCurve(address curve_) external {
        if (msg.sender != launchpad) revert ONLY_LAUNCHPAD();
        if (curve != address(0)) revert ALREADY_BOUND();
        curve = curve_;
    }

    modifier onlyCurve() {
        if (msg.sender != curve) revert ONLY_CURVE();
        _;
    }

    function basketLength() external view returns (uint256) {
        return basketTokens.length;
    }

    // ─── Curve hooks ───────────────────────────────────────────────────────────
    /// Quote already transferred (ERC20) or attached (ETH). Splits into the four buckets.
    function onFee(uint256 amount) external payable onlyCurve {
        _checkIncoming(amount);
        _splitFee(amount);
    }

    /// Anti-snipe penalties: never to the creator. Jackpot → basket → burn, whichever is enabled.
    function onCommunityFee(uint256 amount) external payable onlyCurve {
        _checkIncoming(amount);
        if (split.jackpotBps > 0) jackpotPot += amount;
        else if (split.basketBps > 0) basketPending += amount;
        else burnPending += amount;
        lifetimeFees += amount;
        emit CommunityFeeReceived(amount);
    }

    /// Pays the whole pot to `winner`. If the payout call fails the amount becomes claimable.
    function payJackpot(address winner) external onlyCurve returns (uint256 amount) {
        amount = jackpotPot;
        if (amount == 0) return 0;
        jackpotPot = 0;
        lifetimeJackpots += amount;
        bool ok = _trySend(winner, amount);
        if (!ok) {
            jackpotOwed[winner] += amount;
            totalJackpotOwed += amount;
        }
        emit JackpotPaid(winner, amount, !ok);
    }

    // ─── Venue fee (post graduation, quote-denominated, e.g. BarkHookV3) ───────
    /// Permissionless: value must already be here (ETH attached, or ERC20 delivered before the call).
    /// ERC20 amounts are capped by what is not yet booked, so a caller cannot inflate the buckets.
    function onMarketFee(uint256 amount) external payable {
        _checkIncoming(amount);
        if (quote != NATIVE && _held() - _accounted() < amount) revert BAD_AMOUNT();
        _splitFee(amount);
    }

    /// Quote that is booked in a bucket or owed to a jackpot winner.
    function _accounted() internal view returns (uint256) {
        return creatorEarned + basketPending + jackpotPot + burnPending + totalJackpotOwed;
    }

    // ─── Token hook (post graduation meme tax) ─────────────────────────────────
    function onTax(uint256 amount) external override {
        if (msg.sender != address(token)) revert ONLY_TOKEN();
        memePending += amount;
        emit TaxReceived(amount);
    }

    /// Burns the burn share directly, swaps the rest to quote and splits it among the other buckets.
    function settleTax(uint256 minQuoteOut) external nonReentrant {
        uint256 amountIn = memePending;
        if (amountIn == 0) revert NOTHING_PENDING();
        memePending = 0;
        uint256 toBurn = (amountIn * split.burnBps) / 10_000;
        if (toBurn > 0) {
            token.burn(toBurn);
            lifetimeBurned += toBurn;
        }
        uint256 toSwap = amountIn - toBurn;
        uint256 quoteOut;
        if (toSwap > 0) {
            IERC20(address(token)).forceApprove(address(adapter), toSwap);
            uint256 before = _held();
            adapter.swapExactIn(address(token), quote, toSwap, minQuoteOut, address(this));
            quoteOut = _held() - before;
            if (quoteOut < minQuoteOut) revert SLIPPAGE();
            uint256 denom = 10_000 - split.burnBps;
            uint256 toCreator = (quoteOut * split.creatorBps) / denom;
            uint256 toBasket = (quoteOut * split.basketBps) / denom;
            uint256 toJackpot = quoteOut - toCreator - toBasket;
            creatorEarned += toCreator;
            basketPending += toBasket;
            jackpotPot += toJackpot;
            lifetimeFees += quoteOut;
            emit FeeReceived(quoteOut, toCreator, toBasket, toJackpot, 0);
        }
        emit TaxSettled(amountIn, toBurn, quoteOut);
    }

    // ─── Permissionless actions ────────────────────────────────────────────────
    function claimCreator() external nonReentrant {
        uint256 amount = creatorEarned;
        if (amount == 0) revert NOTHING_TO_CLAIM();
        creatorEarned = 0;
        _send(creator, amount);
        emit CreatorClaimed(amount);
    }

    function claimJackpot() external nonReentrant {
        uint256 amount = jackpotOwed[msg.sender];
        if (amount == 0) revert NOTHING_TO_CLAIM();
        jackpotOwed[msg.sender] = 0;
        totalJackpotOwed -= amount;
        _send(msg.sender, amount);
    }

    /// Converts pending basket quote into the configured stocks and streams them to holders.
    function buyBasket(uint256[] calldata minOuts) external nonReentrant {
        uint256 amount = basketPending;
        if (amount == 0) revert NOTHING_PENDING();
        if (minOuts.length != basketTokens.length) revert BAD_BASKET();
        basketPending = 0;
        uint256 spent;
        for (uint256 i; i < basketTokens.length; ++i) {
            address stock = basketTokens[i];
            uint256 legIn = i + 1 == basketTokens.length ? amount - spent : (amount * basketWeights[i]) / 10_000;
            spent += legIn;
            if (legIn == 0) continue;
            uint256 out;
            if (stock == quote) {
                IERC20(stock).safeTransfer(address(token), legIn);
                out = legIn;
            } else {
                uint256 before = IERC20(stock).balanceOf(address(token));
                _swapQuote(stock, legIn, minOuts[i], address(token));
                out = IERC20(stock).balanceOf(address(token)) - before;
            }
            if (out < minOuts[i]) revert SLIPPAGE();
            token.notifyReward(stock, out);
            emit BasketLeg(stock, legIn, out);
        }
        lifetimeBasketBought += amount;
        emit BasketBought(amount);
    }

    /// Buys the meme with the burn bucket (from the curve before graduation, via the adapter after) and burns it.
    function buybackAndBurn(uint256 minOut) external nonReentrant {
        uint256 amount = burnPending;
        if (amount == 0) revert NOTHING_PENDING();
        burnPending = 0;
        uint256 before = token.balanceOf(address(this));
        if (!ICurveForVault(curve).graduated()) {
            if (quote == NATIVE) {
                ICurveForVault(curve).buy{value: amount}(amount, minOut, address(this));
            } else {
                IERC20(quote).forceApprove(curve, amount);
                ICurveForVault(curve).buy(amount, minOut, address(this));
            }
        } else {
            _swapQuote(address(token), amount, minOut, address(this));
        }
        uint256 got = token.balanceOf(address(this)) - before;
        if (got < minOut) revert SLIPPAGE();
        token.burn(got);
        lifetimeBurned += got;
        emit Burned(amount, got);
    }

    // ─── Internals ─────────────────────────────────────────────────────────────
    function _splitFee(uint256 amount) internal {
        uint256 toCreator = (amount * split.creatorBps) / 10_000;
        uint256 toBasket = (amount * split.basketBps) / 10_000;
        uint256 toJackpot = (amount * split.jackpotBps) / 10_000;
        uint256 toBurn = amount - toCreator - toBasket - toJackpot;
        // Rounding must never activate a disabled buyback. Preserve the historical
        // burn remainder when enabled; otherwise credit an enabled bucket.
        if (split.burnBps == 0) {
            if (split.basketBps > 0) toBasket += toBurn;
            else if (split.jackpotBps > 0) toJackpot += toBurn;
            else toCreator += toBurn;
            toBurn = 0;
        }
        creatorEarned += toCreator;
        basketPending += toBasket;
        jackpotPot += toJackpot;
        burnPending += toBurn;
        lifetimeFees += amount;
        emit FeeReceived(amount, toCreator, toBasket, toJackpot, toBurn);
    }

    function _checkIncoming(uint256 amount) internal view {
        if (amount == 0) revert BAD_AMOUNT();
        if (quote == NATIVE) {
            if (msg.value != amount) revert BAD_AMOUNT();
        } else if (msg.value != 0) {
            revert BAD_AMOUNT();
        }
    }

    function _held() internal view returns (uint256) {
        return quote == NATIVE ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    function _swapQuote(address tokenOut, uint256 amountIn, uint256 minOut, address recipient) internal {
        if (quote == NATIVE) {
            adapter.swapExactIn{value: amountIn}(NATIVE, tokenOut, amountIn, minOut, recipient);
        } else {
            IERC20(quote).forceApprove(address(adapter), amountIn);
            adapter.swapExactIn(quote, tokenOut, amountIn, minOut, recipient);
        }
    }

    function _send(address to, uint256 amount) internal {
        if (!_trySend(to, amount)) revert TRANSFER_FAILED();
    }

    function _trySend(address to, uint256 amount) internal returns (bool) {
        if (quote == NATIVE) {
            (bool sent,) = payable(to).call{value: amount, gas: 60_000}("");
            return sent;
        }
        (bool ok, bytes memory data) = address(quote).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (data.length == 0 || abi.decode(data, (bool)));
    }

    receive() external payable {}
}
