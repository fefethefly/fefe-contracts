// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FefeAnchor} from "../src/fefe/FefeAnchor.sol";

/// @notice Testnet 46630 only. Mainnet 4663 waits for unveil — this script refuses it.
contract DeployFefeAnchor is Script {
    uint256 internal constant TESTNET = 46630;
    uint256 internal constant MAINNET = 4663;

    function run() external {
        require(block.chainid == TESTNET, "FefeAnchor: deploy on Robinhood testnet 46630 only; mainnet waits for unveil");
        require(block.chainid != MAINNET, "FefeAnchor: mainnet gated");
        address signer_ = vm.envAddress("FEFE_ANCHOR_SIGNER");
        vm.startBroadcast();
        FefeAnchor anchor = new FefeAnchor(signer_);
        vm.stopBroadcast();
        console2.log("FefeAnchor", address(anchor));
        console2.log("signer", signer_);
        console2.log("chainId", block.chainid);
    }
}
