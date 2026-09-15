// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// 税路由:接收 BarkToken 转账税,按模板分发。
/// 实现合约必须:比例和恒等于 100%、无 owner、创建后不可修改参数。
interface ITaxRouter {
    /// @dev BarkToken 在每次计税转账后调用,tax 数量的代币已转到本合约。
    function onTax(uint256 tax) external;
}

/// 毕业处理器:curve 募资达阈值后接管流动性(生产实现 = 部署 Uniswap v4 池 + LP Timelock)。
interface IGraduationHandler {
    /// @param token 毕业代币
    /// @param tokenLiquidity curve 中剩余的代币(将全额注入新池)
    /// @return pool 新池地址
    function graduate(address token, uint256 tokenLiquidity) external payable returns (address pool);
}
