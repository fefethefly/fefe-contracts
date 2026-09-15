// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InstantLaunchGateway, InstantCommunityToken} from "../src/candidates/InstantLaunchGateway.sol";

// Test-only ABI subset of Uniswap/liquidity-launcher dd8769cd45c0e9450e928513ee129b0af74f7f32.
// These fixtures run exclusively in Forge's local fork. They are not deployable product entry points.
struct ForkDistribution {
    address strategy;
    uint128 amount;
    bytes configData;
}

struct ForkPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ForkFeeSplit {
    address recipient;
    uint16 nativeBps;
    uint16 tokenBps;
    bool useCallback;
}

struct ForkSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IForkPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(ForkPoolKey calldata key, ForkSwapParams calldata params, bytes calldata hookData)
        external
        returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IForkBeneficiaryVault {
    function amounts(uint256 id) external view returns (uint128 currency0Amount, uint128 currency1Amount);
    function claim(uint256 id, uint256 minCurrency0Amount, uint256 minCurrency1Amount) external;
}

interface IForkLauncher {
    function distributeToken(address token, ForkDistribution calldata distribution, bytes32 salt) external payable;
}

interface IForkPositionManager {
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (ForkPoolKey memory, uint256);
}

interface IForkStrategy {
    function launcher() external view returns (address);
    function positionManager() external view returns (address);
    function poolManager() external view returns (address);
    function feeSplitter() external view returns (address);
    function beneficiaryVault() external view returns (address);
    function positionLiquidity() external view returns (uint128);
    function initialSqrtPriceX96() external view returns (uint160);
}

interface IForkFeeSplitter {
    function getSplits() external view returns (ForkFeeSplit[] memory);
    function collectFees(uint256[] calldata tokenIds) external;
}

// Minimal test-only native/token settlement adapter. This is not a product swap router.
contract ForkSwapHarness {
    IForkPoolManager immutable manager;

    constructor(address manager_) {
        manager = IForkPoolManager(manager_);
    }

    function trade(ForkPoolKey calldata key, bool zeroForOne, uint256 amount, uint160 limit)
        external
        payable
        returns (int256 delta)
    {
        uint256 beforeNative = address(this).balance - msg.value;
        delta = abi.decode(manager.unlock(abi.encode(key, zeroForOne, amount, limit, msg.sender)), (int256));
        uint256 refund = address(this).balance - beforeNative;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (ForkPoolKey memory key, bool zeroForOne, uint256 amount, uint160 limit, address trader) =
            abi.decode(data, (ForkPoolKey, bool, uint256, uint160, address));
        int256 delta = manager.swap(key, ForkSwapParams(zeroForOne, -int256(amount), limit), "");
        int128 nativeDelta = int128(delta >> 128);
        int128 tokenDelta = int128(delta);
        if (nativeDelta < 0) manager.settle{value: uint128(-nativeDelta)}();
        else if (nativeDelta > 0) manager.take(address(0), trader, uint128(nativeDelta));
        if (tokenDelta < 0) {
            manager.sync(key.currency1);
            require(IERC20(key.currency1).transferFrom(trader, address(manager), uint128(-tokenDelta)));
            manager.settle();
        } else if (tokenDelta > 0) {
            manager.take(key.currency1, trader, uint128(tokenDelta));
        }
        return abi.encode(delta);
    }
    receive() external payable {}
}

