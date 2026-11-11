// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FairToken.sol";
import "../src/FairMinter.sol";
import "../src/test/MockAgentIdRegistry.sol";
import "../src/test/MockPancake.sol";

/// @notice Full-flow tests for $FAIR. Uses a small maxShares (10) so the
///         sold-out path is reachable; the locked mainnet values
///         (100,000 shares, 5,000,000 FAIR/share, 0.001 BNB/share) are
///         verified separately in testLockedMainnetParams.
contract FairTest is Test {
    FairToken token;
    FairMinter minter;
    MockAgentIdRegistry registry;
    MockPancake router;
    address pair;
    address wbnb;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant START = 1_800_000_000; // fixed test start
    uint256 constant MAX_SHARES = 10;
    uint256 constant PER_SHARE = 5_000_000 * 1e18;
    uint256 constant PRICE = 0.001 ether;
    uint256 constant LP_POOL = 500_000_000_000 * 1e18;
    uint256 constant THRESHOLD = 1e12; // 0.000001 BNB, test-only small value

    function setUp() public {
        pair = makeAddr("pair");
        wbnb = makeAddr("wbnb");
        router = new MockPancake{value: 10 ether}(pair, wbnb);
        token = new FairToken(address(router), wbnb, THRESHOLD);
        router.setFair(address(token));
        registry = new MockAgentIdRegistry();
        registry.register(alice, "alice.ai");
        registry.register(bob, "bob.ai");
        registry.register(carol, ""); // has an ID entry but an empty handle
        minter = new FairMinter(
            address(token), address(registry), address(router),
            START, MAX_SHARES, PER_SHARE, PRICE, LP_POOL
        );
        token.setMinter(address(minter));
        // fund the mock router with FAIR so buybacks can settle
        token.transfer(address(router), 100_000_000 * 1e18);
        // fund the pair so simulated buys can move FAIR
        token.transfer(pair, 10_000_000 * 1e18);
        // the rest (mint pool + LP pool) goes to the minter
        token.transfer(address(minter), token.balanceOf(address(this)));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _mint(address who, uint256 shares) internal {
        vm.prank(who);
        minter.mint{value: shares * PRICE}(shares);
    }

    // ---- mint gate ----

    function testMintBeforeStartReverts() public {
        vm.warp(START - 1);
        vm.prank(alice);
        vm.expectRevert("not started");
        minter.mint{value: PRICE}(1);
    }

    function testMintSuccess() public {
        vm.warp(START);
        _mint(alice, 5);
        assertEq(token.balanceOf(alice), 5 * PER_SHARE);
        assertEq(address(minter).balance, 5 * PRICE);
        assertEq(minter.totalSold(), 5);
        assertEq(minter.mintedByHandle(keccak256(bytes("alice.ai"))), 5);
    }

    function testMintGateNoIdReverts() public {
        vm.warp(START);
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert("no agent id");
        minter.mint{value: PRICE}(1);
    }

    function testMintGateEmptyHandleReverts() public {
        vm.warp(START);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert("empty handle");
        minter.mint{value: PRICE}(1);
    }

    function testMintPerIdCap() public {
        vm.warp(START);
        _mint(alice, 5);
        vm.prank(alice);
        vm.expectRevert("id cap 5");
        minter.mint{value: PRICE}(1);
    }

    function testMintWrongValueReverts() public {
        vm.warp(START);
        vm.prank(alice);
        vm.expectRevert("wrong value");
        minter.mint{value: PRICE + 1}(1);
    }

    function testMintZeroSharesReverts() public {
        vm.warp(START);
        vm.prank(alice);
        vm.expectRevert("shares 1..5");
        minter.mint{value: 0}(0);
    }

    // ---- tax ----

    function testBuyTax2AndSellTax4() public {
        // NOTE: setUp already put 400,000 FAIR of tax in the pool, because
        // funding the pair with 10,000,000 FAIR is itself a sell (4% tax).
        // buy: pair -> alice, 1,000,000 FAIR, 2% tax
        vm.prank(pair);
        token.transfer(alice, 1_000_000 * 1e18);
        assertEq(token.balanceOf(alice), 980_000 * 1e18);
        assertEq(token.balanceOf(address(token)), 420_000 * 1e18);
        // sell: alice -> pair, 980,000 FAIR, 4% tax
        vm.prank(alice);
        token.transfer(pair, 980_000 * 1e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 420_000 * 1e18 + 39_200 * 1e18);
    }

    function testWalletToWalletNoTax() public {
        vm.warp(START);
        _mint(alice, 1);
        vm.prank(alice);
        token.transfer(bob, 1_000_000 * 1e18);
        assertEq(token.balanceOf(bob), 1_000_000 * 1e18);
        // pool is unchanged by wallet-to-wallet transfers: it still holds
        // only the 400,000 FAIR from setUp's pair funding (a sell, 4% tax)
        assertEq(token.balanceOf(address(token)), 400_000 * 1e18);
    }

    function testMintItselfNotTaxed() public {
        vm.warp(START);
        _mint(alice, 1);
        assertEq(token.balanceOf(alice), PER_SHARE); // full 5,000,000, no tax
    }

    // ---- finalize: sold out ----

    function testFinalizeSoldOut() public {
        vm.warp(START);
        _mint(alice, 5);
        _mint(bob, 5);
        assertEq(minter.totalSold(), MAX_SHARES);
        minter.finalize();
        assertTrue(minter.finalized());
        // LP: 500B * 10/10 = 500B FAIR + 0.01 BNB, LP tokens to dead
        assertEq(router.lpMintedTo(token.DEAD()), LP_POOL);
        // nothing left in the minter: minted 50M + LP 500B = 500,050,000,000;
        // the rest of the minter's balance (499,840,000,000) burned to dead.
        // (110M FAIR sits with the mock router/pair as test funding, not burned.)
        assertEq(token.balanceOf(address(minter)), 0);
        assertEq(token.balanceOf(token.DEAD()), 499_840_000_000 * 1e18);
        assertEq(address(minter).balance, 0);
    }

    function testFinalizeTooEarlyReverts() public {
        vm.warp(START);
        _mint(alice, 1);
        vm.expectRevert("too early");
        minter.finalize();
    }

    // ---- finalize: 30-day fallback, partial fill ----

    function testFinalize30DayPartial() public {
        vm.warp(START);
        _mint(alice, 4); // 4 of 10 shares
        vm.warp(START + 30 days + 1);
        minter.finalize();
        // LP tokens = 500B * 4/10 = 200B FAIR + 0.004 BNB
        assertEq(router.lpMintedTo(token.DEAD()), 200_000_000_000 * 1e18);
        // burned = minter balance 999,890,000,000 - minted 20M - LP 200B
        //        = 799,870,000,000 (110M FAIR sits with mock router/pair)
        assertEq(token.balanceOf(token.DEAD()), 799_870_000_000 * 1e18);
        assertEq(token.balanceOf(address(minter)), 0);
    }

    function testFinalizeTwiceReverts() public {
        vm.warp(START);
        _mint(alice, 5);
        _mint(bob, 5);
        minter.finalize();
        vm.expectRevert("already finalized");
        minter.finalize();
    }

    // ---- tax swap + buyback ----

    function testSwapTaxAndBuyback() public {
        vm.prank(pair);
        token.transfer(alice, 1_000_000 * 1e18); // +20,000 FAIR tax
        // pool: 400,000 (setUp) + 20,000 = 420,000 FAIR
        assertEq(token.taxPoolValueBNB(), 420_000 * 1e18 * 2e8 / 1e18);
        uint256 bnbBefore = address(token).balance;
        token.swapTaxToBNB();
        uint256 taxBnb = address(token).balance - bnbBefore;
        assertEq(taxBnb, 420_000 * 1e18 * 2e8 / 1e18); // 8.4e13 wei
        assertEq(token.balanceOf(address(token)), 0);
        uint256 deadBefore = token.balanceOf(token.DEAD());
        token.buybackAndBurn();
        // mock price: 8.4e13 wei BNB buys 420,000 FAIR to dead
        // (real Pancake would shave 2% buy tax off this; the mock is not a pair)
        assertEq(token.balanceOf(token.DEAD()) - deadBefore, 420_000 * 1e18);
        assertEq(address(token).balance, 0);
    }

    function testSwapTaxBelowThresholdReverts() public {
        // fresh token + fresh mock router with a tiny tax pool: fund the
        // pair with 1,000 FAIR, which is a sell, so 40 FAIR of tax lands
        // in the pool (value 8e9 wei < THRESHOLD 1e12 wei)
        MockPancake router2 = new MockPancake{value: 1 ether}(pair, wbnb);
        FairToken t2 = new FairToken(address(router2), wbnb, THRESHOLD);
        router2.setFair(address(t2));
        t2.transfer(pair, 1_000 * 1e18);
        assertEq(t2.balanceOf(address(t2)), 40 * 1e18);
        vm.expectRevert("below threshold");
        t2.swapTaxToBNB();
    }

    // ---- locked mainnet parameters are accepted by the constructors ----

    function testLockedMainnetParams() public {
        FairToken t2 = new FairToken(address(router), wbnb, 0.05 ether);
        FairMinter m2 = new FairMinter(
            address(t2), address(registry), address(router),
            1794715200, // 2026-11-15 12:00 CST = 04:00 UTC
            100_000, 5_000_000 * 1e18, 0.001 ether, 500_000_000_000 * 1e18
        );
        assertEq(m2.maxShares(), 100_000);
        assertEq(m2.tokensPerShare(), 5_000_000 * 1e18);
        assertEq(m2.pricePerShare(), 0.001 ether);
        assertEq(m2.finalizeAfter(), 1794715200 + 30 days);
        assertEq(m2.finalizeAfter(), 1797307200); // 2026-12-15 12:00 CST
    }
}
