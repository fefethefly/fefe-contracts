// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {LaunchpadV3Test} from "./LaunchpadV3.t.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {BondingCurveV3} from "../src/v3/BondingCurveV3.sol";
contract CurvePortfolioExitBoundaryTest is LaunchpadV3Test {
 function test_FirstMarketProposalUsesRemainingReserveAndExposesCreatorConcentration() public {
  // Same 18-decimal arithmetic as the ZC proposal, using native quote fixtures.
  // This verifies curve arithmetic, not ZC identity, oracle eligibility or V4 execution.
  LaunchpadV3.Launch memory p=baseParams();
  p.virtualQuote=500 ether;p.graduationQuote=2000 ether;p.firstBuyQuote=100 ether;
  p.buyTaxBps=300;p.sellTaxBps=500;p.jackpotEveryN=0;
  p.antiSnipeSeconds=60;p.antiSnipeMaxWalletBps=500;
  p.split.creatorBps=3000;p.split.basketBps=7000;p.split.jackpotBps=0;p.split.burnBps=0;
  vm.deal(creator,101 ether);vm.deal(alice,2100 ether);
  (MemeTokenV3 t,BondingCurveV3 c,)=launch(p,pad.CREATION_FEE()+100 ether);
  assertEq(c.backingReserve(),99 ether);
  assertEq(c.treasuryEarned(),1 ether);
  assertEq(t.balanceOf(creator),165275459098497495826377295);
  assertGt(t.balanceOf(creator),t.FIXED_SUPPLY()*500/10000,"first buy is exempt from ordinary wallet cap");
  uint256 openSpot=500 ether*1e18/t.FIXED_SUPPLY();
  assertEq(openSpot,500000000000,"raw quote units per whole token");
  vm.warp(block.timestamp+61);
  for(uint256 i;i<40;i++){vm.prank(alice);c.buy{value:50 ether}(50 ether,0,alice);}
  assertTrue(c.graduated());
  assertEq(grad.quoteReceived(),2019 ether);
  assertEq(c.treasuryEarned(),21 ether);
  assertEq(grad.tokenReceived(),198491464867010718539102831);
  uint256 finalCurveSpot=(grad.quoteReceived()+500 ether)*1e18/grad.tokenReceived();
  assertEq(finalCurveSpot,12690721999999);
  assertEq(finalCurveSpot*1000000/openSpot,25381443,"approximately 25.381444x before pool migration, not 5x");
 }
 function test_PortfolioFinalExitRoundingMatchesModel() public {
  LaunchpadV3.Launch memory p=baseParams();
  p.virtualQuote=500 ether;p.graduationQuote=2000 ether;
  p.buyTaxBps=0;p.sellTaxBps=0;p.antiSnipeSeconds=0;
  p.antiSnipeMaxWalletBps=0;p.antiSnipeTaxBps=0; // Two buys do not reach the fixture jackpot interval.
  (MemeTokenV3 t,BondingCurveV3 c,)=launch(p,pad.CREATION_FEE());
  vm.deal(alice,1000 ether);vm.deal(bob,1000 ether);
  vm.prank(alice);c.buy{value:100 ether}(100 ether,0,alice);
  vm.prank(bob);c.buy{value:500 ether}(500 ether,0,bob);
  vm.startPrank(alice);t.approve(address(c),type(uint256).max);c.sell(t.balanceOf(alice),0);vm.stopPrank();
  // Values from the separately executed TypeScript scenario, not production settings.
  assertEq(c.backingReserve(),303453112509379459842);
  assertEq(t.balanceOf(bob),377686149676639615690990163);
  (uint256 net,uint256 fee,uint256 tax)=c.quoteSell(t.balanceOf(bob));
  assertLe(net+fee+tax,c.backingReserve(),"payout must not exceed actual backing");
  uint256 held=t.balanceOf(bob);
  vm.startPrank(bob);t.approve(address(c),held);
  uint256 out=c.sell(held,net);vm.stopPrank();
  assertEq(out,300418581384285665243);
  assertEq(t.balanceOf(bob),0,"all owned tokens sold");
  assertEq(c.backingReserve(),1,"remaining dust matches model");
 }
}
