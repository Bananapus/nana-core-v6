// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBChainlinkV3PriceFeed} from "../../../../src/JBChainlinkV3PriceFeed.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {JBFixedPointNumber} from "../../../../src/libraries/JBFixedPointNumber.sol";

/// @notice Mock Chainlink AggregatorV3Interface for testing.
contract MockAggregator {
    int256 public price;
    uint8 public decimals_;
    uint256 public updatedAt_;
    uint80 public roundId_;

    function setPrice(int256 _price) external {
        price = _price;
    }

    function setDecimals(uint8 _decimals) external {
        decimals_ = _decimals;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt_ = _updatedAt;
    }

    function setRoundId(uint80 _roundId) external {
        roundId_ = _roundId;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (roundId_, price, block.timestamp, updatedAt_, roundId_);
    }
}

/// @notice Tests for JBChainlinkV3PriceFeed.
contract TestPriceFeed_Local is JBTest {
    using JBFixedPointNumber for uint256;

    MockAggregator mockFeed;
    JBChainlinkV3PriceFeed priceFeed;

    uint256 constant THRESHOLD = 1 hours;

    function setUp() external {
        mockFeed = new MockAggregator();
        mockFeed.setDecimals(8);
        mockFeed.setPrice(200_000_000_000); // $2000 with 8 decimals
        mockFeed.setUpdatedAt(block.timestamp);
        mockFeed.setRoundId(1);

        priceFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(address(mockFeed)), THRESHOLD);
    }

    //*********************************************************************//
    // --- Normal Operation --------------------------------------------- //
    //*********************************************************************//

    /// @notice Price is returned correctly with same decimals as feed.
    function test_normalPrice_sameDecimals() external view {
        uint256 price = priceFeed.currentUnitPrice(8);
        assertEq(price, 200_000_000_000, "price should be 2000e8");
    }

    /// @notice Price is adjusted when requesting more decimals than the feed.
    function test_normalPrice_scaleUp() external view {
        uint256 price = priceFeed.currentUnitPrice(18);
        assertEq(price, 2_000_000_000_000_000_000_000, "price should be 2000e18");
    }

    /// @notice Price is adjusted when requesting fewer decimals than the feed.
    function test_normalPrice_scaleDown() external view {
        uint256 price = priceFeed.currentUnitPrice(6);
        assertEq(price, 2_000_000_000, "price should be 2000e6");
    }

    /// @notice Price of 1 (minimum positive) is returned.
    function test_normalPrice_minimumPositive() external {
        mockFeed.setPrice(1);
        uint256 price = priceFeed.currentUnitPrice(8);
        assertEq(price, 1, "minimum positive price should be 1");
    }

    //*********************************************************************//
    // --- Stale Price -------------------------------------------------- //
    //*********************************************************************//

    /// @notice Reverts when price is older than threshold.
    function test_stalePrice_reverts() external {
        // Set updatedAt to a time older than threshold
        mockFeed.setUpdatedAt(block.timestamp - THRESHOLD - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector,
                block.timestamp,
                THRESHOLD,
                block.timestamp - THRESHOLD - 1
            )
        );
        priceFeed.currentUnitPrice(18);
    }

    /// @notice Does not revert when price is exactly at the threshold boundary.
    function test_stalePrice_atBoundary_succeeds() external {
        // Set updatedAt exactly at the threshold
        mockFeed.setUpdatedAt(block.timestamp - THRESHOLD);
        uint256 price = priceFeed.currentUnitPrice(8);
        assertEq(price, 200_000_000_000, "price at boundary should succeed");
    }

    //*********************************************************************//
    // --- Incomplete Round --------------------------------------------- //
    //*********************************************************************//

    /// @notice Reverts when updatedAt is 0 (incomplete round).
    /// @dev Note: the stale check fires first when block.timestamp > THRESHOLD.
    ///      To test the IncompleteRound path, we use a priceFeed with THRESHOLD > block.timestamp.
    function test_incompleteRound_reverts() external {
        // Create a price feed with a huge threshold so stale check passes
        JBChainlinkV3PriceFeed largeThrPriceFeed = new JBChainlinkV3PriceFeed(
            AggregatorV3Interface(address(mockFeed)), type(uint256).max
        );
        mockFeed.setUpdatedAt(0);

        vm.expectRevert(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_IncompleteRound.selector);
        largeThrPriceFeed.currentUnitPrice(18);
    }

    //*********************************************************************//
    // --- Negative / Zero Price ---------------------------------------- //
    //*********************************************************************//

    /// @notice Reverts when price is 0.
    function test_zeroPrice_reverts() external {
        mockFeed.setPrice(0);

        vm.expectRevert(abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, int256(0)));
        priceFeed.currentUnitPrice(18);
    }

    /// @notice Reverts when price is negative.
    function test_negativePrice_reverts() external {
        mockFeed.setPrice(-100);

        vm.expectRevert(
            abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, int256(-100))
        );
        priceFeed.currentUnitPrice(18);
    }

    //*********************************************************************//
    // --- Fuzz Tests --------------------------------------------------- //
    //*********************************************************************//

    /// @notice Decimal adjustment is consistent with JBFixedPointNumber.
    function testFuzz_decimalsAdjustment(uint128 rawPrice, uint8 feedDecimals, uint8 requestedDecimals) external {
        rawPrice = uint128(bound(uint256(rawPrice), 1, type(uint128).max));
        feedDecimals = uint8(bound(uint256(feedDecimals), 0, 18));
        requestedDecimals = uint8(bound(uint256(requestedDecimals), 0, 36));

        MockAggregator fuzzFeed = new MockAggregator();
        fuzzFeed.setDecimals(feedDecimals);
        fuzzFeed.setPrice(int256(uint256(rawPrice)));
        fuzzFeed.setUpdatedAt(block.timestamp);
        fuzzFeed.setRoundId(1);

        JBChainlinkV3PriceFeed fuzzPriceFeed = new JBChainlinkV3PriceFeed(
            AggregatorV3Interface(address(fuzzFeed)), THRESHOLD
        );

        uint256 price = fuzzPriceFeed.currentUnitPrice(requestedDecimals);
        uint256 expected = uint256(rawPrice).adjustDecimals({decimals: feedDecimals, targetDecimals: requestedDecimals});
        assertEq(price, expected, "price should match JBFixedPointNumber.adjustDecimals");
    }

    /// @notice Fresh prices never revert (for valid price ranges).
    function testFuzz_freshPrice_doesNotRevert(uint128 rawPrice) external {
        rawPrice = uint128(bound(uint256(rawPrice), 1, type(uint128).max));

        mockFeed.setPrice(int256(uint256(rawPrice)));
        mockFeed.setUpdatedAt(block.timestamp);

        // Should not revert
        priceFeed.currentUnitPrice(18);
    }

    /// @notice Stale prices always revert.
    function testFuzz_stalePrice_alwaysReverts(uint256 delay) external {
        delay = bound(delay, THRESHOLD + 1, block.timestamp);

        mockFeed.setUpdatedAt(block.timestamp - delay);

        vm.expectRevert();
        priceFeed.currentUnitPrice(18);
    }

    //*********************************************************************//
    // --- Immutable Properties ----------------------------------------- //
    //*********************************************************************//

    /// @notice FEED is set correctly.
    function test_feedIsSet() external view {
        assertEq(address(priceFeed.FEED()), address(mockFeed), "FEED should match mock");
    }

    /// @notice THRESHOLD is set correctly.
    function test_thresholdIsSet() external view {
        assertEq(priceFeed.THRESHOLD(), THRESHOLD, "THRESHOLD should match");
    }
}
