// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";

/// @dev Batch 144 smoke: tiny ETH-quote V3 meme on testnet LaunchpadV3.
/// Env: LAUNCHPAD (default testnet), optional SALT.
contract SmokeLaunchV3 is Script {
    address constant DEFAULT_PAD = 0x71D493380c5D2518dA244367057A074f28b6137a;

    function run() external {
        address padAddr = vm.envOr("LAUNCHPAD", DEFAULT_PAD);
        bytes32 salt = vm.envOr("SALT", bytes32(uint256(0x1440007)));
        uint256 firstBuy = 0.0001 ether;
        uint256 fee = LaunchpadV3(payable(padAddr)).CREATION_FEE();

        address[] memory basket = new address[](0);
        uint16[] memory weights = new uint16[](0);

        LaunchpadV3.Launch memory p = LaunchpadV3.Launch({
            name: "V3Smoke",
            symbol: "V3SM",
            quoteAsset: NATIVE,
            virtualQuote: uint128(0.05 ether), // small curve for smoke
            graduationQuote: uint128(0.5 ether),
            buyTaxBps: 0,
            sellTaxBps: 0,
            protocolFeeBps: 20,
            split: FeeVaultV3.Split({creatorBps: 10000, basketBps: 0, jackpotBps: 0, burnBps: 0}),
            basketTokens: basket,
            basketWeights: weights,
            antiSnipeSeconds: 60,
            antiSnipeMaxWalletBps: 100,
            antiSnipeTaxBps: 3000,
            jackpotEveryN: 0,
            jackpotMinBuy: 0,
            salt: salt,
            firstBuyQuote: firstBuy,
            minFirstBuyOut: 0,
            deadline: block.timestamp + 1 hours
        });

        address predicted = LaunchpadV3(payable(padAddr)).predictToken(msg.sender, salt);
        console2.log("pad", padAddr);
        console2.log("predicted token", predicted);
        console2.log("value", fee + firstBuy);

        vm.startBroadcast();
        (address token, address curve, address vault) =
            LaunchpadV3(payable(padAddr)).create{value: fee + firstBuy}(p);
        vm.stopBroadcast();

        console2.log("token", token);
        console2.log("curve", curve);
        console2.log("vault", vault);
    }
}
