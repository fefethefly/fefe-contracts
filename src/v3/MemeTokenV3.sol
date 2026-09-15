// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITaxSinkV3} from "./InterfacesV3.sol";

/**
 * @title MemeTokenV3
 * @notice Fixed-supply meme token with configurable buy/sell tax on AMM trades and a
 * multi-asset dividend tracker used to stream a stock basket to holders.
 *
 * Deployed with an empty constructor so its CREATE2 init code hash is constant: the
 * contract address can be mined client-side ("reserved CA") before name, symbol or
 * tax settings are final. `initialize` runs once, in the same transaction, by the deployer.
 *
 * Invariants: no owner, no pause, no blacklist. Taxes only apply when one side of a
 * transfer is a registered market (AMM pool). Exempt addresses (curve, vault, launchpad,
 * graduation handler) never pay tax. Markets and exempt addresses never earn dividends.
 */
contract MemeTokenV3 is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ALREADY_INITIALIZED();
    error NOT_AUTHORIZED();
    error TAX_TOO_HIGH();
    error TOO_MANY_REWARDS();
    error UNKNOWN_REWARD();
    error NOTHING_TO_CLAIM();
    error REWARD_NOT_FUNDED();

    uint256 public constant FIXED_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MAX_TAX_BPS = 1_000; // 10%
    uint256 public constant MAX_REWARD_TOKENS = 8;
    // Reward amounts are < 1e30 and balances < 1e27, so pps * balance stays far below 2^256.
    uint256 private constant SCALE = 1e36;

    address public immutable deployer;
    string private _name;
    string private _symbol;
    bool public initialized;

    uint16 public buyTaxBps;
    uint16 public sellTaxBps;
    address public curve;
    ITaxSinkV3 public taxSink;

    mapping(address => bool) public isMarket;
    mapping(address => bool) public exempt;
    /// Excluded from dividends (markets, exempt, dead). Their balances leave the dividend supply.
    mapping(address => bool) public excluded;
    uint256 public excludedBalance;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public pointsPerShare; // reward => accumulated points
    mapping(address => uint256) public unallocated; // reward => amount waiting for dividend supply
    mapping(address => mapping(address => uint256)) private snapshot; // reward => account => pps snapshot
    mapping(address => mapping(address => uint256)) public owed; // reward => account => settled, unclaimed
    mapping(address => uint256) public totalDistributed; // reward => lifetime notified
    mapping(address => uint256) public totalClaimed; // reward => lifetime paid; dust stays reserved

    event Initialized(string name, string symbol, uint16 buyTaxBps, uint16 sellTaxBps);
    event MarketSet(address indexed market, bool enabled);
    event ExemptSet(address indexed account, bool enabled);
    event TaxCollected(address indexed from, address indexed to, uint256 amount, bool isBuy);
    event RewardNotified(address indexed reward, uint256 amount);
    event RewardClaimed(address indexed account, address indexed reward, uint256 amount);

    constructor() ERC20("", "") {
        deployer = msg.sender;
    }

    modifier onlyAuthority() {
        if (msg.sender != deployer && msg.sender != curve) revert NOT_AUTHORIZED();
        _;
    }

    /// One-shot setup by the deployer. Mints the fixed supply to `curve_`.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        address curve_,
        address taxSink_,
        address[] calldata rewardTokens_,
        address[] calldata exempt_
    ) external {
        if (msg.sender != deployer) revert NOT_AUTHORIZED();
        if (initialized) revert ALREADY_INITIALIZED();
        if (buyTaxBps_ > MAX_TAX_BPS || sellTaxBps_ > MAX_TAX_BPS) revert TAX_TOO_HIGH();
        if (rewardTokens_.length > MAX_REWARD_TOKENS) revert TOO_MANY_REWARDS();
        initialized = true;
        _name = name_;
        _symbol = symbol_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        curve = curve_;
        taxSink = ITaxSinkV3(taxSink_);
        for (uint256 i; i < rewardTokens_.length; ++i) {
            address r = rewardTokens_[i];
            if (r == address(0) || isRewardToken[r]) revert UNKNOWN_REWARD();
            isRewardToken[r] = true;
            rewardTokens.push(r);
        }
        _setExempt(deployer, true);
        _setExempt(curve_, true);
        _setExempt(taxSink_, true);
        _setExcluded(address(0xdead), true);
        for (uint256 i; i < exempt_.length; ++i) {
            _setExempt(exempt_[i], true);
        }
        _mint(curve_, FIXED_SUPPLY);
        emit Initialized(name_, symbol_, buyTaxBps_, sellTaxBps_);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    // ─── Roles (deployer during creation, curve at graduation) ──────────────────
    function setMarket(address market, bool enabled) external onlyAuthority {
        isMarket[market] = enabled;
        _setExcluded(market, enabled);
        emit MarketSet(market, enabled);
    }

    function setExempt(address account, bool enabled) external onlyAuthority {
        _setExempt(account, enabled);
    }

    function _setExempt(address account, bool enabled) internal {
        exempt[account] = enabled;
        _setExcluded(account, enabled);
        emit ExemptSet(account, enabled);
    }

    function _setExcluded(address account, bool enabled) internal {
        if (excluded[account] == enabled) return;
        _settle(account);
        excluded[account] = enabled;
        uint256 bal = balanceOf(account);
        if (enabled) excludedBalance += bal;
        else excludedBalance -= bal;
    }

    // ─── Dividends ─────────────────────────────────────────────────────────────
    function dividendSupply() public view returns (uint256) {
        return totalSupply() - excludedBalance;
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    /// Only the basket vault may allocate rewards, after transferring them here.
    /// Existing liabilities (including unallocated rewards and rounding dust) stay reserved.
    function notifyReward(address reward, uint256 amount) external nonReentrant {
        if (!isRewardToken[reward]) revert UNKNOWN_REWARD();
        if (msg.sender != address(taxSink)) revert NOT_AUTHORIZED();
        uint256 reserved = totalDistributed[reward] - totalClaimed[reward];
        uint256 held = IERC20(reward).balanceOf(address(this));
        if (held < reserved || amount > held - reserved) revert REWARD_NOT_FUNDED();
        uint256 total = amount + unallocated[reward];
        uint256 supply = dividendSupply();
        if (supply == 0) {
            unallocated[reward] = total;
        } else {
            unallocated[reward] = 0;
            pointsPerShare[reward] += (total * SCALE) / supply;
        }
        totalDistributed[reward] += amount;
        emit RewardNotified(reward, amount);
    }

    function pending(address account, address reward) public view returns (uint256) {
        uint256 accrued = owed[reward][account];
        if (!excluded[account]) {
            accrued += (balanceOf(account) * (pointsPerShare[reward] - snapshot[reward][account])) / SCALE;
        }
        return accrued;
    }

    /// Claims every reward token owed to the caller.
    function claimRewards() external nonReentrant returns (uint256 claimedCount) {
        _settle(msg.sender);
        for (uint256 i; i < rewardTokens.length; ++i) {
            address r = rewardTokens[i];
            uint256 amount = owed[r][msg.sender];
            if (amount == 0) continue;
            owed[r][msg.sender] = 0;
            totalClaimed[r] += amount;
            IERC20(r).safeTransfer(msg.sender, amount);
            emit RewardClaimed(msg.sender, r, amount);
            ++claimedCount;
        }
        if (claimedCount == 0) revert NOTHING_TO_CLAIM();
    }

    function _settle(address account) internal {
        if (account == address(0)) return;
        uint256 n = rewardTokens.length;
        if (n == 0) return;
        uint256 bal = balanceOf(account);
        bool skip = excluded[account];
        for (uint256 i; i < n; ++i) {
            address r = rewardTokens[i];
            uint256 pps = pointsPerShare[r];
            if (!skip) {
                uint256 delta = pps - snapshot[r][account];
                if (delta != 0 && bal != 0) owed[r][account] += (bal * delta) / SCALE;
            }
            snapshot[r][account] = pps;
        }
    }

    // ─── Transfers with tax ────────────────────────────────────────────────────
    function _update(address from, address to, uint256 value) internal override {
        _settle(from);
        _settle(to);
        uint256 tax;
        bool isBuy;
        if (value > 0 && from != to && !exempt[from] && !exempt[to]) {
            if (isMarket[from] && !isMarket[to]) {
                isBuy = true;
                tax = (value * buyTaxBps) / 10_000;
            } else if (isMarket[to] && !isMarket[from]) {
                tax = (value * sellTaxBps) / 10_000;
            }
        }
        if (tax > 0) {
            _move(from, address(taxSink), tax);
            _move(from, to, value - tax);
            emit TaxCollected(from, to, tax, isBuy);
            taxSink.onTax(tax);
            return;
        }
        _move(from, to, value);
    }

    function _move(address from, address to, uint256 value) internal {
        super._update(from, to, value);
        if (excluded[from]) excludedBalance -= value;
        if (excluded[to]) excludedBalance += value;
    }

    function burn(uint256 amount) external {
        _settle(msg.sender);
        _move(msg.sender, address(0), amount);
    }
}
