// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGraduationHandler} from "../interfaces.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 *  @notice Versioned candidate curve. Not deployed or audited for public funds.
 * Quotes and execution use backing only; accrued fees stay outside price reserves.
 */
contract BondingCurveV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error ZERO_INPUT();
    error INSUFFICIENT_BACKING();
    error SLIPPAGE();
    error GRADUATED();
    error ALREADY_GRADUATED();
    error BELOW_THRESHOLD();
    error POOL_ZERO();
    error TOKEN_MIGRATE_FAIL();
    error ETH_TRANSFER_FAIL();
    error NOTHING_TO_CLAIM();

    uint256 public constant VIRTUAL_ETH = 0.5 ether; // 虚拟储备:定价偏置
    uint256 public constant FEE_BPS = 100; // 曲线交易费 1%
    uint256 public constant CREATOR_FEE_SHARE = 5_000; // 费的 50% 给创作者
    uint256 public constant GRADUATION_ETH = 25 ether; // 候选固定阈值；不是美元锚定

    IERC20 public immutable token;
    address payable public immutable creator;
    address public immutable treasury; // 固定平台费用接收人
    IGraduationHandler public immutable gradHandler; // 固定毕业执行器；集成仍需验证

    uint256 public creatorEarned; // ETH,可随时 claim
    uint256 public treasuryEarned; // ETH,treasury 可随时 claim
    bool public graduated;
    address public pool; // 毕业后新池地址

    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 fee);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event CreatorClaimed(uint256 amount);
    event TreasuryClaimed(uint256 amount);
    event Graduated(address indexed pool, uint256 ethLiquidity, uint256 tokenLiquidity);

    constructor(IERC20 token_, address payable creator_, address treasury_, IGraduationHandler gradHandler_) {
        token = token_;
        creator = creator_;
        treasury = treasury_;
        gradHandler = gradHandler_;
    }

    // ─── 报价 ───────────────────────────────────────────────
    function backingReserve() public view returns (uint256) {
        return address(this).balance - creatorEarned - treasuryEarned;
    }

    function quoteBuy(uint256 ethInNet) public view returns (uint256 out) {
        uint256 x = backingReserve() + VIRTUAL_ETH;
        uint256 y = token.balanceOf(address(this));
        out = (y * ethInNet) / (x + ethInNet); // 与 buy() 同式:视图报价与实际执行严格一致
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 grossEthOut) {
        uint256 x = backingReserve() + VIRTUAL_ETH;
        uint256 y = token.balanceOf(address(this));
        grossEthOut = x - (x * y) / (y + tokensIn);
    }

    // ─── 交易 ───────────────────────────────────────────────
    function buy(uint256 minOut) external payable nonReentrant returns (uint256 out) {
        if (graduated) revert GRADUATED();
        if (!(msg.value > 0)) revert ZERO_INPUT();
        uint256 fee = (msg.value * FEE_BPS) / 10_000;
        uint256 net = msg.value - fee;

        // 定价必须用"交易前"储备:此时余额已含本次付款,需先扣除(否则重复计入,买家少拿代币)
        uint256 x = backingReserve() - msg.value + VIRTUAL_ETH;
        uint256 y = token.balanceOf(address(this));
        out = (y * net) / (x + net);
        if (!(out >= minOut)) revert SLIPPAGE();

        _accrue(fee);
        token.safeTransfer(msg.sender, out);
        emit Bought(msg.sender, msg.value, out, fee);
    }

    function sell(uint256 tokensIn, uint256 minEthOut) external nonReentrant returns (uint256 net) {
        if (graduated) revert GRADUATED();
        if (!(tokensIn > 0)) revert ZERO_INPUT();
        uint256 gross = quoteSell(tokensIn);
        if (gross > backingReserve()) revert INSUFFICIENT_BACKING();
        uint256 fee = (gross * FEE_BPS) / 10_000;
        net = gross - fee;
        if (!(net >= minEthOut)) revert SLIPPAGE();
        _accrue(fee);

        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        (bool ok,) = msg.sender.call{value: net}("");
        if (!(ok)) revert ETH_TRANSFER_FAIL();
        emit Sold(msg.sender, tokensIn, net, fee);
    }

    // ─── 毕业 ───────────────────────────────────────────────
    function graduate() external nonReentrant returns (address newPool) {
        if (graduated) revert ALREADY_GRADUATED();
        if (!(backingReserve() >= GRADUATION_ETH)) revert BELOW_THRESHOLD();

        uint256 ethLiquidity = backingReserve();
        uint256 tokenLiquidity = token.balanceOf(address(this));

        // Calls revert atomically; successful return alone does not prove a liquid DEX pool.
        newPool = gradHandler.graduate{value: ethLiquidity}(address(token), tokenLiquidity);
        if (!(newPool != address(0))) revert POOL_ZERO();
        token.safeTransfer(newPool, tokenLiquidity);

        graduated = true;
        pool = newPool;
        emit Graduated(newPool, ethLiquidity, tokenLiquidity);
    }

    // ─── 分成领取 ───────────────────────────────────────────
    function claimCreator() external nonReentrant {
        uint256 amount = creatorEarned;
        if (!(amount > 0)) revert NOTHING_TO_CLAIM();
        creatorEarned = 0;
        (bool ok,) = creator.call{value: amount}("");
        if (!(ok)) revert ETH_TRANSFER_FAIL();
        emit CreatorClaimed(amount);
    }

    function claimTreasury() external nonReentrant {
        uint256 amount = treasuryEarned;
        if (!(amount > 0)) revert NOTHING_TO_CLAIM();
        treasuryEarned = 0;
        (bool ok,) = treasury.call{value: amount}("");
        if (!(ok)) revert ETH_TRANSFER_FAIL();
        emit TreasuryClaimed(amount);
    }

    function _accrue(uint256 fee) internal {
        uint256 toCreator = (fee * CREATOR_FEE_SHARE) / 10_000;
        creatorEarned += toCreator;
        treasuryEarned += fee - toCreator; // 对账不变量:fee 全额进入应付款
    }

    receive() external payable {} // Direct ETH donations increase backing; they are not fee income.
}
