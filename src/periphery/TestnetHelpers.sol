// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IGraduationHandler} from "../interfaces.sol";
import {IExchangeRouter} from "../routers/StockVaultTax.sol";

/**
 * 测试网辅助合约(仅 testnet,主网换真实实现):
 *  - TestGradHandler:毕业时收 ETH/代币并返回固定池地址(验证原子迁移)
 *  - MockDex:1:1 兑换并自行铸造 toToken(验证 StockVault 回购路径)
 *  - TestStock:测试用股票代币
 */
contract TestGradHandler is IGraduationHandler {
    address public constant POOL = address(0xB0B);

    function graduate(address, uint256) external payable override returns (address) {
        return POOL;
    }
}

contract MockDex is IExchangeRouter {
    function swapExactIn(address, address toToken, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 outAmount)
    {
        outAmount = amountIn; // 1:1
        require(outAmount >= minOut, "SLIPPAGE");
        IMintable(toToken).mint(recipient, outAmount);
    }
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract TestStock is ERC20, IMintable {
    // 测试网演示股票:开放铸造(零价值);主网用 Robinhood 官方 Stock Token
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface ITestHelpers {
    function thisIsOnlyForTestnet() external;
}
