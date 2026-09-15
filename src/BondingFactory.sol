// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BarkToken} from "./BarkToken.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {CreatorTax} from "./routers/CreatorTax.sol";
import {StockVaultTax, IExchangeRouter} from "./routers/StockVaultTax.sol";
import {IGraduationHandler} from "./interfaces.sol";

/**
 * @title BondingFactory —— 发币工厂(Phase 2 F6/F7/F9)
 *
 * 无 owner、无暂停、无白名单:任何人可发币,费率与阈值为常量。
 *
 * 部署顺序(token ↔ router ↔ curve 存在循环引用,用"同交易一次性绑定"解决):
 *   1. BarkToken(供给 mint 给工厂)
 *   2. TaxRouter(可选,引用 token + 创作者;curve 槽待绑)
 *   3. BondingCurve(引用 token + 创作者 + treasury + 毕业处理器)
 *   4. 一次性绑定 router.setCurve + token.bind —— 全部在同一交易内完成,
 *      部署交易结束后无可再调用的初始化入口(审计阶段可替换为 CREATE3 预计算地址)
 *   5. 全部供给注入 curve;创建费归 treasury
 */
contract BondingFactory {
    error FEE_REQUIRED();
    error TAX_TOO_HIGH();
    error STOCK_PARAMS();
    error STOCK_ONLY_FOR_VAULT();
    error FEE_TRANSFER_FAIL();

    address public immutable treasury;
    IGraduationHandler public immutable gradHandler;

    uint256 public constant CREATION_FEE = 0.001 ether; // 防垃圾发币,归 treasury

    event TokenCreated(
        address indexed creator,
        address indexed token,
        address curve,
        address taxRouter,
        BarkToken.Template template,
        uint256 taxBps,
        address stockToken
    );

    constructor(address treasury_, IGraduationHandler gradHandler_) {
        treasury = treasury_;
        gradHandler = gradHandler_;
    }

    /**
     * @param template  0=无税 1=创作者税 2=持有者分红 3=股票金库
     * @param taxBps    税率(bp,≤300)
     * @param stockToken / stockVault / dex:仅股票金库模板必填,其余模板必须为零地址
     */
    function createToken(
        string calldata name,
        string calldata symbol,
        BarkToken.Template template,
        uint256 taxBps,
        address stockToken,
        address stockVault,
        address dex
    ) external payable returns (address token, address curve, address router) {
        if (!(msg.value >= CREATION_FEE)) revert FEE_REQUIRED();
        if (!(taxBps <= 300)) revert TAX_TOO_HIGH();
        bool isVault = template == BarkToken.Template.StockVault;
        if (isVault) {
            if (!(stockToken != address(0) && stockVault != address(0) && dex != address(0))) revert STOCK_PARAMS();
        } else {
            if (!(stockToken == address(0) && stockVault == address(0) && dex == address(0))) revert STOCK_ONLY_FOR_VAULT();
        }

        // 1) token:供给 mint 给工厂(工厂豁免),待绑
        BarkToken t = new BarkToken(name, symbol, template, taxBps);

        // 2) router(按模板)
        if (template == BarkToken.Template.Creator) {
            router = address(new CreatorTax(IERC20(address(t)), payable(msg.sender)));
        } else if (isVault) {
            router = address(
                new StockVaultTax(IERC20(address(t)), payable(msg.sender), stockToken, stockVault, IExchangeRouter(dex))
            );
        }

        // 3) curve
        curve = address(new BondingCurve(IERC20(address(t)), payable(msg.sender), treasury, gradHandler));

        // 4) 同交易一次性绑定
        if (router != address(0)) ICurveBindable(router).setCurve(curve);
        t.bind(router, curve);

        // 5) 公平发射:全部供给进 curve,工厂与创作者零预留
        t.transfer(curve, t.totalSupply());

        // 6) 创建费
        (bool ok,) = treasury.call{value: msg.value}("");
        if (!(ok)) revert FEE_TRANSFER_FAIL();

        token = address(t);
        emit TokenCreated(msg.sender, token, curve, router, template, taxBps, stockToken);
    }
}

/// 一次性 curve 绑定(routers 实现;仅工厂可调且仅一次)
interface ICurveBindable {
    function setCurve(address curve) external;
}
