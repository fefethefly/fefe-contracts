// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITaxRouter} from "./interfaces.sol";

/**
 * @title BarkToken —— 可编程代币标准(Phase 2 F9)
 *
 * 发币时选定模板与税率,创建后不可修改。三模板:
 *   Creator    60% 创作者 / 30% curve 储备 / 10% 燃烧     (flap.sh 验证模式)
 *   Holder     70% 按持仓占比实时分红 / 30% curve 储备      (Hold-to-Earn,税留代币内结算)
 *   StockVault 50% 股票金库 / 25% 创作者 / 25% curve 储备  (越交易越囤股,本平台独创)
 *
 * 安全不变量(见 ARCHITECTURE.md §6.3):
 *   - 无 owner / 无暂停 / 无黑名单 —— sell 结构性可用(反貔貅)
 *   - 税率上限 300bp;模板与税率 immutable
 *   - 税只对非豁免地址间转账收取;豁免表只在绑定交易内写入(curve / router / 工厂)
 *   - router/curve 为同交易一次性绑定(见 BondingFactory 注释),绑定后 seal
 */
contract BarkToken is ERC20 {
    enum Template {
        None,       // 0:无税
        Creator,    // 1:创作者税
        Holder,     // 2:持有者分红(税留代币内,按持仓结算)
        StockVault  // 3:股票金库
    }

    error TAX_TOO_HIGH();
    error BIND_LOCKED();
    error NOT_HOLDER_TEMPLATE();

    uint256 public constant MAX_TAX_BPS = 300;
    uint256 public constant FIXED_SUPPLY = 1_000_000_000 ether;
    uint256 private constant SHARE_SCALE = 1e24;

    Template public immutable template;
    uint256 public immutable taxBps;
    address public immutable deployer; // 工厂,仅用于同交易 bind

    ITaxRouter public taxRouter; // 绑定后不再可变(Holder/None 为零地址)
    address public curve;
    bool public bound;

    mapping(address => bool) public exempt;

    // Holder 模板分红累加器(per-share 结算)
    uint256 public pointsPerShare;
    mapping(address => uint256) public userPoints;

    event TaxCollected(address indexed from, uint256 tax);
    event HolderClaimed(address indexed user, uint256 amount);
    event Bound(address router, address curve);

    constructor(string memory name_, string memory symbol_, Template template_, uint256 taxBps_) ERC20(name_, symbol_) {
        if (!(taxBps_ <= MAX_TAX_BPS)) revert TAX_TOO_HIGH();
        template = template_;
        taxBps = taxBps_;
        deployer = msg.sender;
        exempt[msg.sender] = true;    // 工厂(其向 curve 的转账不计税)
        exempt[address(this)] = true; // 分红池自身:claim 转出不再计税
        _mint(msg.sender, FIXED_SUPPLY); // 公平发射:无创作者预留
    }

    /// 一次性绑定(仅工厂、仅未绑定、仅一次)
    function bind(address router, address curve_) external {
        if (!(msg.sender == deployer && !bound)) revert BIND_LOCKED();
        taxRouter = ITaxRouter(router);
        curve = curve_;
        exempt[curve_] = true;
        exempt[router] = true;
        bound = true;
        emit Bound(router, curve_);
    }

    /// Holder 模板:领取按持仓累积的分红(以本币结算)
    function claimHolderYield() external returns (uint256 pending) {
        if (!(template == Template.Holder)) revert NOT_HOLDER_TEMPLATE();
        pending = _pendingYield(msg.sender);
        if (pending > 0) {
            userPoints[msg.sender] = pointsPerShare;
            _transfer(address(this), msg.sender, pending);
            emit HolderClaimed(msg.sender, pending);
        }
    }

    function pendingYield(address user) external view returns (uint256) {
        return _pendingYield(user);
    }

    function _pendingYield(address user) internal view returns (uint256) {
        return (balanceOf(user) * (pointsPerShare - userPoints[user])) / SHARE_SCALE;
    }

    /// OZ v5 转账钩子:计税在此完成
    function _update(address from, address to, uint256 value) internal override {
        // Holder 模板:任何余额变动前先结算双方指针 —— 分红守恒不变量(总领取 ≤ 总计税)
        if (template == Template.Holder && value > 0) {
            if (from != address(0)) userPoints[from] = pointsPerShare;
            if (to != address(0)) userPoints[to] = pointsPerShare;
        }
        if (value > 0 && taxBps > 0 && !exempt[from] && !exempt[to] && from != to) {
            uint256 tax = (value * taxBps) / 10_000;
            if (tax > 0) {
                if (template == Template.Holder) {
                    // 税留代币内,per-share 结算给全体持有人
                    super._update(from, address(this), tax);
                    pointsPerShare += (tax * SHARE_SCALE) / totalSupply();
                    emit TaxCollected(from, tax);
                    super._update(from, to, value - tax);
                } else {
                    super._update(from, address(taxRouter), tax);
                    taxRouter.onTax(tax);
                    emit TaxCollected(from, tax);
                    super._update(from, to, value - tax);
                }
                return;
            }
        }
        super._update(from, to, value);
    }
}
