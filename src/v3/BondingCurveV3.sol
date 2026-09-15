// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGraduationHandlerV3, NATIVE} from "./InterfacesV3.sol";
import {MemeTokenV3} from "./MemeTokenV3.sol";
import {FeeVaultV3} from "./FeeVaultV3.sol";

/**
 * @title BondingCurveV3
 * @notice Constant-product curve priced in any quote asset (ETH or a tokenized stock).
 * Adds three creator-configured mechanics on top of the V2 accounting model:
 *   Anti-snipe   time-boxed per-wallet cap plus a decaying penalty that goes to the community
 *   Nth-buy pot  every Nth qualifying buy wins the whole jackpot bucket instantly
 *   Taxes        buy / sell tax in quote, split four ways by the FeeVault
 * Protocol fee is per-token (community 20 bps → FefeSink; official 0) and paid to treasury.
 * The buy that crosses the graduation threshold also wins whatever is left in the pot.
 */
contract BondingCurveV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZERO_INPUT();
    error BAD_VALUE();
    error SLIPPAGE();
    error GRADUATED();
    error ALREADY_GRADUATED();
    error BELOW_THRESHOLD();
    error INSUFFICIENT_BACKING();
    error POOL_ZERO();
    error TRANSFER_FAILED();
    error SNIPE_CAP();
    error NOT_LAUNCHPAD();
    error NOTHING_TO_CLAIM();

    struct Config {
        uint128 virtualQuote; // pricing bias, quote units
        uint128 graduationQuote; // backing needed to graduate, quote units
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint32 antiSnipeSeconds; // 0 = off
        uint16 antiSnipeMaxWalletBps; // max share of supply one wallet may buy inside the window (0 = no cap)
        uint16 antiSnipeTaxBps; // penalty at t=0, decays linearly to 0 at window end
        uint16 jackpotEveryN; // 0 = off
        uint96 jackpotMinBuy; // quote units a buy must reach to count
        uint16 protocolFeeBps; // community 20 → FefeSink; official 0. Max 100.
    }

    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100;
    uint256 public constant MAX_TAX_BPS = 1_000;

    MemeTokenV3 public immutable token;
    address public immutable quote; // address(0) = ETH
    address payable public immutable creator;
    address public immutable treasury;
    FeeVaultV3 public immutable vault;
    IGraduationHandlerV3 public immutable gradHandler;
    address public immutable launchpad;
    Config public config;

    uint64 public launchedAt;
    bool public graduated;
    address public pool;
    uint256 public treasuryEarned;
    uint256 private quoteHeld; // ERC20 quote accounting mirror (ETH uses balance)
    uint256 public buyCount; // qualifying buys since launch
    uint256 public volumeQuote;
    mapping(address => uint256) public boughtInWindow;

    event Opened(uint64 at, uint128 virtualQuote, uint128 graduationQuote);
    event Bought(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 tax, uint256 penalty
    );
    event Sold(address indexed seller, uint256 tokensIn, uint256 quoteOut, uint256 tax);
    event Jackpot(address indexed winner, uint256 amount, uint256 buyIndex, bool graduationBonus);
    event Graduated(address indexed pool, uint256 quoteLiquidity, uint256 tokenLiquidity);
    event TreasuryClaimed(uint256 amount);

    constructor(
        MemeTokenV3 token_,
        address quote_,
        address payable creator_,
        address treasury_,
        address launchpad_,
        FeeVaultV3 vault_,
        IGraduationHandlerV3 gradHandler_,
        Config memory config_
    ) {
        token = token_;
        quote = quote_;
        creator = creator_;
        treasury = treasury_;
        vault = vault_;
        gradHandler = gradHandler_;
        config = config_;
        launchpad = launchpad_;
    }

    // ─── Views ─────────────────────────────────────────────────────────────────
    function backingReserve() public view returns (uint256) {
        uint256 held = quote == NATIVE ? address(this).balance : quoteHeld;
        return held - treasuryEarned;
    }

    function tokenReserve() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// Per-token protocol take, same name as the old constant so existing `cast` / ABI keep working.
    function PROTOCOL_FEE_BPS() public view returns (uint256) {
        return config.protocolFeeBps;
    }

    /// Spot price in quote units per whole token (1e18 scaled).
    function spotPrice() external view returns (uint256) {
        uint256 y = tokenReserve();
        if (y == 0) return 0;
        return ((backingReserve() + config.virtualQuote) * 1e18) / y;
    }

    function progressBps() external view returns (uint256) {
        uint256 b = backingReserve();
        if (b >= config.graduationQuote) return 10_000;
        return (b * 10_000) / config.graduationQuote;
    }

    /// Full buy quote for a gross quote amount from `buyer` at the current time.
    function quoteBuy(uint256 quoteIn, address buyer)
        public
        view
        returns (uint256 tokensOut, uint256 protocolFee, uint256 tax, uint256 penalty)
    {
        Config memory c = config;
        protocolFee = (quoteIn * uint256(c.protocolFeeBps)) / 10_000;
        bool exemptBuyer = buyer == address(vault);
        tax = exemptBuyer ? 0 : (quoteIn * c.buyTaxBps) / 10_000;
        penalty = exemptBuyer ? 0 : (quoteIn * _penaltyBps()) / 10_000;
        uint256 net = quoteIn - protocolFee - tax - penalty;
        uint256 x = backingReserve() + c.virtualQuote;
        tokensOut = (tokenReserve() * net) / (x + net);
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 quoteOut, uint256 protocolFee, uint256 tax) {
        Config memory c = config;
        uint256 x = backingReserve() + c.virtualQuote;
        uint256 y = tokenReserve();
        // Round payout down; subtracting a floored reserve rounds payout up and can
        // exceed actual backing by one raw unit on the final full exit.
        uint256 gross = (x * tokensIn) / (y + tokensIn);
        protocolFee = (gross * uint256(c.protocolFeeBps)) / 10_000;
        tax = (gross * c.sellTaxBps) / 10_000;
        quoteOut = gross - protocolFee - tax;
    }

    /// Current anti-snipe penalty in bps (0 once the window closed).
    function penaltyBps() external view returns (uint256) {
        return _penaltyBps();
    }

    function _penaltyBps() internal view returns (uint256) {
        Config memory c = config;
        if (c.antiSnipeSeconds == 0 || c.antiSnipeTaxBps == 0 || launchedAt == 0) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= c.antiSnipeSeconds) return 0;
        return (uint256(c.antiSnipeTaxBps) * (c.antiSnipeSeconds - elapsed)) / c.antiSnipeSeconds;
    }

    function inAntiSnipeWindow() public view returns (bool) {
        return config.antiSnipeSeconds != 0 && launchedAt != 0 && block.timestamp - launchedAt < config.antiSnipeSeconds;
    }

    // ─── Launch ────────────────────────────────────────────────────────────────
    /// Called once by the launchpad. The creator's first buy is tax-free and exempt from anti-snipe.
    function open(uint256 firstBuyQuote, uint256 minOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        if (msg.sender != launchpad) revert NOT_LAUNCHPAD();
        if (launchedAt != 0) revert GRADUATED();
        launchedAt = uint64(block.timestamp);
        emit Opened(launchedAt, config.virtualQuote, config.graduationQuote);
        if (firstBuyQuote == 0) {
            if (msg.value != 0) revert BAD_VALUE();
            return 0;
        }
        _receiveQuote(firstBuyQuote);
        uint256 protocolFee = (firstBuyQuote * uint256(config.protocolFeeBps)) / 10_000;
        uint256 net = firstBuyQuote - protocolFee;
        uint256 x = backingReserve() - firstBuyQuote + config.virtualQuote;
        out = (tokenReserve() * net) / (x + net);
        if (out < minOut) revert SLIPPAGE();
        treasuryEarned += protocolFee;
        volumeQuote += firstBuyQuote;
        token.transfer(recipient, out);
        emit Bought(recipient, recipient, firstBuyQuote, out, 0, 0);
    }

    // ─── Trading ───────────────────────────────────────────────────────────────
    function buy(uint256 quoteIn, uint256 minOut, address recipient) external payable nonReentrant returns (uint256 out) {
        if (graduated) revert GRADUATED();
        if (quoteIn == 0) revert ZERO_INPUT();
        if (recipient == address(0)) recipient = msg.sender;
        _receiveQuote(quoteIn);
        Config memory c = config;
        bool exemptBuyer = msg.sender == address(vault);

        uint256 protocolFee = (quoteIn * uint256(c.protocolFeeBps)) / 10_000;
        uint256 tax = exemptBuyer ? 0 : (quoteIn * c.buyTaxBps) / 10_000;
        uint256 penalty = exemptBuyer ? 0 : (quoteIn * _penaltyBps()) / 10_000;
        uint256 net = quoteIn - protocolFee - tax - penalty;

        // Price with pre-trade reserves: this payment is already in the balance.
        uint256 x = backingReserve() - quoteIn + c.virtualQuote;
        uint256 y = tokenReserve();
        out = (y * net) / (x + net);
        if (out < minOut) revert SLIPPAGE();

        if (!exemptBuyer && inAntiSnipeWindow() && c.antiSnipeMaxWalletBps != 0) {
            uint256 bought = boughtInWindow[recipient] + out;
            if (bought > (token.FIXED_SUPPLY() * c.antiSnipeMaxWalletBps) / 10_000) revert SNIPE_CAP();
            boughtInWindow[recipient] = bought;
        }

        treasuryEarned += protocolFee;
        volumeQuote += quoteIn;
        if (tax > 0) _pushFee(tax, false);
        if (penalty > 0) _pushFee(penalty, true);
        token.transfer(recipient, out);
        emit Bought(msg.sender, recipient, quoteIn, out, tax, penalty);

        if (!exemptBuyer && c.jackpotEveryN != 0 && quoteIn >= c.jackpotMinBuy) {
            uint256 index = ++buyCount;
            if (index % c.jackpotEveryN == 0) {
                uint256 won = vault.payJackpot(recipient);
                if (won > 0) emit Jackpot(recipient, won, index, false);
            }
        }
        if (backingReserve() >= c.graduationQuote) _graduate(recipient);
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut) external nonReentrant returns (uint256 out) {
        if (graduated) revert GRADUATED();
        if (tokensIn == 0) revert ZERO_INPUT();
        (uint256 net, uint256 protocolFee, uint256 tax) = quoteSell(tokensIn);
        if (net + protocolFee + tax > backingReserve()) revert INSUFFICIENT_BACKING();
        if (net < minQuoteOut) revert SLIPPAGE();
        out = net;
        treasuryEarned += protocolFee;
        volumeQuote += net + protocolFee + tax;
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensIn);
        if (tax > 0) _pushFee(tax, false);
        _sendQuote(msg.sender, net);
        emit Sold(msg.sender, tokensIn, net, tax);
    }

    // ─── Graduation ────────────────────────────────────────────────────────────
    function graduate() external nonReentrant returns (address) {
        if (graduated) revert ALREADY_GRADUATED();
        if (backingReserve() < config.graduationQuote) revert BELOW_THRESHOLD();
        _graduate(address(0));
        return pool;
    }

    function _graduate(address crosser) internal {
        if (graduated) return;
        graduated = true;
        uint256 quoteLiquidity = backingReserve();
        uint256 tokenLiquidity = tokenReserve();
        token.setExempt(address(gradHandler), true);
        token.transfer(address(gradHandler), tokenLiquidity);
        address newPool;
        bool taxOnTransfer;
        if (quote == NATIVE) {
            (newPool, taxOnTransfer) =
                gradHandler.graduate{value: quoteLiquidity}(address(token), quote, quoteLiquidity, tokenLiquidity);
        } else {
            quoteHeld -= quoteLiquidity;
            IERC20(quote).safeTransfer(address(gradHandler), quoteLiquidity);
            (newPool, taxOnTransfer) = gradHandler.graduate(address(token), quote, quoteLiquidity, tokenLiquidity);
        }
        if (newPool == address(0)) revert POOL_ZERO();
        pool = newPool;
        // Classic AMM: tax on transfer. v4 hook venue: pool only leaves the dividend supply.
        if (taxOnTransfer) token.setMarket(newPool, true);
        else token.setExempt(newPool, true);
        emit Graduated(newPool, quoteLiquidity, tokenLiquidity);
        if (crosser != address(0)) {
            uint256 bonus = vault.payJackpot(crosser);
            if (bonus > 0) emit Jackpot(crosser, bonus, buyCount, true);
        }
    }

    function claimTreasury() external nonReentrant {
        uint256 amount = treasuryEarned;
        if (amount == 0) revert NOTHING_TO_CLAIM();
        treasuryEarned = 0;
        _sendQuote(treasury, amount);
        emit TreasuryClaimed(amount);
    }

    // ─── Quote plumbing ────────────────────────────────────────────────────────
    function _receiveQuote(uint256 amount) internal {
        if (quote == NATIVE) {
            if (msg.value != amount) revert BAD_VALUE();
        } else {
            if (msg.value != 0) revert BAD_VALUE();
            uint256 before = IERC20(quote).balanceOf(address(this));
            IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
            if (IERC20(quote).balanceOf(address(this)) - before != amount) revert BAD_VALUE();
            quoteHeld += amount;
        }
    }

    function _sendQuote(address to, uint256 amount) internal {
        if (quote == NATIVE) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TRANSFER_FAILED();
        } else {
            quoteHeld -= amount;
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    function _pushFee(uint256 amount, bool community) internal {
        if (quote == NATIVE) {
            if (community) vault.onCommunityFee{value: amount}(amount);
            else vault.onFee{value: amount}(amount);
        } else {
            quoteHeld -= amount;
            IERC20(quote).safeTransfer(address(vault), amount);
            if (community) vault.onCommunityFee(amount);
            else vault.onFee(amount);
        }
    }

    receive() external payable {}
}
