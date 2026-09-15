// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NATIVE} from "../src/v3/InterfacesV3.sol";
import {IPoolManager, IUnlockCallback, PoolKey, ModifyLiquidityParams, V4} from "../src/v3/uniswap/V4Types.sol";

interface ITestStockMint {
    function mint(address to, uint256 amount) external;
}

/**
 * @dev Batch 152: seed a hookless ETH/HOOD Uniswap v4 pool on testnet so Quoter/buyBasket work.
 * Mints TestStock HOOD, initializes PoolKey(fee=500, tickSpacing=10, hooks=0) at 1:1, full-range LP.
 *
 *   ETH_AMOUNT=0.0001ether HOOD_AMOUNT=0.0001ether \
 *   forge script script/SeedEthHoodV4.s.sol --rpc-url $RPC --sender $DEPLOYER \
 *     --evm-version cancun -vv
 *   # broadcast: --private-key $DEPLOYER_KEY --broadcast
 */
contract EthHoodV4Seeder is IUnlockCallback {
    using Math for uint256;

    error ONLY_POOL_MANAGER();
    error ONLY_OWNER();
    error BAD_AMOUNTS();
    error BAD_VALUE();
    error PRICE_OUT_OF_RANGE();

    uint256 private constant Q96 = 1 << 96;

    IPoolManager public immutable poolManager;
    address public immutable owner;

    event Seeded(bytes32 poolId, uint256 used0, uint256 used1, uint128 liq, uint160 sqrtPriceX96, bool initializedNow);

    constructor(IPoolManager pm) {
        poolManager = pm;
        owner = msg.sender;
    }

    function seed(PoolKey calldata key, uint256 a0, uint256 a1) external payable returns (bytes32 id, uint128 liq) {
        if (msg.sender != owner) revert ONLY_OWNER();
        if (key.currency0 != NATIVE || key.currency1 == NATIVE) revert BAD_AMOUNTS();
        if (a0 == 0 || a1 == 0) revert BAD_AMOUNTS();
        if (msg.value != a0) revert BAD_VALUE();
        if (IERC20(key.currency1).balanceOf(address(this)) < a1) revert BAD_AMOUNTS();

        (uint160 sqrtPriceX96, uint128 liq_) = _priceAndLiquidity(a0, a1);
        liq = liq_;
        id = V4.poolId(key);

        bool initializedNow = false;
        try poolManager.initialize(key, sqrtPriceX96) returns (int24) {
            initializedNow = true;
        } catch {
            // already initialized — still add liquidity at current price using same amounts
            initializedNow = false;
        }

        (uint256 used0, uint256 used1) =
            abi.decode(poolManager.unlock(abi.encode(key, liq, a0, a1)), (uint256, uint256));
        emit Seeded(id, used0, used1, liq, sqrtPriceX96, initializedNow);

        // refund dust to owner
        _sweep(NATIVE, address(this).balance);
        uint256 left1 = IERC20(key.currency1).balanceOf(address(this));
        if (left1 > 0) IERC20(key.currency1).transfer(owner, left1);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert ONLY_POOL_MANAGER();
        (PoolKey memory key, uint128 liq, uint256 a0, uint256 a1) =
            abi.decode(data, (PoolKey, uint128, uint256, uint256));
        ModifyLiquidityParams memory p = ModifyLiquidityParams(
            V4.minUsableTick(key.tickSpacing), V4.maxUsableTick(key.tickSpacing), int256(uint256(liq)), bytes32(0)
        );
        (int256 delta,) = poolManager.modifyLiquidity(key, p, "");
        int128 d0 = V4.amount0(delta);
        int128 d1 = V4.amount1(delta);
        if (d0 > 0 || d1 > 0 || uint128(-d0) > a0 || uint128(-d1) > a1) revert BAD_AMOUNTS();
        _pay(key.currency0, uint128(-d0));
        _pay(key.currency1, uint128(-d1));
        return abi.encode(uint256(uint128(-d0)), uint256(uint128(-d1)));
    }

    function _priceAndLiquidity(uint256 a0, uint256 a1) internal pure returns (uint160 sqrtPriceX96, uint128 liq) {
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
        if (sqrtPriceX96 <= V4.MIN_SQRT_PRICE || sqrtPriceX96 >= V4.MAX_SQRT_PRICE) revert PRICE_OUT_OF_RANGE();
        uint256 l = Math.min(Math.mulDiv(a0, sqrtPriceX96, Q96), Math.mulDiv(a1, Q96, sqrtPriceX96));
        l -= l / 1_000_000 + 1;
        if (l == 0 || l > type(uint128).max) revert BAD_AMOUNTS();
        liq = uint128(l);
    }

    function _pay(address currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == NATIVE) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            require(IERC20(currency).transfer(address(poolManager), amount), "xfer");
            poolManager.settle();
        }
    }

    function _sweep(address currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == NATIVE) {
            (bool ok,) = payable(owner).call{value: amount}("");
            require(ok, "eth");
        }
    }

    receive() external payable {}
}

contract SeedEthHoodV4 is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOOD = 0x972e99afe1E677b7dB0B00a3C207170784f485d6;
    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;

    function run() external {
        uint256 ethAmount = vm.envOr("ETH_AMOUNT", uint256(0.0001 ether));
        uint256 hoodAmount = vm.envOr("HOOD_AMOUNT", uint256(0.0001 ether));

        PoolKey memory key = PoolKey(NATIVE, HOOD, FEE, TICK_SPACING, address(0));
        bytes32 expectedId = V4.poolId(key);
        console2.log("PoolManager", POOL_MANAGER);
        console2.log("HOOD", HOOD);
        console2.logBytes32(expectedId);
        console2.log("ethAmount", ethAmount);
        console2.log("hoodAmount", hoodAmount);

        vm.startBroadcast();
        EthHoodV4Seeder seeder = new EthHoodV4Seeder(IPoolManager(POOL_MANAGER));
        ITestStockMint(HOOD).mint(address(seeder), hoodAmount);
        (bytes32 id, uint128 liq) = seeder.seed{value: ethAmount}(key, ethAmount, hoodAmount);
        vm.stopBroadcast();

        console2.log("seeder", address(seeder));
        console2.logBytes32(id);
        console2.log("liquidity", uint256(liq));
    }
}
