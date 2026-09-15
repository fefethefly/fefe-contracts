// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommoditySwapAdapterV3, ICommodityV3Factory} from "../src/v3/uniswap/CommoditySwapAdapterV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";

import {CommodityOracleGuardV3, ICommodityPriceFeedV3} from "../src/v3/uniswap/CommodityOracleGuardV3.sol";

contract CommodityTestToken is ERC20 {
    bytes32 public assetId;

    function setAssetId(bytes32 id) external {
        assetId = id;
    }
    uint8 private immutable precision;
    bool public taxed;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        precision = d;
        assetId = keccak256(bytes(n));
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(bool value) external {
        taxed = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxed && from != address(0) && to != address(0) && value > 1) {
            super._update(from, address(0), value / 100);
            value -= value / 100;
        }
        super._update(from, to, value);
    }
}

contract CommodityTestFactory {
    mapping(bytes32 => address) private pools;

    function key(address a, address b, uint24 fee) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b, fee)) : keccak256(abi.encode(b, a, fee));
    }

    function setPool(address a, address b, address pool) external {
        pools[key(a, b, 500)] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[key(a, b, fee)];
    }
}

contract CommodityTestPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    uint24 public constant fee = 500;
    uint8 public mode;
    bool public reentryBlocked;

    constructor(address a, address b, address f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        factory = f;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function _reenter(bool direction, address recipient) private {
        try CommoditySwapAdapterV3(msg.sender)
            .swapExactIn(direction ? token0 : token1, direction ? token1 : token0, 1, 1, recipient) {
            reentryBlocked = false;
        } catch {
            reentryBlocked = true;
        }
    }

    function swap(address recipient, bool zeroForOne, int256 amount, uint160, bytes calldata)
        external
        returns (int256 d0, int256 d1)
    {
        require(mode != 1, "second hop failed");
        address input = zeroForOne ? token0 : token1;
        address output = zeroForOne ? token1 : token0;
        uint256 spent = uint256(amount);
        if (mode == 2) spent--;
        uint256 out = spent * 10 ** CommodityTestToken(output).decimals() / 10 ** CommodityTestToken(input).decimals();
        // Test-only adverse venue pricing while source health remains unchanged.
        if (mode == 7) out /= 100;
        if (mode != 3) CommodityTestToken(output).transfer(recipient, out);
        (d0, d1) = zeroForOne ? (int256(spent), -int256(out)) : (-int256(out), int256(spent));
        if (mode == 4) return (d0, d1);
        if (mode == 5) _reenter(zeroForOne, recipient);
        CommoditySwapAdapterV3(msg.sender).uniswapV3SwapCallback(d0, d1, "");
        if (mode == 6) CommoditySwapAdapterV3(msg.sender).uniswapV3SwapCallback(d0, d1, "");
    }
}

contract CommodityTestFeed is ICommodityPriceFeedV3 {
    bool public paused;
    bool public fail;
    bool public mismatch;
    mapping(bytes32 => Config) public configs;
    mapping(bytes32 => Observation) public observations;

    function setPaused(bool value) external {
        paused = value;
    }

    function setFail(bool value) external {
        fail = value;
    }

    function setMismatch(bool value) external {
        mismatch = value;
    }

    function set(bytes32 id, Config memory c, Observation memory o) external {
        configs[id] = c;
        observations[id] = o;
    }

    function assetConfig(bytes32 id) external view returns (Config memory) {
        require(!fail, "feed unavailable");
        return configs[id];
    }

    function latest(bytes32 id) external view returns (Observation memory) {
        return observations[id];
    }

    function price(bytes32 id) external view returns (uint256, uint64) {
        require(!fail, "feed unavailable");
        Observation memory o = observations[id];
        return (o.priceWad + (mismatch ? 1 : 0), o.observedAt);
    }
}

