// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Tiny {
    uint256 public x = 42;
}

contract CreateProbe {
    event Made(address a);

    function make() external returns (address) {
        Tiny t = new Tiny();
        emit Made(address(t));
        return address(t);
    }
}

import {BondingFactory} from "../BondingFactory.sol";
import {BarkToken} from "../BarkToken.sol";

contract CallerProbe {
    event Created(address token, address curve, address router);

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
            BondingFactory(factory).createToken{value: msg.value}(name, symbol, BarkToken.Template(template), taxBps, stock, vault, dex);
        emit Created(t, c, r);
    }
}
