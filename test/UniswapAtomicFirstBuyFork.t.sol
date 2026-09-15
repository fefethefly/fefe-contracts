// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    InstantLaunchAndBuyGateway,
    IInitialBuyPoolManager,
    InitialSwapParams
} from "../src/candidates/InstantLaunchAndBuyGateway.sol";
import {InstantCommunityToken, InstantPoolKey} from "../src/candidates/InstantLaunchGateway.sol";
import {
    UniswapInstantLaunchForkTest,
    IForkPositionManager,
    IForkFeeSplitter,
    IForkBeneficiaryVault,
    ForkSwapHarness,
    ForkPoolKey
} from "./UniswapInstantLaunchFork.t.sol";

interface IAtomicPoolInitialize {
    function initialize(InstantPoolKey calldata, uint160) external returns (int24);
}

contract UniswapAtomicFirstBuyForkTest is UniswapInstantLaunchForkTest {
    function atomicGateway() internal returns (InstantLaunchAndBuyGateway) {
        vm.deal(beneficiary, 10 ether);
        return new InstantLaunchAndBuyGateway();
    }

    function expectedToken(InstantLaunchAndBuyGateway gateway, address creator, bytes32 salt)
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

    function testAtomicCreationAndBuyPreserveSupplyOwnershipAndExactNativeBudget() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        bytes32 salt = keccak256("atomic-native-buy");
        uint256 beforeBalance = beneficiary.balance;
        uint256 beforePool = POOL_MANAGER.balance;
        vm.prank(beneficiary);
        (address token, uint256 id, uint256 output) =
            gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1, block.timestamp + 300);
        assertEq(token, expectedToken(gateway, beneficiary, salt));
        assertGt(output, 0);
        assertEq(IERC20(token).balanceOf(beneficiary), output);
        assertEq(
            IERC20(token).balanceOf(POOL_MANAGER) + IERC20(token).balanceOf(address(0xdead)) + output,
            1_000_000_000 ether
        );
        assertEq(beneficiary.balance, beforeBalance - 0.01 ether);
        assertEq(POOL_MANAGER.balance, beforePool + 0.01 ether);
        assertEq(address(gateway).balance, 0);
        assertEq(IERC721(VAULT).ownerOf(id), beneficiary);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(id), SPLITTER);
        assertEq(gateway.tokenFor(beneficiary, salt), token);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IForkFeeSplitter(SPLITTER).collectFees(ids);
        (uint128 earned,) = IForkBeneficiaryVault(VAULT).amounts(id);
        assertGt(earned, 0);
    }

    function testAtomicMinimumOutputFailureRollsBackCreationAndSaltThenAllowsRetry() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        bytes32 salt = keccak256("atomic-rollback");
        uint256 beforeId = IForkPositionManager(POSITION_MANAGER).nextTokenId();
        uint256 beforeBalance = beneficiary.balance;
        uint256 beforePool = POOL_MANAGER.balance;
        vm.expectRevert(InstantLaunchAndBuyGateway.MinimumOutputNotMet.selector);
        vm.prank(beneficiary);
        gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1_000_000_001 ether, block.timestamp + 300);
        assertEq(gateway.tokenFor(beneficiary, salt), address(0));
        assertEq(expectedToken(gateway, beneficiary, salt).code.length, 0);
        assertEq(IForkPositionManager(POSITION_MANAGER).nextTokenId(), beforeId);
        assertEq(beneficiary.balance, beforeBalance);
        assertEq(POOL_MANAGER.balance, beforePool);
        assertEq(address(gateway).balance, 0);
        vm.prank(beneficiary);
        (address token, uint256 id,) =
            gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1, block.timestamp + 300);
        assertEq(id, beforeId);
        assertGt(IERC20(token).balanceOf(beneficiary), 0);
    }

    function testAtomicGatewayCannotSpendPreviouslyForcedNativeFunds() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        vm.deal(address(gateway), 1 ether);
        uint256 beforePool = POOL_MANAGER.balance;
        vm.prank(beneficiary);
        gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", bytes32(0), 1, block.timestamp);
        assertEq(address(gateway).balance, 1 ether);
        assertEq(POOL_MANAGER.balance, beforePool + 0.01 ether);
    }

    function testAtomicPartialFillDeltaIsRejectedAndAllCreationStateRollsBack() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        bytes32 salt = keccak256("partial-delta");
        address token = expectedToken(gateway, beneficiary, salt);
        uint256 beforeId = IForkPositionManager(POSITION_MANAGER).nextTokenId();
        int256 partialDelta = (int256(-int128(uint128(0.005 ether))) << 128) | int256(uint256(1 ether));
        vm.mockCall(
            POOL_MANAGER,
            abi.encodeCall(
                IInitialBuyPoolManager.swap,
                (
                    InstantPoolKey(address(0), token, 2500, 25, address(0)),
                    InitialSwapParams(true, -int256(0.01 ether), 4295128740),
                    bytes("")
                )
            ),
            abi.encode(partialDelta)
        );
        vm.expectRevert(InstantLaunchAndBuyGateway.BuyNotFilled.selector);
        vm.prank(beneficiary);
        gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1, block.timestamp);
        vm.clearMockedCalls();
        assertEq(token.code.length, 0);
        assertEq(gateway.tokenFor(beneficiary, salt), address(0));
        assertEq(IForkPositionManager(POSITION_MANAGER).nextTokenId(), beforeId);
    }

    function testAtomicBuyerCanSellThroughActualProtocolAfterCreation() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        vm.prank(beneficiary);
        (address token,, uint256 output) =
            gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", bytes32(0), 1, block.timestamp);
        ForkSwapHarness swapper = new ForkSwapHarness(POOL_MANAGER);
        vm.prank(beneficiary);
        IERC20(token).approve(address(swapper), output);
        uint256 beforeBalance = beneficiary.balance;
        vm.prank(beneficiary);
        swapper.trade(
            ForkPoolKey(address(0), token, 2500, 25, address(0)),
            false,
            output,
            1461446703485210103287273052203988822378723970341
        );
        assertEq(IERC20(token).balanceOf(beneficiary), 0);
        assertGt(beneficiary.balance, beforeBalance);
        assertLt(beneficiary.balance - beforeBalance, 0.01 ether);
    }

    function testAtomicPreinitializedPredictedPoolCanBlockLaunchButCannotTakePayment() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        bytes32 salt = keccak256("preinitialized");
        address token = expectedToken(gateway, beneficiary, salt);
        IAtomicPoolInitialize(POOL_MANAGER)
            .initialize(InstantPoolKey(address(0), token, 2500, 25, address(0)), uint160(1 << 96));
        uint256 beforeBalance = beneficiary.balance;
        uint256 beforeId = IForkPositionManager(POSITION_MANAGER).nextTokenId();
        vm.expectRevert();
        vm.prank(beneficiary);
        gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1, block.timestamp);
        assertEq(beneficiary.balance, beforeBalance);
        assertEq(token.code.length, 0);
        assertEq(gateway.tokenFor(beneficiary, salt), address(0));
        assertEq(IForkPositionManager(POSITION_MANAGER).nextTokenId(), beforeId);
    }

    function testAtomicSuccessfulSaltCannotBeUsedTwiceAndCallbacksCannotBeReplayed() public {
        InstantLaunchAndBuyGateway gateway = atomicGateway();
        bytes32 salt = bytes32(uint256(99));
        vm.prank(beneficiary);
        (address token,,) = gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1, block.timestamp);
        vm.expectRevert(InstantLaunchAndBuyGateway.SaltUsed.selector);
        vm.prank(beneficiary);
        gateway.createAndBuy{value: 0.01 ether}("Ocean Club", "OCEAN", salt, 1, block.timestamp);
        vm.expectRevert(InstantLaunchAndBuyGateway.InvalidCallback.selector);
        vm.prank(POOL_MANAGER);
        gateway.unlockCallback(abi.encode(beneficiary, token, uint128(0.01 ether), uint256(1)));
    }
}
