// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGraduationHandlerV3, ISwapAdapterV3} from "./InterfacesV3.sol";
import {MemeTokenV3} from "./MemeTokenV3.sol";
import {FeeVaultV3} from "./FeeVaultV3.sol";
import {BondingCurveV3} from "./BondingCurveV3.sol";

/// Stateless deployers keep LaunchpadV3 under the EIP-170 size limit. The caller becomes the
/// `launchpad` authority of what it deploys; deploying through them directly yields an orphan.
contract FeeVaultDeployerV3 {
    function deploy(
        MemeTokenV3 token,
        address quote,
        address payable creator,
        ISwapAdapterV3 adapter,
        FeeVaultV3.Split calldata split,
        address[] calldata basketTokens,
        uint16[] calldata basketWeights
    ) external returns (FeeVaultV3) {
        return new FeeVaultV3(token, quote, creator, msg.sender, adapter, split, basketTokens, basketWeights);
    }
}

contract CurveDeployerV3 {
    function deploy(
        MemeTokenV3 token,
        address quote,
        address payable creator,
        address treasury,
        FeeVaultV3 vault,
        IGraduationHandlerV3 gradHandler,
        BondingCurveV3.Config calldata config
    ) external returns (BondingCurveV3) {
        return new BondingCurveV3(token, quote, creator, treasury, msg.sender, vault, gradHandler, config);
    }
}
