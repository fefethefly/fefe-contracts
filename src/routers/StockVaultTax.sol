// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITaxRouter} from "../interfaces.sol";

/**
 * @title StockVaultTax —— 股票金库模板(本平台独创)
 * 每笔税:50% 进入待回购池,由任何人触发 executeBuyback 换成关联股票代币注入无主金库
 * (「越交易越囤股」);25% 归创作者;25% 注入 curve 储备。
 *
 * 回收通过极简兑换接口执行;生产实现接 Uniswap v4 Quoter + TWAP 防夹
 * (ARCHITECTURE.md §6.2 / §6.3-8)。
 */
interface IExchangeRouter {
    /// @return outAmount 实际换得的 toToken 数量
    function swapExactIn(address fromToken, address toToken, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 outAmount);
}

contract StockVaultTax is ITaxRouter {
    error ONLY_TOKEN();
    error BIND_LOCKED();
    error NOTHING_TO_CLAIM();
    error NOTHING_PENDING();
    error SLIPPAGE();

    uint256 public constant VAULT_BPS = 5_000;
    uint256 public constant CREATOR_BPS = 2_500; // curve = 2_500

    IERC20 public immutable token;
    address payable public immutable creator;
    address public immutable admin; // 工厂:仅用于一次性 setCurve
    address public immutable stockToken; // 关联股票代币(如 xNVDA)
    address public immutable stockVault; // 无主金库(回购股票的归宿)
    IExchangeRouter public immutable dex;

    address public curve; // 绑定后不再可变
    uint256 public creatorEarned;
    uint256 public pendingBuyback; // 待回购的本币数量
    uint256 public totalStockAccumulated; // 已囤入金库的股票代币累计

    event Distributed(uint256 toVaultPending, uint256 toCreator, uint256 toCurve);
    event BuybackExecuted(uint256 memeIn, uint256 stockOut);

    constructor(
        IERC20 token_,
        address payable creator_,
        address stockToken_,
        address stockVault_,
        IExchangeRouter dex_
    ) {
        token = token_;
        creator = creator_;
        admin = msg.sender;
        stockToken = stockToken_;
        stockVault = stockVault_;
        dex = dex_;
    }

    /// 一次性绑定(仅工厂、仅一次)
    function setCurve(address curve_) external {
        if (!(msg.sender == admin && curve == address(0))) revert BIND_LOCKED();
        curve = curve_;
    }

    function onTax(uint256 tax) external override {
        if (!(msg.sender == address(token))) revert ONLY_TOKEN();
        uint256 toVault = (tax * VAULT_BPS) / 10_000;
        uint256 toCreator = (tax * CREATOR_BPS) / 10_000;
        uint256 toCurve = tax - toVault - toCreator;

        pendingBuyback += toVault;
        creatorEarned += toCreator;
        token.transfer(curve, toCurve);
        emit Distributed(toVault, toCreator, toCurve);
    }

    /// 任何人可执行(无特权 keeper):把累积 meme 换成股票代币进金库;失败整体 revert,资金保持待回购
    function executeBuyback(uint256 minOut) external returns (uint256 stockOut) {
        uint256 amountIn = pendingBuyback;
        if (!(amountIn > 0)) revert NOTHING_PENDING();
        pendingBuyback = 0;
        token.transfer(address(dex), amountIn);
        stockOut = dex.swapExactIn(address(token), stockToken, amountIn, minOut, stockVault);
        if (!(stockOut >= minOut)) revert SLIPPAGE();
        totalStockAccumulated += stockOut;
        emit BuybackExecuted(amountIn, stockOut);
    }

    function claimCreator() external {
        uint256 amount = creatorEarned;
        if (!(amount > 0)) revert NOTHING_TO_CLAIM();
        creatorEarned = 0;
        token.transfer(creator, amount);
    }
}
