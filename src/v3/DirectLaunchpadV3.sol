// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDirectLaunchHandlerV3, ISwapAdapterV3, NATIVE} from "./InterfacesV3.sol";
import {MemeTokenV3} from "./MemeTokenV3.sol";
import {FeeVaultV3} from "./FeeVaultV3.sol";
import {FeeVaultDeployerV3} from "./DeployersV3.sol";

/**
 * @title DirectLaunchpadV3
 * @notice openlaunch-style launch: one transaction creates the token (100% supply minted to the
 * graduation handler), the fee vault, and a Uniswap v4 pool locked forever at the virtual-quote
 * price. No creation fee, no protocol share, no LP fee — the creator pays only gas.
 *
 * Unlike LaunchpadV3 there is no bonding curve: the pool itself is the price curve. The creator's
 * buy/sell tax (optional, can be 0) is charged by BarkHookV3 and split by FeeVaultV3 into
 * creator / basket dividends / buyback-burn. Anti-snipe and Nth-buy jackpot are not available in
 * this mode (they are curve mechanics), so jackpotBps must be 0.
 *
 * Standalone (does not extend LaunchpadV3) to stay well under the EIP-170 size limit while
 * reusing the exact MemeTokenV3 creation-code hash for client-side address mining.
 */
contract DirectLaunchpadV3 is ReentrancyGuard {
    error INVALID_CONFIG();
    error INVALID_NAME();
    error INVALID_QUOTE();
    error INVALID_CURVE();
    error INVALID_TAX();
    error INVALID_SPLIT();
    error INVALID_BASKET();
    error EXPIRED();
    error DIRECT_JACKPOT_UNSUPPORTED();

    uint256 public constant MAX_TAX_BPS = 1_000;

    IDirectLaunchHandlerV3 public immutable directHandler;
    ISwapAdapterV3 public immutable adapter;
    FeeVaultDeployerV3 public immutable vaultDeployer;
    bytes32 public immutable TOKEN_INIT_CODE_HASH;

    struct DirectLaunch {
        string name;
        string symbol;
        address quoteAsset; // address(0) = ETH, else ERC20 (tokenized stock)
        uint256 virtualQuote; // launch price bias in quote units (1e18 scaled)
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        FeeVaultV3.Split split;
        address[] basketTokens;
        uint16[] basketWeights;
        bytes32 salt;
        uint256 deadline;
    }

    struct Deployment {
        address token;
        address curve; // always address(0) in direct mode
        address vault;
        address creator;
        address quoteAsset;
        uint64 createdAt;
    }

    mapping(address => Deployment) public deployments; // token => deployment
    address[] public tokens;

    event Created(
        address indexed creator, address indexed token, address vault, address pool, address quoteAsset, bytes32 salt
    );

    constructor(IDirectLaunchHandlerV3 directHandler_, ISwapAdapterV3 adapter_) {
        if (address(directHandler_).code.length == 0 || address(adapter_).code.length == 0) revert INVALID_CONFIG();
        directHandler = directHandler_;
        adapter = adapter_;
        vaultDeployer = new FeeVaultDeployerV3();
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

    function create(DirectLaunch calldata p) external nonReentrant returns (address token, address vault, address pool) {
        _validate(p);

        MemeTokenV3 t = new MemeTokenV3{salt: effectiveSalt(msg.sender, p.salt)}();
        token = address(t);
        FeeVaultV3 v = vaultDeployer.deploy(t, p.quoteAsset, payable(msg.sender), adapter, p.split, p.basketTokens, p.basketWeights);
        vault = address(v);
        v.setCurve(address(directHandler));
        _initToken(t, p, vault);

        pool = directHandler.launchDirect(token, p.quoteAsset, p.virtualQuote, vault);

        deployments[token] = Deployment(token, address(0), vault, msg.sender, p.quoteAsset, uint64(block.timestamp));
        tokens.push(token);
        emit Created(msg.sender, token, vault, pool, p.quoteAsset, p.salt);
    }

    /// Mints the whole supply to the handler and sets it as the token's `curve` authority.
    function _initToken(MemeTokenV3 t, DirectLaunch calldata p, address vault) internal {
        address[] memory exempt = new address[](0);
        t.initialize(p.name, p.symbol, p.buyTaxBps, p.sellTaxBps, address(directHandler), vault, p.basketTokens, exempt);
    }

    function _validate(DirectLaunch calldata p) internal view {
        if (block.timestamp > p.deadline) revert EXPIRED();
        uint256 nameLen = bytes(p.name).length;
        uint256 symLen = bytes(p.symbol).length;
        if (nameLen == 0 || nameLen > 96 || symLen < 2 || symLen > 8) revert INVALID_NAME();
        if (p.quoteAsset != NATIVE && p.quoteAsset.code.length == 0) revert INVALID_QUOTE();
        if (p.virtualQuote == 0) revert INVALID_CURVE();
        if (p.buyTaxBps > MAX_TAX_BPS || p.sellTaxBps > MAX_TAX_BPS) revert INVALID_TAX();
        if (uint256(p.split.creatorBps) + p.split.basketBps + p.split.jackpotBps + p.split.burnBps != 10_000) {
            revert INVALID_SPLIT();
        }
        // No curve exists to trigger Nth-buy jackpot payouts in direct mode.
        if (p.split.jackpotBps != 0) revert DIRECT_JACKPOT_UNSUPPORTED();
        if (p.basketTokens.length != p.basketWeights.length || p.basketTokens.length > 8) revert INVALID_BASKET();
        if (p.split.basketBps > 0 && p.basketTokens.length == 0) revert INVALID_BASKET();
    }
}