abstract contract CommodityAdapterFixture is Test {
    CommodityTestToken corn;
    CommodityTestToken coffee;
    CommodityTestToken usdg;
    CommodityTestFactory factory;
    CommodityTestPool cornPool;
    CommodityTestPool coffeePool;
    CommoditySwapAdapterV3 adapter;
    CommodityOracleGuardV3 guard;
    CommodityTestFeed feed;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function config() internal view returns (address[] memory assets, address[] memory pools) {
        assets = new address[](2);
        pools = new address[](2);
        assets[0] = address(corn);
        assets[1] = address(coffee);
        pools[0] = address(cornPool);
        pools[1] = address(coffeePool);
    }

    function setUp() public virtual {
        vm.warp(100000);
        corn = new CommodityTestToken("ZC", 18);
        coffee = new CommodityTestToken("KC", 18);
        usdg = new CommodityTestToken("USDG", 6);
        factory = new CommodityTestFactory();
        cornPool = new CommodityTestPool(address(corn), address(usdg), address(factory));
        coffeePool = new CommodityTestPool(address(coffee), address(usdg), address(factory));
        factory.setPool(address(corn), address(usdg), address(cornPool));
        factory.setPool(address(coffee), address(usdg), address(coffeePool));
        (address[] memory assets, address[] memory pools) = config();
        feed = new CommodityTestFeed();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = corn.assetId();
        ids[1] = coffee.assetId();
        guard = new CommodityOracleGuardV3(block.chainid, feed, 600, 600, assets, ids);
        refreshFeed();
        adapter = new CommoditySwapAdapterV3(
            block.chainid, ICommodityV3Factory(address(factory)), address(usdg), 500, assets, pools, guard
        );
        corn.mint(alice, 100 ether);
        coffee.mint(alice, 100 ether);
        usdg.mint(alice, 100e6);
        corn.mint(address(cornPool), 1_000_000 ether);
        usdg.mint(address(cornPool), 1_000_000e6);
        coffee.mint(address(coffeePool), 1_000_000 ether);
        usdg.mint(address(coffeePool), 1_000_000e6);
        vm.startPrank(alice);
        corn.approve(address(adapter), type(uint256).max);
        coffee.approve(address(adapter), type(uint256).max);
        usdg.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function refreshFeed() internal {
        ICommodityPriceFeedV3.Config memory c = ICommodityPriceFeedV3.Config(true, false, 300, 1, 100 ether);
        ICommodityPriceFeedV3.Observation memory o =
            ICommodityPriceFeedV3.Observation(1 ether, uint64(block.timestamp - 10), uint64(block.timestamp - 5));
        feed.set(corn.assetId(), c, o);
        feed.set(coffee.assetId(), c, o);
    }

    function swap(uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.prank(alice);
        return adapter.swapExactIn(address(corn), address(coffee), amount, minOut, bob);
    }

    function vaultSetup() internal returns (MemeTokenV3 token, FeeVaultV3 vault) {
        token = new MemeTokenV3();
        address[] memory rewards = new address[](1);
        rewards[0] = address(coffee);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        vault = new FeeVaultV3(
            token,
            address(corn),
            payable(address(this)),
            address(this),
            adapter,
            FeeVaultV3.Split(0, 10000, 0, 0),
            rewards,
            weights
        );
        vault.setCurve(address(this));
        token.initialize("LUMOB", "LUM", 0, 0, address(this), address(vault), rewards, new address[](0));
        token.transfer(alice, 100 ether);
        token.transfer(bob, 100 ether);
        corn.mint(address(vault), 10 ether);
        vault.onFee(10 ether);
    }
}

contract CommoditySwapAdapterV3Test is CommodityAdapterFixture {
    function test_twoHopPreservesDustAndPaysActualRecipient() public {
        corn.mint(address(adapter), 7);
        usdg.mint(address(adapter), 9);
        coffee.mint(address(adapter), 11);
        assertEq(swap(10 ether, 10 ether), 10 ether);
        assertEq(coffee.balanceOf(bob), 10 ether);
        assertEq(corn.balanceOf(alice), 90 ether);
        assertEq(corn.balanceOf(address(adapter)), 7);
        assertEq(usdg.balanceOf(address(adapter)), 9);
        assertEq(coffee.balanceOf(address(adapter)), 11);
        assertEq(corn.allowance(address(adapter), address(cornPool)), 0);
    }

    function test_directBridgeBothDirectionsAndReverseTwoHop() public {
        vm.startPrank(alice);
        assertEq(adapter.swapExactIn(address(usdg), address(corn), 2e6, 2 ether, bob), 2 ether);
        assertEq(adapter.swapExactIn(address(corn), address(usdg), 3 ether, 3e6, bob), 3e6);
        assertEq(adapter.swapExactIn(address(coffee), address(corn), 4 ether, 4 ether, bob), 4 ether);
        vm.stopPrank();
        assertEq(corn.balanceOf(bob), 6 ether);
        assertEq(usdg.balanceOf(bob), 3e6);
    }

    function test_secondHopFailureRollsBackFirstPoolAndCaller() public {
        coffeePool.setMode(1);
        uint256 pc = corn.balanceOf(address(cornPool));
        uint256 pu = usdg.balanceOf(address(cornPool));
        vm.expectRevert("second hop failed");
        swap(10 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(corn.balanceOf(address(cornPool)), pc);
        assertEq(usdg.balanceOf(address(cornPool)), pu);
        assertEq(coffee.balanceOf(bob), 0);
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    function test_slippageRollsBackBothPools() public {
        vm.expectRevert(CommoditySwapAdapterV3.SLIPPAGE.selector);
        swap(10 ether, 11 ether);
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(coffee.balanceOf(bob), 0);
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    function test_partialFillCannotSpendAdapterDust() public {
        corn.mint(address(adapter), 1 ether);
        cornPool.setMode(2);
        vm.expectRevert(CommoditySwapAdapterV3.PARTIAL_FILL.selector);
        swap(10 ether, 1);
        assertEq(corn.balanceOf(address(adapter)), 1 ether);
        assertEq(corn.balanceOf(alice), 100 ether);
    }

    function test_falseOutputOrMissingCallbackReverts() public {
        for (uint8 mode = 3; mode <= 4; mode++) {
            coffeePool.setMode(mode);
            vm.expectRevert();
            swap(10 ether, 1);
            assertEq(corn.balanceOf(alice), 100 ether);
            assertEq(coffee.balanceOf(bob), 0);
        }
    }

    function test_forgedAndRepeatedCallbacksCannotWithdraw() public {
        corn.mint(address(adapter), 1 ether);
        vm.expectRevert(CommoditySwapAdapterV3.BAD_CALLBACK.selector);
        adapter.uniswapV3SwapCallback(1, -1, "");
        vm.prank(address(cornPool));
        vm.expectRevert(CommoditySwapAdapterV3.BAD_CALLBACK.selector);
        adapter.uniswapV3SwapCallback(1, -1, "");
        cornPool.setMode(6);
        vm.expectRevert(CommoditySwapAdapterV3.BAD_CALLBACK.selector);
        swap(1 ether, 1);
        assertEq(corn.balanceOf(address(adapter)), 1 ether);
    }

    function test_poolCannotReenterSwap() public {
        cornPool.setMode(5);
        swap(1 ether, 1);
        assertTrue(cornPool.reentryBlocked());
    }

    function test_taxedInputOrOutputFailsWithoutCreatingLoss() public {
        corn.setTax(true);
        vm.expectRevert(CommoditySwapAdapterV3.TRANSFER_MISMATCH.selector);
        swap(10 ether, 1);
        corn.setTax(false);
        coffee.setTax(true);
        vm.expectRevert(CommoditySwapAdapterV3.TRANSFER_MISMATCH.selector);
        swap(10 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
        assertEq(coffee.balanceOf(bob), 0);
    }

    function test_changedFactoryMappingAndWrongChainStopBeforeFunding() public {
        factory.setPool(address(coffee), address(usdg), address(cornPool));
        vm.expectRevert(CommoditySwapAdapterV3.BAD_ROUTE.selector);
        swap(1 ether, 1);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(CommoditySwapAdapterV3.WRONG_CHAIN.selector);
        swap(1 ether, 1);
        assertEq(corn.balanceOf(alice), 100 ether);
    }

    function test_unknownNativeSameAssetAndZeroProtectionRejected() public {
        assertFalse(adapter.hasRoute(address(0), address(coffee)));
        assertFalse(adapter.hasRoute(address(corn), address(corn)));
        assertFalse(adapter.hasRoute(address(123), address(coffee)));
        vm.expectRevert(CommoditySwapAdapterV3.BAD_ROUTE.selector);
        adapter.swapExactIn(address(123), address(coffee), 1, 1, bob);
        vm.expectRevert(CommoditySwapAdapterV3.BAD_VALUE.selector);
        swap(1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(CommoditySwapAdapterV3.BAD_VALUE.selector);
        adapter.swapExactIn(address(corn), address(coffee), 1, 1, address(adapter));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(CommoditySwapAdapterV3.BAD_VALUE.selector);
        adapter.swapExactIn{value: 1}(address(corn), address(coffee), 1, 1, bob);
    }

    function test_constructorRejectsWrongIdentityAndDuplicateAssets() public {
        (address[] memory assets, address[] memory pools) = config();
        vm.expectRevert(CommoditySwapAdapterV3.WRONG_CHAIN.selector);
        new CommoditySwapAdapterV3(
            block.chainid + 1, ICommodityV3Factory(address(factory)), address(usdg), 500, assets, pools, guard
        );
        pools[1] = address(cornPool);
        vm.expectRevert(CommoditySwapAdapterV3.BAD_CONFIG.selector);
        new CommoditySwapAdapterV3(
            block.chainid, ICommodityV3Factory(address(factory)), address(usdg), 500, assets, pools, guard
        );
        assets[1] = assets[0];
        vm.expectRevert(CommoditySwapAdapterV3.BAD_CONFIG.selector);
        new CommoditySwapAdapterV3(
            block.chainid, ICommodityV3Factory(address(factory)), address(usdg), 500, assets, pools, guard
        );
    }

    function testFuzz_twoHopConservesRawUnits(uint64 raw) public {
        uint256 amount = bound(uint256(raw), 1, 100e6) * 1e12;
        assertEq(swap(amount, amount), amount);
        assertEq(corn.balanceOf(alice) + coffee.balanceOf(bob), 100 ether);
        assertEq(corn.balanceOf(address(adapter)), 0);
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    function test_vaultConversionFundsActualHolderClaims() public {
        (MemeTokenV3 token, FeeVaultV3 vault) = vaultSetup();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 10 ether;
        vault.buyBasket(mins);
        assertEq(vault.basketPending(), 0);
        assertEq(token.totalDistributed(address(coffee)), 10 ether);
        assertEq(token.pending(alice, address(coffee)), 5 ether);
        assertEq(token.pending(bob, address(coffee)), 5 ether);
        uint256 beforeAlice = coffee.balanceOf(alice);
        vm.prank(alice);
        token.claimRewards();
        vm.prank(bob);
        token.claimRewards();
        assertEq(coffee.balanceOf(alice) - beforeAlice, 5 ether);
        assertEq(coffee.balanceOf(bob), 5 ether);
        assertEq(token.totalClaimed(address(coffee)), 10 ether);
        assertEq(coffee.balanceOf(address(token)), 0);
    }

    function test_failedConversionKeepsPendingAndAllowsExactlyOneRetry() public {
        (MemeTokenV3 token, FeeVaultV3 vault) = vaultSetup();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 10 ether;
        coffeePool.setMode(1);
        vm.expectRevert("second hop failed");
        vault.buyBasket(mins);
        assertEq(vault.basketPending(), 10 ether);
        assertEq(corn.balanceOf(address(vault)), 10 ether);
        assertEq(token.totalDistributed(address(coffee)), 0);
        coffeePool.setMode(0);
        vault.buyBasket(mins);
        assertEq(token.totalDistributed(address(coffee)), 10 ether);
        vm.expectRevert(FeeVaultV3.NOTHING_PENDING.selector);
        vault.buyBasket(mins);
    }
}
