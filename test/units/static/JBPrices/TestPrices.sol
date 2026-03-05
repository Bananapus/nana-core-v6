// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBPricesSetup} from "./JBPricesSetup.sol";
import {MockPriceFeed} from "../../../mock/MockPriceFeed.sol";

/// @notice Edge case & bug-hunting tests for JBPrices.
/// Covers inverse precision, feed immutability, default fallback, and the overly-restrictive
/// default-blocks-project-specific issue.
contract TestPrices_Local is JBPricesSetup {
    uint256 constant DEFAULT_PROJECT_ID = 0;
    uint256 constant PROJECT_ID = 1;
    uint256 _pricingCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
    uint256 _unitCurrency = uint32(uint160(makeAddr("unitToken")));

    function setUp() public {
        super.pricesSetup();
    }

    // ───────────────────── Helpers
    // ─────────────────────

    /// @dev Sets a mock price feed directly into storage for a given project.
    function _storeFeed(uint256 projectId, uint256 pricing, uint256 unit_, address feed) internal {
        bytes32 slot0 = keccak256(abi.encode(projectId, uint256(1)));
        bytes32 slot1 = keccak256(abi.encode(pricing, uint256(slot0)));
        bytes32 slot2 = keccak256(abi.encode(unit_, uint256(slot1)));
        vm.store(address(_prices), slot2, bytes32(uint256(uint160(feed))));
    }

    // ───────────────────── Inverse precision tests
    // ─────────────────────

    /// @notice Feed returns 1 (minimum non-zero price). Inverse should be 10^(2*decimals).
    function test_inversePrecision_smallPrice() external {
        uint256 decimals = 18;
        MockPriceFeed feed = new MockPriceFeed(1, decimals);
        _storeFeed(PROJECT_ID, _unitCurrency, _pricingCurrency, address(feed));

        // Query the inverse direction: pricing → unit requires inverting the unit→pricing feed.
        uint256 inverse = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, decimals);
        // inverse = 10^18 * 10^18 / 1 = 10^36, but mulDiv(10^18, 10^18, 1) = 10^36
        // Wait: the formula is mulDiv(10^decimals, 10^decimals, feedPrice) = mulDiv(10^18, 10^18, 1)
        assertEq(inverse, 10 ** (2 * decimals), "Inverse of price=1 should be 10^(2*decimals)");
    }

    /// @notice Feed returns near-max value. Inverse should not underflow to 0.
    function test_inversePrecision_largePrice() external {
        uint256 decimals = 18;
        // Price is 10^36 (very large).
        // Inverse = mulDiv(10^18, 10^18, 10^36) = 10^36 / 10^36 = 1
        MockPriceFeed feed = new MockPriceFeed(10 ** 36, 18);
        _storeFeed(PROJECT_ID, _unitCurrency, _pricingCurrency, address(feed));

        uint256 inverse = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, decimals);
        assertEq(inverse, 1, "Inverse of very large price should be 1 (floor)");
    }

    /// @notice Fuzz: price(A->B) * price(B->A) should approximate 10^(2*decimals).
    /// Bounded to realistic price range where precision is expected to hold.
    function testFuzz_inversePrecision_roundTrip(uint256 price) external {
        uint256 decimals = 18;
        // Bound price to [10^9, 10^27] — realistic range where inverse precision is reasonable.
        // Outside this range, integer division precision loss is severe (see test below).
        price = bound(price, 10 ** 9, 10 ** 27);

        MockPriceFeed feed = new MockPriceFeed(price, decimals);

        // Store feed as direct A->B feed.
        _storeFeed(PROJECT_ID, _pricingCurrency, _unitCurrency, address(feed));

        // Get direct price.
        uint256 direct = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, decimals);
        assertEq(direct, price, "Direct price should match feed");

        // Get inverse price (B->A).
        uint256 inverse = _prices.pricePerUnitOf(PROJECT_ID, _unitCurrency, _pricingCurrency, decimals);

        // Round-trip: direct * inverse should approximate 10^decimals.
        uint256 product = mulDiv(direct, inverse, 10 ** decimals);
        assertApproxEqRel(product, 10 ** decimals, 0.01e18, "Round-trip should approximate 10^decimals");
    }

    /// @notice PRECISION BUG: At extreme prices (>10^27), inverse precision degrades severely.
    /// For non-power-of-10 prices, round-trip error can exceed 10%.
    function test_inversePrecision_degradesAtExtremes() external {
        uint256 decimals = 18;
        // Price of 3*10^35 — inverse = mulDiv(10^18, 10^18, 3*10^35) = floor(3.33) = 3
        MockPriceFeed feed = new MockPriceFeed(3 * 10 ** 35, decimals);
        _storeFeed(PROJECT_ID, _unitCurrency, _pricingCurrency, address(feed));

        uint256 inverse = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, decimals);
        // Inverse only has 1 significant digit — massive precision loss.
        assertEq(inverse, 3, "Extreme price inverse has only 1 digit of precision");

        // Round-trip: 3*10^35 * 3 / 10^18 = 9*10^17 (should be 10^18). 10% error.
        uint256 product = mulDiv(3 * 10 ** 35, inverse, 10 ** decimals);
        assertEq(product, 9 * 10 ** 17, "Round-trip at extreme prices loses 10% precision");
    }

    /// @notice inverse(inverse(price)) should approximately equal price (precision loss compounds).
    function test_inversePrecision_asymmetry() external {
        uint256 decimals = 18;
        uint256 originalPrice = 3333 * 10 ** 14; // 0.3333 ETH (a price that doesn't divide evenly)

        // Store A->B feed.
        MockPriceFeed feed = new MockPriceFeed(originalPrice, decimals);
        _storeFeed(PROJECT_ID, _pricingCurrency, _unitCurrency, address(feed));

        // Get inverse (B->A).
        uint256 inversePrice = _prices.pricePerUnitOf(PROJECT_ID, _unitCurrency, _pricingCurrency, decimals);

        // Now set a NEW feed for B->A with the inverse price, and query A->B back via inversion.
        // We need a different project to avoid the "already exists" check.
        uint256 project2 = 2;
        MockPriceFeed feed2 = new MockPriceFeed(inversePrice, decimals);
        _storeFeed(project2, _unitCurrency, _pricingCurrency, address(feed2));

        uint256 doubleInverse = _prices.pricePerUnitOf(project2, _pricingCurrency, _unitCurrency, decimals);

        // Double-inverse should be approximately equal to original, but may lose precision.
        // This documents the precision loss from compounding inversions.
        assertApproxEqRel(doubleInverse, originalPrice, 0.01e18, "Double inverse should approximate original within 1%");
    }

    // ───────────────────── Feed immutability tests
    // ─────────────────────

    /// @notice Adding a feed for an existing pair should revert.
    function test_feedImmutability_cannotReplace() external {
        MockPriceFeed feed1 = new MockPriceFeed(1000e18, 18);
        MockPriceFeed feed2 = new MockPriceFeed(2000e18, 18);

        // Mock controller for project.
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(this))
        );

        _prices.addPriceFeedFor(PROJECT_ID, _pricingCurrency, _unitCurrency, feed1);

        // Second add for same pair should revert.
        vm.expectRevert(abi.encodeWithSelector(JBPrices.JBPrices_PriceFeedAlreadyExists.selector, feed1));
        _prices.addPriceFeedFor(PROJECT_ID, _pricingCurrency, _unitCurrency, feed2);
    }

    /// @notice Adding A->B should block adding B->A for the same project.
    function test_feedImmutability_inverseBlocksToo() external {
        MockPriceFeed feed1 = new MockPriceFeed(1000e18, 18);
        MockPriceFeed feed2 = new MockPriceFeed(2000e18, 18);

        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(this))
        );

        _prices.addPriceFeedFor(PROJECT_ID, _pricingCurrency, _unitCurrency, feed1);

        // Adding inverse pair should revert.
        vm.expectRevert(abi.encodeWithSelector(JBPrices.JBPrices_PriceFeedAlreadyExists.selector, feed1));
        _prices.addPriceFeedFor(PROJECT_ID, _unitCurrency, _pricingCurrency, feed2);
    }

    // ───────────────────── Default fallback tests
    // ─────────────────────

    /// @notice Project-specific feed takes priority over default.
    function test_defaultFallback_projectFeedTakesPriority() external {
        MockPriceFeed defaultFeed = new MockPriceFeed(1000e18, 18);
        MockPriceFeed projectFeed = new MockPriceFeed(2000e18, 18);

        // Store default feed.
        _storeFeed(DEFAULT_PROJECT_ID, _pricingCurrency, _unitCurrency, address(defaultFeed));
        // Store project feed.
        _storeFeed(PROJECT_ID, _pricingCurrency, _unitCurrency, address(projectFeed));

        uint256 price = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, 18);
        assertEq(price, 2000e18, "Project feed should take priority over default");
    }

    /// @notice Default inverse feed used when no project-specific direct or inverse feed exists.
    function test_defaultFallback_inverseOfDefault() external {
        uint256 decimals = 18;
        // Only store default feed in the inverse direction: unit->pricing.
        MockPriceFeed defaultFeed = new MockPriceFeed(2e18, decimals);
        _storeFeed(DEFAULT_PROJECT_ID, _unitCurrency, _pricingCurrency, address(defaultFeed));

        // Query pricing->unit on a project with no feeds — should fall back to default inverse.
        uint256 price = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, decimals);

        // Expected: mulDiv(10^18, 10^18, 2*10^18) = 5*10^17
        assertEq(price, 5e17, "Should use inverse of default feed");
    }

    // ───────────────────── Same currency
    // ─────────────────────

    /// @notice pricePerUnitOf(X, X, decimals) == 10^decimals.
    function test_sameCurrency_returns1() external view {
        uint256 price18 = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _pricingCurrency, 18);
        assertEq(price18, 1e18, "Same currency at 18 decimals should return 1e18");

        uint256 price6 = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _pricingCurrency, 6);
        assertEq(price6, 1e6, "Same currency at 6 decimals should return 1e6");
    }

    // ───────────────────── Zero currency reverts
    // ─────────────────────

    /// @notice Both zero pricing and zero unit currency should revert on addPriceFeedFor.
    function test_zeroCurrency_reverts() external {
        MockPriceFeed feed = new MockPriceFeed(1000e18, 18);

        vm.prank(_owner);
        vm.expectRevert(JBPrices.JBPrices_ZeroPricingCurrency.selector);
        _prices.addPriceFeedFor(DEFAULT_PROJECT_ID, 0, _unitCurrency, feed);

        vm.prank(_owner);
        vm.expectRevert(JBPrices.JBPrices_ZeroUnitCurrency.selector);
        _prices.addPriceFeedFor(DEFAULT_PROJECT_ID, _pricingCurrency, 0, feed);
    }

    // ───────────────────── BUG HYPOTHESIS: default blocks project-specific
    // ─────────────────────

    /// @notice BUG: Adding a default A->B feed blocks ANY project from adding their own A->B feed.
    /// This is overly restrictive — projects cannot use a different oracle for the same pair.
    /// The check at JBPrices.sol:188-197 checks default feeds BEFORE project feeds.
    function test_addFeedFor_defaultBlocksProjectSpecific() external {
        MockPriceFeed defaultFeed = new MockPriceFeed(1000e18, 18);
        MockPriceFeed projectFeed = new MockPriceFeed(2000e18, 18);

        // Add default feed.
        vm.prank(_owner);
        _prices.addPriceFeedFor(DEFAULT_PROJECT_ID, _pricingCurrency, _unitCurrency, defaultFeed);

        // Now try to add a project-specific feed for the SAME pair.
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(this))
        );

        // BUG CONFIRMED: This reverts because default feed blocks project-specific feeds.
        vm.expectRevert(abi.encodeWithSelector(JBPrices.JBPrices_PriceFeedAlreadyExists.selector, defaultFeed));
        _prices.addPriceFeedFor(PROJECT_ID, _pricingCurrency, _unitCurrency, projectFeed);
    }

    // ───────────────────── Fuzz: valid feeds never overflow
    // ─────────────────────

    /// @notice Fuzz: pricePerUnitOf should never revert for valid feed values.
    function testFuzz_pricePerUnitOf_neverReverts_forValidFeed(uint256 price, uint8 decimals) external {
        // Bound inputs to reasonable ranges.
        decimals = uint8(bound(decimals, 1, 18));
        price = bound(price, 1, type(uint128).max);

        MockPriceFeed feed = new MockPriceFeed(price, decimals);
        _storeFeed(PROJECT_ID, _pricingCurrency, _unitCurrency, address(feed));

        // Should not revert.
        uint256 result = _prices.pricePerUnitOf(PROJECT_ID, _pricingCurrency, _unitCurrency, decimals);
        assertGt(result, 0, "Price should be non-zero for valid feed");
    }
}
