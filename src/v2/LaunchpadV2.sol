// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BarkToken} from "../BarkToken.sol";
import {CreatorTax} from "../routers/CreatorTax.sol";
import {StockVaultTax, IExchangeRouter} from "../routers/StockVaultTax.sol";
import {IGraduationHandler} from "../interfaces.sol";
import {BondingCurveV2} from "./BondingCurveV2.sol";

/**
 *  @notice Candidate unified launch path. Direct caller owns creator fees.
 * No forwarding factory changes msg.sender. Undeployed; external review required.
 */
contract LaunchpadV2 is ReentrancyGuard {
    error INVALID_CONFIG();
    error INVALID_NAME();
    error INVALID_TEMPLATE();
    error INVALID_TAX();
    error INVALID_STOCK_PARAMS();
    error EXPIRED();
    error FEE_REQUIRED();
    error INVALID_MIN_OUT();
    error TRANSFER_FAILED();
    uint256 public constant CREATION_FEE = 0.001 ether;
    address public immutable treasury;
    IGraduationHandler public immutable gradHandler;

    struct Launch {
        string name;
        string symbol;
        BarkToken.Template template;
        uint16 taxBps;
        address stockToken;
        address stockRecipient;
        address dex;
        uint256 minFirstBuyOut;
        uint256 deadline;
    }
    event Created(
        address indexed creator,
        address indexed token,
        address curve,
        address taxRouter,
        uint256 firstBuyWei,
        uint256 firstBuyTokens
    );

    constructor(address treasury_, IGraduationHandler gradHandler_) {
        if (treasury_ == address(0) || address(gradHandler_).code.length == 0) revert INVALID_CONFIG();
        treasury = treasury_;
        gradHandler = gradHandler_;
    }

    function create(Launch calldata plan)
        external
        payable
        nonReentrant
        returns (address token, address curve, address taxRouter)
    {
        if (block.timestamp > plan.deadline) revert EXPIRED();
        if (msg.value < CREATION_FEE) revert FEE_REQUIRED();
        if (
            bytes(plan.name).length == 0 || bytes(plan.name).length > 96 || bytes(plan.symbol).length < 2
                || bytes(plan.symbol).length > 8
        ) revert INVALID_NAME();
        // Holder distribution is intentionally excluded until its accounting is redesigned.
        if (plan.template == BarkToken.Template.Holder) revert INVALID_TEMPLATE();
        if (plan.taxBps > 300 || (plan.template == BarkToken.Template.None && plan.taxBps != 0)) revert INVALID_TAX();
        bool isStock = plan.template == BarkToken.Template.StockVault;
        if (isStock) {
            if (
                plan.stockToken.code.length == 0 || plan.dex.code.length == 0 || plan.stockRecipient == address(0)
                    || plan.stockRecipient == address(1)
            ) revert INVALID_STOCK_PARAMS();
        } else if (plan.stockToken != address(0) || plan.stockRecipient != address(0) || plan.dex != address(0)) {
            revert INVALID_STOCK_PARAMS();
        }
        uint256 firstBuy = msg.value - CREATION_FEE;
        if (firstBuy == 0 && plan.minFirstBuyOut != 0) revert INVALID_MIN_OUT();
        BarkToken t = new BarkToken(plan.name, plan.symbol, plan.template, plan.taxBps);
        if (plan.template == BarkToken.Template.Creator) {
            taxRouter = address(new CreatorTax(IERC20(address(t)), payable(msg.sender)));
        } else if (isStock) {
            taxRouter = address(
                new StockVaultTax(
                    IERC20(address(t)),
                    payable(msg.sender),
                    plan.stockToken,
                    plan.stockRecipient,
                    IExchangeRouter(plan.dex)
                )
            );
        }
        BondingCurveV2 c = new BondingCurveV2(IERC20(address(t)), payable(msg.sender), treasury, gradHandler);
        if (taxRouter != address(0)) ICurveBindingV2(taxRouter).setCurve(address(c));
        t.bind(taxRouter, address(c));
        if (!t.transfer(address(c), t.totalSupply())) revert TRANSFER_FAILED();
        uint256 out;
        if (firstBuy > 0) {
            out = c.buy{value: firstBuy}(plan.minFirstBuyOut);
            // Launchpad is the token deployer and is exempt: no second transfer tax on first buy.
            if (!t.transfer(msg.sender, out)) revert TRANSFER_FAILED();
        }
        (bool ok,) = treasury.call{value: CREATION_FEE}("");
        if (!ok) revert TRANSFER_FAILED();
        token = address(t);
        curve = address(c);
        emit Created(msg.sender, token, curve, taxRouter, firstBuy, out);
    }
}

interface ICurveBindingV2 {
    function setCurve(address curve) external;
}
