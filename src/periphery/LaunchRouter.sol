// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BondingFactory} from "../BondingFactory.sol";
import {BondingCurve} from "../BondingCurve.sol";
import {BarkToken} from "../BarkToken.sol";

/**
 * @notice EOA 发币入口 + 创作者首买。
 * 链怪癖:EOA 直连 factory.createToken 会 revert(见 DEPLOYMENTS.md),必须经合约中转;
 * 工厂只收 0.001 创建费,多余的 value 在这里折算成曲线首买,代币直接归创作者。
 */
contract LaunchRouter {
    uint256 public constant CREATION_FEE = 0.001 ether;

    event Created(address indexed creator, address indexed token, address curve, address taxRouter);

    function tryCreate(
        address factory,
        string calldata name,
        string calldata symbol,
        uint8 template,
        uint16 taxBps,
        address stock,
        address vault,
        address dex
    ) external payable {
        (address t, address c, address r) =
            BondingFactory(factory).createToken{value: CREATION_FEE}(name, symbol, BarkToken.Template(template), taxBps, stock, vault, dex);

        uint256 leftover = msg.value - CREATION_FEE;
        if (leftover > 0) {
            // 首买:代币发给 router,再原额转给创作者(链上公开可查)
            uint256 out = BondingCurve(payable(c)).buy{value: leftover}(0);
            BarkToken(t).transfer(msg.sender, out);
        }

        emit Created(msg.sender, t, c, r);
    }
}
