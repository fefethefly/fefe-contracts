// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGraduationHandler} from "./interfaces.sol";

/**
 * @title BondingCurve —— 联合曲线(常积变体 x·y=k)
 *
 * 安全不变量(ARCHITECTURE.md §6.3):
 *   1) 无 owner / 无升级 / 无暂停 —— sell 结构性可用(反貔貅)
 *   2) quote 储备对账:backingReserve() = 实际余额 - 应付(创作者 + 平台)
 *   3) 毕业迁移失败整体 revert,不留半迁移状态
 *   4) 创作者分成只增不减,claim 无锁
 *
 * 计价资产:原生 ETH(股票代币计价模式待法务确认后以 ERC20 版本扩展)。
 */
contract BondingCurve {
    error ZERO_INPUT();
    error SLIPPAGE();
    error GRADUATED();
    error ALREADY_GRADUATED();
    error BELOW_THRESHOLD();
    error POOL_ZERO();
    error TOKEN_MIGRATE_FAIL();
    error ETH_TRANSFER_FAIL();
    error NOTHING_TO_CLAIM();

    uint256 public constant VIRTUAL_ETH = 0.5 ether;         // 虚拟储备:定价偏置
    uint256 public constant FEE_BPS = 100;                   // 曲线交易费 1%
    uint256 public constant CREATOR_FEE_SHARE = 5_000;       // 费的 50% 给创作者
    uint256 public constant GRADUATION_ETH = 25 ether;       // 毕业阈值(生产环境按美元价配置)

    IERC20 public immutable token;
    address payable public immutable creator;
    address public immutable treasury;                 // 平台费归宿(工厂注入)
    IGraduationHandler public immutable gradHandler;   // 毕业执行器(工厂注入)

    uint256 public creatorEarned;  // ETH,可随时 claim
    uint256 public treasuryEarned; // ETH,treasury 可随时 claim
    bool public graduated;
    address public pool; // 毕业后新池地址

    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 fee);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event CreatorClaimed(uint256 amount);
    event TreasuryClaimed(uint256 amount);
    event Graduated(address indexed pool, uint256 ethLiquidity, uint256 tokenLiquidity);

    constructor(
        IERC20 token_,
        address payable creator_,
        address treasury_,
        IGraduationHandler gradHandler_
    ) {
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
    function buy(uint256 minOut) external payable returns (uint256 out) {
        if (!(!graduated)) revert GRADUATED();
        if (!(msg.value > 0)) revert ZERO_INPUT();
        uint256 fee = (msg.value * FEE_BPS) / 10_000;
        uint256 net = msg.value - fee;

        // 定价必须用"交易前"储备:此时余额已含本次付款,需先扣除(否则重复计入,买家少拿代币)
        uint256 x = address(this).balance - msg.value + VIRTUAL_ETH;
        uint256 y = token.balanceOf(address(this));
        out = (y * net) / (x + net);
        if (!(out >= minOut)) revert SLIPPAGE();

        _accrue(fee);
        token.transfer(msg.sender, out);
        emit Bought(msg.sender, msg.value, out, fee);
    }

    function sell(uint256 tokensIn, uint256 minEthOut) external returns (uint256 net) {
        if (!(!graduated)) revert GRADUATED();
        if (!(tokensIn > 0)) revert ZERO_INPUT();
        uint256 gross = quoteSell(tokensIn);
        uint256 fee = (gross * FEE_BPS) / 10_000;
        net = gross - fee;
        if (!(net >= minEthOut)) revert SLIPPAGE();
        _accrue(fee);

        token.transferFrom(msg.sender, address(this), tokensIn);
        (bool ok,) = msg.sender.call{value: net}("");
        if (!(ok)) revert ETH_TRANSFER_FAIL();
        emit Sold(msg.sender, tokensIn, net, fee);
    }

    // ─── 毕业 ───────────────────────────────────────────────
    function graduate() external returns (address newPool) {
        if (!(!graduated)) revert ALREADY_GRADUATED();
        if (!(backingReserve() >= GRADUATION_ETH)) revert BELOW_THRESHOLD();

        uint256 ethLiquidity = backingReserve();
        uint256 tokenLiquidity = token.balanceOf(address(this));

        // 原子迁移:失败整体 revert(不变量 3)
        newPool = gradHandler.graduate{value: ethLiquidity}(address(token), tokenLiquidity);
        if (!(newPool != address(0))) revert POOL_ZERO();
        if (!(token.transfer(newPool, tokenLiquidity))) revert TOKEN_MIGRATE_FAIL();

        graduated = true;
        pool = newPool;
        emit Graduated(newPool, ethLiquidity, tokenLiquidity);
    }

    // ─── 分成领取 ───────────────────────────────────────────
    function claimCreator() external {
        uint256 amount = creatorEarned;
        if (!(amount > 0)) revert NOTHING_TO_CLAIM();
        creatorEarned = 0;
        (bool ok,) = creator.call{value: amount}("");
        if (!(ok)) revert ETH_TRANSFER_FAIL();
        emit CreatorClaimed(amount);
    }

    function claimTreasury() external {
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

    receive() external payable {} // 毕业失败退款等场景的资金安全网
}