contract ForkStandardToken is ERC20 {
    constructor() ERC20("Isolated Fork Fixture", "FORK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract ForkLaunchHarness {
    uint256 public createdCount;

    function create(address launcher, address strategy, address beneficiary)
        external
        returns (ForkStandardToken token)
    {
        createdCount++;
        token = new ForkStandardToken();
        // Funding and distribution are atomic. Never transfer real assets to this public launcher separately.
        token.transfer(launcher, token.totalSupply());
        IForkLauncher(launcher)
            .distributeToken(
                address(token),
                ForkDistribution(strategy, uint128(token.totalSupply()), abi.encode(beneficiary)),
                bytes32(0)
            );
    }
}

contract UniswapInstantLaunchForkTest is Test {
    address constant LAUNCHER = 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0;
    address constant STRATEGY = 0x23f8209572b4a1C2AD88A42749E830791Fb027f1;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SPLITTER = 0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf;
    address constant VAULT = 0xd35E9CA72F64C7F93BE30fad67524323396B36D7;
    address constant COMPOUNDER = 0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a;
    ForkLaunchHarness harness;
    address beneficiary;

    function predictedToken(InstantLaunchGateway gateway, address creator, bytes32 salt)
        internal
        pure
        returns (address)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(InstantCommunityToken).creationCode, abi.encode("Ocean Club", "OCEAN"))
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(gateway), keccak256(abi.encode(creator, salt)), initHash)
                    )
                )
            )
        );
    }

    function testGatewayCreatesForDirectCallerAndSupportsBuySell() public {
        InstantLaunchGateway gateway = new InstantLaunchGateway();
        bytes32 salt = keccak256("gateway-round-trip");
        address expected = predictedToken(gateway, beneficiary, salt);
        vm.prank(beneficiary);
        (address token, uint256 id) = gateway.create("Ocean Club", "OCEAN", salt, block.timestamp + 300);
        assertEq(token, expected);
        assertEq(gateway.tokenFor(beneficiary, salt), token);
        assertEq(IERC721(VAULT).ownerOf(id), beneficiary);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), SPLITTER);
        assertEq(IERC20(token).balanceOf(beneficiary), 0);
        roundTrip(ForkStandardToken(token), id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IForkFeeSplitter(SPLITTER).collectFees(ids);
        (uint128 earned,) = IForkBeneficiaryVault(VAULT).amounts(id);
        uint256 beforeClaim = beneficiary.balance;
        vm.prank(beneficiary);
        IForkBeneficiaryVault(VAULT).claim(id, earned, 0);
        assertGt(earned, 0);
        assertEq(beneficiary.balance - beforeClaim, earned);
    }

    function testGatewaySaltCannotBeReusedButAnotherCallerHasIndependentNamespace() public {
        InstantLaunchGateway gateway = new InstantLaunchGateway();
        bytes32 salt = bytes32(uint256(7));
        vm.prank(beneficiary);
        (address first,) = gateway.create("Ocean Club", "OCEAN", salt, block.timestamp);
        vm.expectRevert(InstantLaunchGateway.SaltUsed.selector);
        vm.prank(beneficiary);
        gateway.create("Other Club", "OTHER", salt, block.timestamp);
        address other = makeAddr("other-gateway-creator");
        vm.prank(other);
        (address second, uint256 id) = gateway.create("Ocean Club", "OCEAN", salt, block.timestamp);
        assertTrue(first != second);
        assertEq(gateway.tokenFor(beneficiary, salt), first);
        assertEq(gateway.tokenFor(other, salt), second);
        assertEq(IERC721(VAULT).ownerOf(id), other);
    }

    function testGatewayRejectsChangedRuntimeBeforeCreatingAnything() public {
        InstantLaunchGateway gateway = new InstantLaunchGateway();
        vm.etch(STRATEGY, hex"00");
        vm.expectRevert(abi.encodeWithSelector(InstantLaunchGateway.DeploymentMismatch.selector, STRATEGY));
        vm.prank(beneficiary);
        gateway.create("Ocean Club", "OCEAN", bytes32(0), block.timestamp);
        assertEq(gateway.tokenFor(beneficiary, bytes32(0)), address(0));
        assertEq(predictedToken(gateway, beneficiary, bytes32(0)).code.length, 0);
    }

    function testGatewayPostconditionFailureRollsBackTokenPositionAndSalt() public {
        InstantLaunchGateway gateway = new InstantLaunchGateway();
        uint256 beforeId = IForkPositionManager(POSITION_MANAGER).nextTokenId();
        // Inject a bad postcondition, not a fake successful protocol run.
        vm.mockCall(
            POSITION_MANAGER,
            abi.encodeCall(IForkPositionManager.getPositionLiquidity, (beforeId)),
            abi.encode(uint128(0))
        );
        vm.expectRevert(InstantLaunchGateway.IncompleteLaunch.selector);
        vm.prank(beneficiary);
        gateway.create("Ocean Club", "OCEAN", bytes32(0), block.timestamp);
        vm.clearMockedCalls();
        assertEq(IForkPositionManager(POSITION_MANAGER).nextTokenId(), beforeId);
        assertEq(gateway.tokenFor(beneficiary, bytes32(0)), address(0));
        assertEq(predictedToken(gateway, beneficiary, bytes32(0)).code.length, 0);
    }

    function testGatewayRejectsInvalidMetadataExpiredRequestAndNativePayment() public {
        InstantLaunchGateway gateway = new InstantLaunchGateway();
        vm.expectRevert(InstantLaunchGateway.InvalidMetadata.selector);
        gateway.create("Ocean Club", "ocean", bytes32(0), block.timestamp);
        vm.expectRevert(InstantLaunchGateway.InvalidMetadata.selector);
        gateway.create(" Ocean Club", "OCEAN", bytes32(0), block.timestamp);
        vm.expectRevert(InstantLaunchGateway.Expired.selector);
        gateway.create("Ocean Club", "OCEAN", bytes32(0), block.timestamp - 1);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(gateway).call{value: 1}(
            abi.encodeCall(InstantLaunchGateway.create, ("Ocean Club", "OCEAN", bytes32(0), block.timestamp))
        );
        assertFalse(ok);
        assertEq(address(gateway).balance, 0);
        assertEq(gateway.tokenFor(address(this), bytes32(0)), address(0));
    }

    function setUp() public {
        // Normal unit tests do not make unexpected public RPC requests.
        if (!vm.envOr("BARK_RUN_UNISWAP_FORK", false)) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "Pass the explicitly pinned Robinhood fork to Forge");
        // Nitro's NUMBER opcode uses the L1 block number. Pin it alongside the RPC fork block.
        assertEq(block.number, vm.envOr("BARK_FORK_L1_BLOCK", uint256(25913616)));
        assertEq(LAUNCHER.codehash, bytes32(0x4a586d925c9d59ece13ce2239ebd7dea9ee725f9d33c6667e0fd16ae8d977d80));
        assertEq(STRATEGY.codehash, bytes32(0x29df27cf43533e9b3708dcd2a2c0fd17a1a8796407e7d39375f47e5c809cffca));
        assertEq(POSITION_MANAGER.codehash, bytes32(0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2));
        assertEq(POOL_MANAGER.codehash, bytes32(0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626));
        assertEq(SPLITTER.codehash, bytes32(0x8238e5106b3a895514083110d1f3b4e51be61148604f35113719af56ae325f42));
        assertEq(VAULT.codehash, bytes32(0x725412bf002214373afc095b0b9e4c756b1d12ac37d5c7dfe1667db4385403b6));
        assertEq(IForkStrategy(STRATEGY).launcher(), LAUNCHER);
        assertEq(IForkStrategy(STRATEGY).positionManager(), POSITION_MANAGER);
        assertEq(IForkStrategy(STRATEGY).poolManager(), POOL_MANAGER);
        assertEq(IForkStrategy(STRATEGY).feeSplitter(), SPLITTER);
        assertEq(IForkStrategy(STRATEGY).beneficiaryVault(), VAULT);
        harness = new ForkLaunchHarness();
        beneficiary = makeAddr("fork-beneficiary");
    }

    function create() internal returns (ForkStandardToken token, uint256 id) {
        id = IForkPositionManager(POSITION_MANAGER).nextTokenId();
        token = harness.create(LAUNCHER, STRATEGY, beneficiary);
    }

    function testForkCreatesRealV4PositionAndSeparatesFeeRightFromLpCustody() public {
        (ForkStandardToken token, uint256 id) = create();
        (ForkPoolKey memory key,) = IForkPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(id);
        assertEq(key.currency0, address(0));
        assertEq(key.currency1, address(token));
        assertEq(key.fee, 2500);
        assertEq(key.tickSpacing, 25);
        assertEq(key.hooks, address(0));
        assertEq(
            IForkPositionManager(POSITION_MANAGER).getPositionLiquidity(id), IForkStrategy(STRATEGY).positionLiquidity()
        );
        assertGt(IForkPositionManager(POSITION_MANAGER).getPositionLiquidity(id), 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), SPLITTER);
        assertEq(IERC721(VAULT).ownerOf(id), beneficiary);
        assertEq(token.balanceOf(POOL_MANAGER) + token.balanceOf(address(0xdead)), token.totalSupply());
        assertEq(token.balanceOf(LAUNCHER), 0);
        assertEq(token.balanceOf(STRATEGY), 0);
        assertEq(token.balanceOf(address(harness)), 0);
        ForkFeeSplit[] memory splits = IForkFeeSplitter(SPLITTER).getSplits();
        assertEq(splits.length, 2);
        uint256 found;
        for (uint256 i; i < splits.length; i++) {
            if (splits[i].recipient == VAULT) {
                assertEq(splits[i].nativeBps, 4000);
                assertEq(splits[i].tokenBps, 0);
                found++;
            }
            if (splits[i].recipient == COMPOUNDER) {
                assertEq(splits[i].nativeBps, 6000);
                assertEq(splits[i].tokenBps, 10000);
                found++;
            }
        }
        assertEq(found, 2);
    }

    function testForkFeeNftTransferDoesNotGrantWithdrawalOfTheLpPosition() public {
        (, uint256 id) = create();
        address nextOwner = makeAddr("next-fork-beneficiary");
        vm.prank(beneficiary);
        IERC721(VAULT).transferFrom(beneficiary, nextOwner, id);
        assertEq(IERC721(VAULT).ownerOf(id), nextOwner);
        vm.expectRevert();
        vm.prank(nextOwner);
        IERC721(POSITION_MANAGER).transferFrom(SPLITTER, nextOwner, id);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), SPLITTER);
    }

    function testForkInvalidBeneficiaryRevertsCreationAndDistributionTogether() public {
        uint256 beforeId = IForkPositionManager(POSITION_MANAGER).nextTokenId();
        vm.expectRevert(abi.encodeWithSignature("InvalidFeeBeneficiary(address)", address(0)));
        harness.create(LAUNCHER, STRATEGY, address(0));
        assertEq(harness.createdCount(), 0);
        assertEq(IForkPositionManager(POSITION_MANAGER).nextTokenId(), beforeId);
    }

    function roundTrip(ForkStandardToken token, uint256 id) internal {
        (ForkPoolKey memory key,) = IForkPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(id);
        ForkSwapHarness router = new ForkSwapHarness(POOL_MANAGER);
        address trader = makeAddr("fork-trader");
        vm.deal(trader, 1 ether);
        uint160 openingPrice = IForkStrategy(STRATEGY).initialSqrtPriceX96();
        vm.prank(trader);
        router.trade{value: 0.01 ether}(key, true, 0.01 ether, openingPrice / 2);
        uint256 purchased = token.balanceOf(trader);
        assertGt(purchased, 0);
        uint256 beforeExit = trader.balance;
        vm.startPrank(trader);
        token.approve(address(router), purchased);
        router.trade(key, false, purchased, openingPrice);
        vm.stopPrank();
        assertEq(token.balanceOf(trader), 0);
        assertGt(trader.balance, beforeExit);
        assertLt(trader.balance, 1 ether);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function testForkBuyerCanExitAndOnlyCurrentFeeNftOwnerCanClaimCollectedNativeFees() public {
        (ForkStandardToken token, uint256 id) = create();
        roundTrip(token, id);
        address nextOwner = makeAddr("fork-fee-owner");
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IForkFeeSplitter(SPLITTER).collectFees(ids);
        (uint128 earnedNative, uint128 earnedToken) = IForkBeneficiaryVault(VAULT).amounts(id);
        assertGt(earnedNative, 0);
        assertEq(earnedToken, 0);
        vm.prank(beneficiary);
        IERC721(VAULT).transferFrom(beneficiary, nextOwner, id);
        vm.expectRevert();
        vm.prank(beneficiary);
        IForkBeneficiaryVault(VAULT).claim(id, earnedNative, 0);
        uint256 beforeClaim = nextOwner.balance;
        vm.prank(nextOwner);
        IForkBeneficiaryVault(VAULT).claim(id, earnedNative, 0);
        assertEq(nextOwner.balance - beforeClaim, earnedNative);
        (uint128 afterNative, uint128 afterToken) = IForkBeneficiaryVault(VAULT).amounts(id);
        assertEq(afterNative, 0);
        assertEq(afterToken, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), SPLITTER);
    }
}
