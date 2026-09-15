// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BondingFactory} from "../src/BondingFactory.sol";
import {NoopGradHandler} from "./TaxRouter.t.sol";
import {MockDex, TestStock} from "../src/periphery/TestnetHelpers.sol";
import {BarkToken} from "../src/BarkToken.sol";

contract DebugGasTest is Test {
    // This fixture is the factory's treasury, so it must accept the creation fee.
    receive() external payable {}

    function test_CreateVaultGas() public {
        TestStock stock = new TestStock("xTSLA", "xTSLA");
        MockDex dex = new MockDex();
        BondingFactory f = new BondingFactory(address(this), new NoopGradHandler());
        uint256 g0 = gasleft();
        (address token, address curve, address router) = f.createToken{value: 0.001 ether}(
            "HoodHound", "HOOD", BarkToken.Template.StockVault, 100, address(stock), address(this), address(dex)
        );
        console2.log("createToken gas:", g0 - gasleft());
        console2.log(token, curve, router);
    }
}
