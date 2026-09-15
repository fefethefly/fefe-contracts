// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";

/// @dev Batch 151: taxed ETH-quote V3 with HOOD basket + burn (会衔-style stock vault).
/// Env: LAUNCHPAD (default testnet), optional SALT.
/// First buy is tax-free; follow with a tiny curve buy to fill basketPending/burnPending.
contract SmokeLaunchV3Tax is Script {
    address constant DEFAULT_PAD = 0x71D493380c5D2518dA244367057A074f28b6137a;
    address constant HOOD = 0x972e99afe1E677b7dB0B00a3C207170784f485d6;

    function run() external {
        address padAddr = vm.envOr("LAUNCHPAD", DEFAULT_PAD);
        bytes32 salt = vm.envOr("SALT", bytes32(uint256(0x1510001)));
        uint256 firstBuy = 0.00005 ether;
        uint256 fee = LaunchpadV3(payable(padAddr)).CREATION_FEE();

        address[] memory basket = new address[](1);
        basket[0] = HOOD;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;

        LaunchpadV3.Launch memory p = LaunchpadV3.Launch({
            name: "V3Tax",
            symbol: "V3TX",
            quoteAsset: NATIVE,
            virtualQuote: uint128(0.05 ether),
            graduationQuote: uint128(0.5 ether),
            buyTaxBps: 80,
            sellTaxBps: 80,
            protocolFeeBps: 20,
            split: FeeVaultV3.Split({creatorBps: 10000, basketBps: 0, jackpotBps: 0, burnBps: 0}),
            basketTokens: basket,
            basketWeights: weights,
            antiSnipeSeconds: 0, // off — keep smoke tax math clean
            antiSnipeMaxWalletBps: 0,
            antiSnipeTaxBps: 0,
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
        console2.log("HOOD basket", HOOD);
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
