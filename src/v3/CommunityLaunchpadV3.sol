// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchpadV3} from "./LaunchpadV3.sol";
import {IGraduationHandlerV3, ISwapAdapterV3} from "./InterfacesV3.sol";

/// Separate community candidate. Existing official FEFE stays in its original factory.
/// Fixes the normal trade fee at 80 bps to the creator's selected destinations and
/// 20 bps to the configured treasury. Existing anti-snipe penalties remain separate.
/// Deployment still requires validating the treasury and the graduation/adapter stack.
contract CommunityLaunchpadV3 is LaunchpadV3 {
    error COMMUNITY_FEE_MISMATCH();

    uint16 public constant COMMUNITY_CREATOR_BPS = 80;
    uint16 public constant COMMUNITY_PROTOCOL_BPS = 20;

    constructor(address treasury_, IGraduationHandlerV3 handler_, ISwapAdapterV3 adapter_)
        LaunchpadV3(treasury_, handler_, adapter_)
    {}

    function _validate(Launch calldata p) internal view override {
        if (
            p.buyTaxBps != COMMUNITY_CREATOR_BPS || p.sellTaxBps != COMMUNITY_CREATOR_BPS
                || p.protocolFeeBps != COMMUNITY_PROTOCOL_BPS
        ) revert COMMUNITY_FEE_MISMATCH();
        super._validate(p);
    }
}
