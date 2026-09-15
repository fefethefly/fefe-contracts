// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITaxRouter} from "../interfaces.sol";

/**
 * @title CreatorTax —— 创作者税模板(flap.sh 验证模式)
 * 每笔税:60% 归创作者(以本币计,随时 claim)、30% 注入 curve 增厚储备、10% 燃烧。
 * 无 owner;比例与受益人固定;curve 由工厂在同交易内一次性绑定。
 */
contract CreatorTax is ITaxRouter {
    error ONLY_TOKEN();
    error BIND_LOCKED();
    error NOTHING_TO_CLAIM();

    uint256 public constant CREATOR_BPS = 6_000;
    uint256 public constant CURVE_BPS = 3_000; // 燃烧 = 1_000

    IERC20 public immutable token;
    address payable public immutable creator;
    address public immutable admin; // 工厂:仅用于一次性 setCurve

    address public curve; // 绑定后不再可变
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public creatorEarned;

    event Distributed(uint256 toCreator, uint256 toCurve, uint256 burned);
    event CreatorClaimed(uint256 amount);

    constructor(IERC20 token_, address payable creator_) {
        token = token_;
        creator = creator_;
        admin = msg.sender;
    }

    /// 一次性绑定(仅工厂、仅一次)
    function setCurve(address curve_) external {
        if (!(msg.sender == admin && curve == address(0))) revert BIND_LOCKED();
        curve = curve_;
    }

    function onTax(uint256 tax) external override {
        if (!(msg.sender == address(token))) revert ONLY_TOKEN();
        uint256 toCreator = (tax * CREATOR_BPS) / 10_000;
        uint256 toCurve = (tax * CURVE_BPS) / 10_000;
        uint256 burned = tax - toCreator - toCurve;

        creatorEarned += toCreator;
        token.transfer(curve, toCurve); // 增厚 curve 代币储备(毕业时随池注入)
        token.transfer(DEAD, burned);
        emit Distributed(toCreator, toCurve, burned);
    }

    function claimCreator() external {
        uint256 amount = creatorEarned;
        if (!(amount > 0)) revert NOTHING_TO_CLAIM();
        creatorEarned = 0;
        token.transfer(creator, amount);
        emit CreatorClaimed(amount);
    }
}
