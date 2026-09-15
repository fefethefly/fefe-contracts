// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FefeBuybackHookV3} from "../src/v3/uniswap/FefeBuybackHookV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {IPoolManager, V4} from "../src/v3/uniswap/V4Types.sol";

/// Dry-run by default. Five deployment/configuration transactions, no buyback transaction.
/// Use --sender equal to the existing route admin. Never reads a private-key file.
contract DeployFefeBuybackHook is Script {
    address constant FEFE = 0x0814068a2e65efeEE2d78F9cc537370D1B62f76b;
    address constant PAD = 0x3Cb03A559F83f8fF59af48C043491A3728FdD396;
    address constant ADAPTER = 0xbd4556Fc59C980542ecd50095BB8396643df05cd;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    function run() external {
        require(block.chainid == 4663, "RH mainnet only");
        require(PM.codehash == 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626, "PM code changed");
        require(CREATE2_FACTORY.code.length > 0, "CREATE2 factory missing");
        UniswapV4SwapAdapterV3 adapter = UniswapV4SwapAdapterV3(payable(ADAPTER));
        address operator = adapter.routeAdmin();
        require(msg.sender == operator && operator != address(0), "sender must be existing route admin");
        require(
            !adapter.hasRoute(address(0), FEFE) && !adapter.hasRoute(NVDA, FEFE),
            "FEFE route already exists; review first"
        );
        bytes memory init = abi.encodePacked(type(FefeBuybackHookV3).creationCode, abi.encode(FEFE, PAD, operator));
        bytes32 initHash = keccak256(init);
        (bytes32 salt, address predicted) = _mine(initHash);

        vm.startBroadcast();
        FefeBuybackHookV3 hook = new FefeBuybackHookV3{salt: salt}(FEFE, PAD, operator);
        require(address(hook) == predicted && address(hook.adapter()) == ADAPTER, "deployment mismatch");
        IPoolManager(PM).initialize(hook.keyFor(address(0)), uint160(1 << 96));
        IPoolManager(PM).initialize(hook.keyFor(NVDA), uint160(1 << 96));
        adapter.setRoute(address(0), FEFE, hook.keyFor(address(0)));
        adapter.setRoute(NVDA, FEFE, hook.keyFor(NVDA));
        vm.stopBroadcast();

        console2.log("Hook", address(hook));
        console2.log("Operator", operator);
        console2.log("Original sink", address(hook.sink()));
        console2.log("Hook init code hash", vm.toString(initHash));
        console2.log("Hook runtime code hash", vm.toString(address(hook).codehash));
        console2.log("CREATE2 salt", vm.toString(salt));
        // An intentional-revert preview, excluded from the broadcast transaction list.
        // The preview itself always reverts, even if somebody broadcasts it directly.
        uint256 balance = address(hook.sink()).balance;
        if (balance > 0) {
            bool graduated = hook.curve().graduated();
            vm.prank(operator);
            try hook.preview(address(0), balance, graduated) {
                revert("preview unexpectedly returned");
            } catch (bytes memory reason) {
                require(
                    reason.length == 68 && bytes4(reason) == FefeBuybackHookV3.BuybackPreview.selector,
                    "full buyback preview failed"
                );
                uint256 q;
                uint256 burned;
                assembly {
                    q := mload(add(reason, 36))
                    burned := mload(add(reason, 68))
                }
                console2.log("Preview ETH input wei", balance);
                console2.log("Preview NVDA raw", q);
                console2.log("Preview FEFE burn raw", burned);
                console2.log("Preview reverted; no funds spent or burned");
            }
        }
    }

    function _mine(bytes32 hash) internal pure returns (bytes32 salt, address at) {
        uint160 flags = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 3);
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, hash)))));
            if ((uint160(at) & V4.ALL_HOOK_MASK) == flags) return (salt, at);
        }
        revert("no hook salt");
    }
}
