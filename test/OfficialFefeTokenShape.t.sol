// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";

contract OfficialFefeTokenShapeTest is Test {
    /// Issuer-catalog NVDA on Robinhood mainnet; the third-party "HOOD" is not a Stock Token.
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    function testOfficialMetadataIsMemestockFefe() public {
        MemeTokenV3 token = new MemeTokenV3();
        address[] memory rewards = new address[](1);
        rewards[0] = NVDA;
        address[] memory extra = new address[](0);
        token.initialize("FEFE", "FEFE", 100, 100, address(this), address(this), rewards, extra);

        assertEq(token.name(), "FEFE");
        assertEq(token.symbol(), "FEFE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(token.buyTaxBps(), 100);
        assertEq(token.sellTaxBps(), 100);
        assertEq(token.rewardTokens(0), NVDA);
    }
}
