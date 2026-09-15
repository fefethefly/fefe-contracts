// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGraduationHandlerV3, ISwapAdapterV3, NATIVE} from "./InterfacesV3.sol";
import {MemeTokenV3} from "./MemeTokenV3.sol";
import {FeeVaultV3} from "./FeeVaultV3.sol";
import {BondingCurveV3} from "./BondingCurveV3.sol";
import {FeeVaultDeployerV3, CurveDeployerV3} from "./DeployersV3.sol";

/**
 * @title LaunchpadV3
 * @notice One transaction: token (CREATE2, sender-bound salt) + fee vault + bonding curve,
 * plus an optional tax-free creator first buy. Quote asset may be ETH or any tokenized stock.
 *
 * Reserved contract addresses: the token init code is constant, and the effective salt is
 * keccak256(creator, salt). A creator can therefore mine a vanity address off-chain with
 * `predictToken` and nobody else can ever deploy to it. No fee, no expiry, no registry.
 */
contract LaunchpadV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error INVALID_CONFIG();
    error INVALID_NAME();
    error INVALID_TAX();
    error INVALID_SPLIT();
    error INVALID_BASKET();
    error INVALID_QUOTE();
    error INVALID_CURVE();
    error INVALID_ANTI_SNIPE();
    error INVALID_JACKPOT();
    error EXPIRED();
    error FEE_REQUIRED();
    error BAD_VALUE();
    error TRANSFER_FAILED();

    uint256 public constant CREATION_FEE = 0.0005 ether;
    uint256 public constant MAX_TAX_BPS = 1_000;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100;
    uint256 public constant MAX_ANTI_SNIPE_SECONDS = 3_600;
    uint256 public constant MAX_ANTI_SNIPE_TAX_BPS = 5_000;
    uint256 public constant MAX_JACKPOT_EVERY_N = 10_000;

    address public immutable treasury;
    IGraduationHandlerV3 public immutable gradHandler;
    ISwapAdapterV3 public immutable adapter;
    FeeVaultDeployerV3 public immutable vaultDeployer;
    CurveDeployerV3 public immutable curveDeployer;
    bytes32 public immutable TOKEN_INIT_CODE_HASH;

    struct Launch {
        string name;
        string symbol;
        address quoteAsset; // address(0) = ETH, else ERC20 (tokenized stock)
        uint128 virtualQuote;
        uint128 graduationQuote;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 protocolFeeBps; // community 20 → FefeSink; official 0
        FeeVaultV3.Split split;
        address[] basketTokens;
        uint16[] basketWeights;
        uint32 antiSnipeSeconds;
        uint16 antiSnipeMaxWalletBps;
        uint16 antiSnipeTaxBps;
        uint16 jackpotEveryN;
        uint96 jackpotMinBuy;
        bytes32 salt;
        uint256 firstBuyQuote;
        uint256 minFirstBuyOut;
        uint256 deadline;
    }

    struct Deployment {
        address token;
        address curve;
        address vault;
        address creator;
        address quoteAsset;
        uint64 createdAt;
    }

    mapping(address => Deployment) public deployments; // token => deployment
    address[] public tokens;

    event Created(
        address indexed creator,
        address indexed token,
        address curve,
        address vault,
        address quoteAsset,
        bytes32 salt,
        uint256 firstBuyQuote,
        uint256 firstBuyTokens
    );

    constructor(address treasury_, IGraduationHandlerV3 gradHandler_, ISwapAdapterV3 adapter_) {
        if (treasury_ == address(0) || address(gradHandler_).code.length == 0 || address(adapter_).code.length == 0) {
            revert INVALID_CONFIG();
        }
        treasury = treasury_;
        gradHandler = gradHandler_;
        adapter = adapter_;
        vaultDeployer = new FeeVaultDeployerV3();
        curveDeployer = new CurveDeployerV3();
        TOKEN_INIT_CODE_HASH = keccak256(type(MemeTokenV3).creationCode);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function effectiveSalt(address creator, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator, salt));
    }

    /// Address the token will get for (creator, salt). Independent of name, symbol and settings.
    function predictToken(address creator, bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), effectiveSalt(creator, salt), TOKEN_INIT_CODE_HASH))
                )
            )
        );
    }

    function create(Launch calldata p)
        external
        payable
        nonReentrant
        returns (address token, address curve, address vault)
    {
        _validate(p);
        if (p.quoteAsset == NATIVE) {
            if (msg.value != CREATION_FEE + p.firstBuyQuote) revert BAD_VALUE();
        } else if (msg.value != CREATION_FEE) {
            revert BAD_VALUE();
        }

        (token, curve, vault) = _deploy(p);
        uint256 out = _firstBuy(p, curve);

        (bool ok,) = treasury.call{value: CREATION_FEE}("");
        if (!ok) revert TRANSFER_FAILED();

        deployments[token] = Deployment(token, curve, vault, msg.sender, p.quoteAsset, uint64(block.timestamp));
        tokens.push(token);
        emit Created(msg.sender, token, curve, vault, p.quoteAsset, p.salt, p.firstBuyQuote, out);
    }

    function _deploy(Launch calldata p) internal returns (address token, address curve, address vault) {
        MemeTokenV3 t = new MemeTokenV3{salt: effectiveSalt(msg.sender, p.salt)}();
        FeeVaultV3 v = vaultDeployer.deploy(
            t, p.quoteAsset, payable(msg.sender), adapter, p.split, p.basketTokens, p.basketWeights
        );
        BondingCurveV3 c =
            curveDeployer.deploy(t, p.quoteAsset, payable(msg.sender), treasury, v, gradHandler, _config(p));
        _initToken(t, p, address(c), address(v));
        v.setCurve(address(c));
        return (address(t), address(c), address(v));
    }

    function _config(Launch calldata p) internal pure returns (BondingCurveV3.Config memory) {
        return BondingCurveV3.Config({
            virtualQuote: p.virtualQuote,
            graduationQuote: p.graduationQuote,
            buyTaxBps: p.buyTaxBps,
            sellTaxBps: p.sellTaxBps,
            antiSnipeSeconds: p.antiSnipeSeconds,
            antiSnipeMaxWalletBps: p.antiSnipeMaxWalletBps,
            antiSnipeTaxBps: p.antiSnipeTaxBps,
            jackpotEveryN: p.jackpotEveryN,
            jackpotMinBuy: p.jackpotMinBuy,
            protocolFeeBps: p.protocolFeeBps
        });
    }

    function _initToken(MemeTokenV3 t, Launch calldata p, address curve, address vault) internal {
        address[] memory extraExempt = new address[](1);
        extraExempt[0] = address(gradHandler);
        t.initialize(p.name, p.symbol, p.buyTaxBps, p.sellTaxBps, curve, vault, p.basketTokens, extraExempt);
    }

    function _firstBuy(Launch calldata p, address curve) internal returns (uint256 out) {
        uint256 firstBuy = p.firstBuyQuote;
        if (p.quoteAsset == NATIVE) {
            return BondingCurveV3(payable(curve)).open{value: firstBuy}(firstBuy, p.minFirstBuyOut, msg.sender);
        }
        if (firstBuy > 0) {
            IERC20(p.quoteAsset).safeTransferFrom(msg.sender, address(this), firstBuy);
            IERC20(p.quoteAsset).forceApprove(curve, firstBuy);
        }
        return BondingCurveV3(payable(curve)).open(firstBuy, p.minFirstBuyOut, msg.sender);
    }

    function _validate(Launch calldata p) internal view virtual {
        if (block.timestamp > p.deadline) revert EXPIRED();
        if (msg.value < CREATION_FEE) revert FEE_REQUIRED();
        uint256 nameLen = bytes(p.name).length;
        uint256 symLen = bytes(p.symbol).length;
        if (nameLen == 0 || nameLen > 96 || symLen < 2 || symLen > 8) revert INVALID_NAME();
        if (p.quoteAsset != NATIVE && p.quoteAsset.code.length == 0) revert INVALID_QUOTE();
        if (p.virtualQuote == 0 || p.graduationQuote == 0) revert INVALID_CURVE();
        if (p.buyTaxBps > MAX_TAX_BPS || p.sellTaxBps > MAX_TAX_BPS || p.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) {
            revert INVALID_TAX();
        }
        if (uint256(p.buyTaxBps) + p.protocolFeeBps > MAX_TAX_BPS || uint256(p.sellTaxBps) + p.protocolFeeBps > MAX_TAX_BPS)
        {
            revert INVALID_TAX();
        }
        if (uint256(p.split.creatorBps) + p.split.basketBps + p.split.jackpotBps + p.split.burnBps != 10_000) {
            revert INVALID_SPLIT();
        }
        if (p.basketTokens.length != p.basketWeights.length || p.basketTokens.length > 8) revert INVALID_BASKET();
        if (p.split.basketBps > 0 && p.basketTokens.length == 0) revert INVALID_BASKET();
        if (p.antiSnipeSeconds > MAX_ANTI_SNIPE_SECONDS || p.antiSnipeTaxBps > MAX_ANTI_SNIPE_TAX_BPS) {
            revert INVALID_ANTI_SNIPE();
        }
        if (p.antiSnipeSeconds == 0 && (p.antiSnipeTaxBps != 0 || p.antiSnipeMaxWalletBps != 0)) revert INVALID_ANTI_SNIPE();
        if (p.antiSnipeMaxWalletBps > 10_000) revert INVALID_ANTI_SNIPE();
        if (p.jackpotEveryN == 1 || p.jackpotEveryN > MAX_JACKPOT_EVERY_N) revert INVALID_JACKPOT();
        if (p.jackpotEveryN == 0 && p.split.jackpotBps != 0) revert INVALID_JACKPOT();
        if (p.firstBuyQuote == 0 && p.minFirstBuyOut != 0) revert INVALID_CURVE();
    }
}
