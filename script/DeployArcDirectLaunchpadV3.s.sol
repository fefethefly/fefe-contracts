// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {IPoolManager, PoolKey, V4} from "../src/v3/uniswap/V4Types.sol";
import {BarkHookV3} from "../src/v3/uniswap/BarkHookV3.sol";
import {UniswapV4GraduationHandlerV3} from "../src/v3/uniswap/UniswapV4GraduationHandlerV3.sol";
import {UniswapV4SwapAdapterV3} from "../src/v3/uniswap/UniswapV4SwapAdapterV3.sol";
import {FefeSink} from "../src/v3/FefeSink.sol";
import {DirectLaunchpadV3} from "../src/v3/DirectLaunchpadV3.sol";

/**
 * Arc mainnet deployment. First simulate with Circle Arc Foundry using profile.arc.
 * Broadcast only after independently verifying ARC_POOL_MANAGER_CODE_HASH and signer funding.
 * Requires an explicit owner-operated signer; the testnet rehearsal cannot call this script.
 * Script does not activate the website. Publish a source-verified chain 5042 release separately.
 */
contract DeployArcDirectLaunchpadV3 is Script {
    address constant ARC_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external {
        require(block.chainid == 5042, "Arc MAINNET 5042 required");
        (bool ok, bytes memory decimals) = address(0x3600000000000000000000000000000000000000).staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && abi.decode(decimals, (uint8)) == 6, "Arc native USDC interface mismatch");
        address broadcaster = msg.sender;
        address routeAdmin = vm.envOr("ROUTE_ADMIN", broadcaster);
        IPoolManager pm = IPoolManager(vm.envOr("POOL_MANAGER", ARC_POOL_MANAGER));
        require(address(pm) == ARC_POOL_MANAGER, "unexpected PoolManager");
        require(address(pm).codehash == vm.envBytes32("ARC_POOL_MANAGER_CODE_HASH"), "PoolManager version mismatch");
        require(CREATE2_FACTORY.code.length > 0, "CREATE2 factory missing; hook salt mining assumes it");

        vm.startBroadcast();
        UniswapV4SwapAdapterV3 adapter = new UniswapV4SwapAdapterV3(pm, broadcaster);
        FefeSink sink = new FefeSink(broadcaster, adapter);
        address treasury = vm.envOr("TREASURY", address(sink));

        UniswapV4GraduationHandlerV3 handler = new UniswapV4GraduationHandlerV3(pm, treasury);

        (bytes32 salt, address predicted) = _mineHookSalt(pm, address(handler));
        BarkHookV3 hook = new BarkHookV3{salt: salt}(pm, address(handler));
        require(address(hook) == predicted, "hook address mismatch");

        adapter.setHandler(handler);
        if (routeAdmin != broadcaster) adapter.setRouteAdmin(routeAdmin);

        DirectLaunchpadV3 directPad = new DirectLaunchpadV3(handler, adapter);
        handler.bindHook(hook);
        handler.bindDirect(address(directPad));
        vm.stopBroadcast();

        console2.log("chainId:", block.chainid);
        console2.log("PoolManager:", address(pm));
        console2.log("FefeSink:", address(sink));
        console2.log("Treasury:", treasury);
        console2.log("UniswapV4GraduationHandlerV3:", address(handler));
        console2.log("BarkHookV3:", address(hook));
        console2.log("  hook salt:", vm.toString(salt));
        console2.log("UniswapV4SwapAdapterV3:", address(adapter));
        console2.log("DirectLaunchpadV3:", address(directPad));
        console2.log("  TOKEN_INIT_CODE_HASH:", vm.toString(directPad.TOKEN_INIT_CODE_HASH()));
        console2.log("vaultDeployer:", address(directPad.vaultDeployer()));
        console2.log("Generate and review the six-contract BARK_ARC_MAINNET_DIRECT_POOL_RELEASE manifest before opening issuance.");
        console2.log("Read-only manifest tool: web/scripts/prepare-direct-pool-release.mjs --arc-mainnet");
    }

    function hookFlags() internal pure returns (uint160) {
        return V4.BEFORE_INITIALIZE_FLAG | V4.BEFORE_SWAP_FLAG | V4.AFTER_SWAP_FLAG | V4.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | V4.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    /// Mines a CREATE2 salt (against the deterministic factory) whose address carries exactly the hook's permission bits.
    function _mineHookSalt(IPoolManager pm, address handler) internal pure returns (bytes32 salt, address predicted) {
        bytes32 initHash = keccak256(abi.encodePacked(type(BarkHookV3).creationCode, abi.encode(pm, handler)));
        uint160 want = hookFlags();
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initHash)))));
            if ((uint160(predicted) & V4.ALL_HOOK_MASK) == want) return (salt, predicted);
        }
        revert("no hook salt found");
    }
}
