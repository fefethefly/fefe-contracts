// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DirectLaunchpadV3} from "../src/v3/DirectLaunchpadV3.sol";
import {MemeTokenV3} from "../src/v3/MemeTokenV3.sol";
import {FeeVaultV3} from "../src/v3/FeeVaultV3.sol";
import {IDirectLaunchHandlerV3, ISwapAdapterV3, NATIVE} from "../src/v3/InterfacesV3.sol";

contract MockDirectHandler is IDirectLaunchHandlerV3 {
    address public pool = address(0xBeeF);
    address public lastToken;
    address public lastQuote;
    uint256 public lastVirtualQuote;
    address public lastVault;

    function launchDirect(address token, address quote, uint256 virtualQuote, address vault)
        external
        returns (address)
    {
        lastToken = token;
        lastQuote = quote;
        lastVirtualQuote = virtualQuote;
        lastVault = vault;
        return pool;
    }
}

contract MockAdapter is ISwapAdapterV3 {
    function swapExactIn(address, address, uint256, uint256, address) external payable returns (uint256) {
        return 0;
    }
}

/// Code-bearing stand-in for a basket stock (FeeVaultV3 requires basket tokens to have code).
contract MockToken {}

/// Direct launchpad plumbing, no Uniswap fork needed: the handler is mocked and the vault
/// is deployed for real, so token minting / binding / deployment records are all asserted.
contract DirectLaunchpadV3Test is Test {
    DirectLaunchpadV3 pad;
    MockDirectHandler handler;
    address creator = makeAddr("creator");
    address basket;

    function setUp() public {
        handler = new MockDirectHandler();
        MockAdapter adapter = new MockAdapter();
        pad = new DirectLaunchpadV3(handler, adapter);
        basket = address(new MockToken());
    }

    function params() internal view returns (DirectLaunchpadV3.DirectLaunch memory p) {
        address[] memory basketTokens = new address[](1);
        basketTokens[0] = basket;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        p = DirectLaunchpadV3.DirectLaunch({
            name: "Ocean Club",
            symbol: "OCEAN",
            quoteAsset: NATIVE,
            virtualQuote: 1 ether,
            buyTaxBps: 100,
            sellTaxBps: 100,
            split: FeeVaultV3.Split({creatorBps: 5000, basketBps: 3000, jackpotBps: 0, burnBps: 2000}),
            basketTokens: basketTokens,
            basketWeights: weights,
            salt: bytes32(uint256(42)),
            deadline: block.timestamp + 1 hours
        });
    }

    function test_create_predictsAddress_and_mintsWholeSupplyToHandler() public {
        DirectLaunchpadV3.DirectLaunch memory p = params();
        address expected = pad.predictToken(creator, p.salt);
        vm.prank(creator);
        (address token, address vault, address pool) = pad.create(p);

        assertEq(token, expected);
        assertEq(pool, handler.pool());
        assertEq(handler.lastToken(), token);
        assertEq(handler.lastQuote(), NATIVE);
        assertEq(handler.lastVirtualQuote(), 1 ether);
        assertEq(handler.lastVault(), vault);

        MemeTokenV3 t = MemeTokenV3(token);
        assertEq(t.balanceOf(address(handler)), t.FIXED_SUPPLY(), "100% supply minted to the handler");
        assertEq(t.balanceOf(creator), 0, "creator receives no tokens");
        assertEq(t.curve(), address(handler), "handler is the token authority (curve slot)");
        assertEq(address(t.taxSink()), vault, "vault receives hook tax");

        FeeVaultV3 v = FeeVaultV3(payable(vault));
        assertEq(address(v.token()), token);
        assertEq(v.quote(), NATIVE);
        assertEq(v.creator(), creator);
        assertEq(v.curve(), address(handler), "direct vault buyback resolves to adapter");

        (address dt, address dc, address dv, address dcreator, address dq,) = pad.deployments(token);
        assertEq(dt, token);
        assertEq(dc, address(0), "no curve in direct mode");
        assertEq(dv, vault);
        assertEq(dcreator, creator);
        assertEq(dq, NATIVE);
        assertEq(pad.tokenCount(), 1);
        assertEq(pad.tokens(0), token);
    }

    function test_create_rejectsJackpotSplit() public {
        DirectLaunchpadV3.DirectLaunch memory p = params();
        p.split.jackpotBps = 1000;
        p.split.creatorBps = 4000;
        vm.expectRevert(DirectLaunchpadV3.DIRECT_JACKPOT_UNSUPPORTED.selector);
        vm.prank(creator);
        pad.create(p);
    }

    function test_create_rejectsBadNameSymbolQuoteVirtualAndDeadline() public {
        DirectLaunchpadV3.DirectLaunch memory p = params();
        p.symbol = "o";
        vm.expectRevert(DirectLaunchpadV3.INVALID_NAME.selector);
        pad.create(p);

        p = params();
        p.virtualQuote = 0;
        vm.expectRevert(DirectLaunchpadV3.INVALID_CURVE.selector);
        pad.create(p);

        p = params();
        p.quoteAsset = makeAddr("no-code");
        vm.expectRevert(DirectLaunchpadV3.INVALID_QUOTE.selector);
        pad.create(p);

        p = params();
        p.deadline = block.timestamp - 1;
        vm.expectRevert(DirectLaunchpadV3.EXPIRED.selector);
        pad.create(p);
    }

    function test_create_saltIsNamespacedPerCreator_and_reuseReverts() public {
        DirectLaunchpadV3.DirectLaunch memory p = params();
        address other = makeAddr("other");
        vm.prank(creator);
        (address first,,) = pad.create(p);

        // Same creator + salt again → CREATE2 collision.
        vm.expectRevert();
        vm.prank(creator);
        pad.create(p);

        // Another creator, same salt → independent namespace.
        vm.prank(other);
        (address second,,) = pad.create(p);
        assertTrue(first != second);
        assertEq(pad.tokenCount(), 2);
    }

    function test_constructor_rejectsCodeLessHandlerAndAdapter() public {
        MockAdapter adapter = new MockAdapter();
        vm.expectRevert(DirectLaunchpadV3.INVALID_CONFIG.selector);
        new DirectLaunchpadV3(IDirectLaunchHandlerV3(makeAddr("nohandler")), adapter);
        vm.expectRevert(DirectLaunchpadV3.INVALID_CONFIG.selector);
        new DirectLaunchpadV3(handler, ISwapAdapterV3(makeAddr("noadapter")));
    }
}
