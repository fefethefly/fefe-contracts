// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3} from "../src/v3/LaunchpadV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {FefeSink} from "../src/v3/FefeSink.sol";

/// @notice Official FEFE as a LaunchpadV3 Memestock on Robinhood mainnet 4663.
/// Default quote is NVDA (issuer catalog, ETH/NVDA adapter route planned in DeployLaunchpadV3).
/// GOOGL is the flybrain-style override. Not Instant ETH. Not Pons.
/// The third-party "HOOD" 0x32ac8c1d… is not an issuer Stock Token and is deliberately absent.
///
/// Single-layer 1% fee. Official split is creator 0 / basket 50 / burn 50; protocolFeeBps = 0.
///
/// Requires a broadcast LaunchpadV3 on 4663 (`docs/DEPLOYMENTS.md` — mainnet pad still pending).
/// Creator must hold the quote Stock Token for the first buy and ETH for the 0.0005 creation fee.
///
///   export LAUNCHPAD=0x…
///   export OFFICIAL_FEFE_QUOTE=NVDA          # or GOOGL
///   export OFFICIAL_FEFE_MIN_OUT=…           # after simulating tokensOut
///   forge script script/DeployOfficialFefe.s.sol --rpc-url $RH_MAINNET_RPC \
///     --private-key $DEPLOYER_KEY --evm-version cancun --broadcast -vv
contract DeployOfficialFefe is Script {
    uint256 internal constant MAINNET = 4663;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;

    struct Plan {
        address quote;
        LaunchpadV3.Launch launch;
    }

    function run() external {
        require(block.chainid == MAINNET, "Official FEFE: Robinhood mainnet 4663 only");
        address padAddr = vm.envAddress("LAUNCHPAD");
        require(padAddr.code.length > 0, "Official FEFE: LaunchpadV3 not deployed; run DeployLaunchpadV3 first");

        Plan memory plan = _plan();
        require(plan.quote.code.length > 0, "Official FEFE: quote stock has no code");

        LaunchpadV3 pad = LaunchpadV3(payable(padAddr));
        address predicted = pad.predictToken(msg.sender, plan.launch.salt);
        uint256 fee = pad.CREATION_FEE();
        _announce(padAddr, predicted, fee, plan);

        vm.startBroadcast();
        IERC20(plan.quote).approve(padAddr, plan.launch.firstBuyQuote);
        (address token, address curve, address vault) = pad.create{value: fee}(plan.launch);
        _bindSink(pad, token);
        vm.stopBroadcast();

        require(token == predicted, "Official FEFE: CREATE2 mismatch");
        console2.log("token", token);
        console2.log("curve", curve);
        console2.log("vault", vault);
        console2.log("NEXT_PUBLIC_OFFICIAL_TOKEN", token);
        console2.log("NEXT_PUBLIC_LAUNCHPAD_V3_ADDRESS", padAddr);
    }

    function _plan() internal view returns (Plan memory plan) {
        plan.quote = _quote(vm.envOr("OFFICIAL_FEFE_QUOTE", string("NVDA")));
        bytes32 salt = vm.envOr("OFFICIAL_FEFE_SALT", keccak256("fefe-official-memestock-2026-09-12"));
        // First buy is locked at 0.5 NVDA. Curve $5,000 / $40,000 still uses a live mid.
        uint256 firstBuy = vm.envOr("OFFICIAL_FEFE_FIRST_BUY_QUOTE_WEI", uint256(0.5 ether));
        uint256 virtualQuote = vm.envOr("OFFICIAL_FEFE_VIRTUAL_QUOTE_WEI", uint256(21.551724 ether));
        uint256 graduationQuote = vm.envOr("OFFICIAL_FEFE_GRADUATION_QUOTE_WEI", uint256(172.413793 ether));
        require(firstBuy > 0 && virtualQuote > 0 && graduationQuote > 0, "Official FEFE: curve/first-buy unset");
        require(graduationQuote >= virtualQuote * 2, "Official FEFE: graduation must be >= 2x virtual quote");

        address[] memory basket = new address[](1);
        basket[0] = plan.quote;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        plan.launch = LaunchpadV3.Launch({
            name: "FEFE",
            symbol: "FEFE",
            quoteAsset: plan.quote,
            virtualQuote: uint128(virtualQuote),
            graduationQuote: uint128(graduationQuote),
            buyTaxBps: 100,
            sellTaxBps: 100,
            protocolFeeBps: 0,
            split: FeeVaultV3.Split({creatorBps: 0, basketBps: 5000, jackpotBps: 0, burnBps: 5000}),
            basketTokens: basket,
            basketWeights: weights,
            antiSnipeSeconds: 60,
            antiSnipeMaxWalletBps: 500,
            antiSnipeTaxBps: 3000,
            jackpotEveryN: 0,
            jackpotMinBuy: 0,
            salt: salt,
            firstBuyQuote: firstBuy,
            minFirstBuyOut: _minOut(),
            deadline: block.timestamp + vm.envOr("OFFICIAL_FEFE_DEADLINE_SECONDS", uint256(1800))
        });
    }

    function _announce(address padAddr, address predicted, uint256 fee, Plan memory plan) internal pure {
        console2.log("launchpad", padAddr);
        console2.log("quote", plan.quote);
        console2.log("predicted token", predicted);
        console2.log("firstBuyQuoteWei", plan.launch.firstBuyQuote);
        console2.log("virtualQuoteWei", uint256(plan.launch.virtualQuote));
        console2.log("graduationQuoteWei", uint256(plan.launch.graduationQuote));
        console2.log("minOut", plan.launch.minFirstBuyOut);
        console2.log("creationFeeWei", fee);
    }

    function _bindSink(LaunchpadV3 pad, address token) internal {
        address treasury = pad.treasury();
        if (treasury.code.length == 0) return;
        FefeSink sink = FefeSink(payable(treasury));
        try sink.admin() returns (address a) {
            if (a == msg.sender && sink.fefe() == address(0)) {
                sink.setFefe(token);
                console2.log("FefeSink.fefe", token);
            }
        } catch {}
    }

    function _minOut() internal view returns (uint256 minOut) {
        minOut = vm.envUint("OFFICIAL_FEFE_MIN_OUT");
        require(minOut > 1, "Official FEFE: set OFFICIAL_FEFE_MIN_OUT from a simulated tokensOut (99%)");
    }

    function _quote(string memory symbol) internal pure returns (address) {
        bytes32 id = keccak256(bytes(symbol));
        if (id == keccak256("GOOGL")) return GOOGL;
        if (id == keccak256("NVDA")) return NVDA;
        revert("Official FEFE: quote must be NVDA or GOOGL (issuer catalog)");
    }
}
