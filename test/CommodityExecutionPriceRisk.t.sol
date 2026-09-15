// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommodityAdapterFixture} from "./CommoditySwapAdapterV3.t.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";

/// Local risk reproduction, NOT a security acceptance test. No real pool is manipulated.
/// A green test here demonstrates a release blocker in the current permissionless vault.
contract CommodityExecutionPriceRiskTest is CommodityAdapterFixture {
    function test_risk_arbitraryCallerCanUseTinyFloorAtAdverseVenuePrice() public {
        (MemeTokenV3 token, FeeVaultV3 vault) = vaultSetup();
        guard.validate(address(corn));
        guard.validate(address(coffee));
        coffeePool.setMode(7);
        uint256[] memory callerFloors = new uint256[](1);
        callerFloors[0] = 1;
        vm.prank(makeAddr("untrusted-keeper"));
        vault.buyBasket(callerFloors);
        assertEq(vault.basketPending(), 0);
        assertEq(token.totalDistributed(address(coffee)), 0.1 ether);
        assertEq(coffee.balanceOf(address(token)), 0.1 ether);
        // Ten units were consumed for a reward worth only 1% of the fixture's normal output.
        // Source health and nonzero minOut cannot authorize a public treasury exchange.
        assertEq(corn.balanceOf(address(vault)), 0);
    }

    function test_meaningfulFloorProtectsBudgetButIsNotCurrentlyEnforcedOnEveryCaller() public {
        (MemeTokenV3 token, FeeVaultV3 vault) = vaultSetup();
        coffeePool.setMode(7);
        uint256[] memory reviewedFloors = new uint256[](1);
        reviewedFloors[0] = 9.9 ether;
        vm.expectRevert();
        vault.buyBasket(reviewedFloors);
        assertEq(vault.basketPending(), 10 ether);
        assertEq(corn.balanceOf(address(vault)), 10 ether);
        assertEq(token.totalDistributed(address(coffee)), 0);
    }
}
