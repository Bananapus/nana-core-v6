// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {Test} from "forge-std/Test.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {JBChainlinkV3PriceFeed} from "../src/JBChainlinkV3PriceFeed.sol";
import {JBChainlinkV3SequencerPriceFeed} from "../src/JBChainlinkV3SequencerPriceFeed.sol";

/// @notice Tests for JBChainlinkV3PriceFeed and JBChainlinkV3SequencerPriceFeed failure scenarios.
/// Covers sequencer down, grace period, stale prices, negative/zero prices, and incomplete rounds.
contract TestL2SequencerPriceFeed_Local is Test {
    // The price feed under test (with sequencer check).
    JBChainlinkV3SequencerPriceFeed private _sequencerFeed;

    // The base price feed (without sequencer check).
    JBChainlinkV3PriceFeed private _baseFeed;

    // Mock addresses for Chainlink aggregators.
    address private _mockPriceFeed = makeAddr("priceFeed");
    address private _mockSequencerFeed = makeAddr("sequencerFeed");

    uint256 private constant _THRESHOLD = 3600; // 1 hour staleness threshold
    uint256 private constant _GRACE_PERIOD = 3600; // 1 hour grace period after restart

    function setUp() public {
        // Warp to a realistic timestamp so subtraction does not underflow.
        vm.warp(100_000);

        vm.label(_mockPriceFeed, "MockPriceFeed");
        vm.label(_mockSequencerFeed, "MockSequencerFeed");

        // Mock the decimals() call on the price feed aggregator.
        vm.mockCall(
            _mockPriceFeed, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8))
        );

        _baseFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(_mockPriceFeed), _THRESHOLD);

        _sequencerFeed = new JBChainlinkV3SequencerPriceFeed(
            AggregatorV3Interface(_mockPriceFeed),
            _THRESHOLD,
            AggregatorV2V3Interface(_mockSequencerFeed),
            _GRACE_PERIOD
        );
    }

    // -- Helper to mock a healthy price feed response --
    function _mockHealthyPrice(int256 price, uint256 updatedAt) internal {
        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, block.timestamp, updatedAt, uint80(1))
        );
    }

    // -- Helper to mock sequencer feed response --
    function _mockSequencer(int256 answer, uint256 startedAt) internal {
        vm.mockCall(
            _mockSequencerFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), answer, startedAt, block.timestamp, uint80(1))
        );
    }

    /// @notice Sequencer is down (answer=1): should revert.
    function test_revertsWhenSequencerDown() public {
        // answer=1 means sequencer is down.
        // startedAt is well in the past (long enough for grace period).
        _mockSequencer(int256(1), block.timestamp - _GRACE_PERIOD - 100);
        _mockHealthyPrice(2000e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting.selector,
                block.timestamp,
                _GRACE_PERIOD,
                block.timestamp - _GRACE_PERIOD - 100
            )
        );
        _sequencerFeed.currentUnitPrice(18);
    }

    /// @notice Sequencer just restarted and still within grace period: should revert.
    function test_revertsWhenWithinGracePeriod() public {
        // Sequencer is up (answer=0), but restarted very recently.
        uint256 restartedAt = block.timestamp - _GRACE_PERIOD / 2; // half the grace period ago
        _mockSequencer(int256(0), restartedAt);
        _mockHealthyPrice(2000e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting.selector,
                block.timestamp,
                _GRACE_PERIOD,
                restartedAt
            )
        );
        _sequencerFeed.currentUnitPrice(18);
    }

    /// @notice Sequencer feed returns startedAt=0 (invalid round): should revert.
    function test_revertsWhenSequencerRoundInvalid() public {
        _mockSequencer(int256(0), 0);
        _mockHealthyPrice(2000e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_InvalidRound.selector
            )
        );
        _sequencerFeed.currentUnitPrice(18);
    }

    /// @notice After grace period passes, sequencer feed works normally.
    function test_worksAfterGracePeriodPasses() public {
        // Sequencer is up (answer=0), restarted long enough ago.
        uint256 restartedAt = block.timestamp - _GRACE_PERIOD - 1;
        _mockSequencer(int256(0), restartedAt);
        _mockHealthyPrice(2000e8, block.timestamp);

        uint256 price = _sequencerFeed.currentUnitPrice(18);
        // 2000e8 with 8 decimals -> adjusted to 18 decimals: 2000e18.
        assertEq(price, 2000e18, "price should be 2000 with 18 decimals");
    }

    /// @notice Stale price beyond threshold: should revert (base feed behavior).
    function test_revertsOnStalePrice() public {
        uint256 staleUpdatedAt = block.timestamp - _THRESHOLD - 1;

        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, staleUpdatedAt, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector,
                block.timestamp,
                _THRESHOLD,
                staleUpdatedAt
            )
        );
        _baseFeed.currentUnitPrice(18);
    }

    /// @notice Stale price on sequencer feed (sequencer healthy, price stale): should revert.
    function test_sequencerFeed_revertsOnStalePrice() public {
        uint256 restartedAt = block.timestamp - _GRACE_PERIOD - 1;
        _mockSequencer(int256(0), restartedAt);

        uint256 staleUpdatedAt = block.timestamp - _THRESHOLD - 1;
        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, staleUpdatedAt, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector,
                block.timestamp,
                _THRESHOLD,
                staleUpdatedAt
            )
        );
        _sequencerFeed.currentUnitPrice(18);
    }

    /// @notice Negative price: should revert.
    function test_revertsOnNegativePrice() public {
        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(-100), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, int256(-100))
        );
        _baseFeed.currentUnitPrice(18);
    }

    /// @notice Fuzz: any negative price should revert.
    function testFuzz_revertsOnAnyNegativePrice(int256 _price) public {
        vm.assume(_price < 0);

        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _price, block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, _price)
        );
        _baseFeed.currentUnitPrice(18);
    }

    /// @notice Zero price: should revert (price <= 0 check).
    function test_revertsOnZeroPrice() public {
        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, int256(0))
        );
        _baseFeed.currentUnitPrice(18);
    }

    /// @notice Incomplete round (updatedAt=0): should revert.
    function test_revertsOnIncompleteRound() public {
        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, uint256(0), uint80(1))
        );

        vm.expectRevert(abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_IncompleteRound.selector));
        _baseFeed.currentUnitPrice(18);
    }

    /// @notice Incomplete round on sequencer feed path: should revert.
    function test_sequencerFeed_revertsOnIncompleteRound() public {
        uint256 restartedAt = block.timestamp - _GRACE_PERIOD - 1;
        _mockSequencer(int256(0), restartedAt);

        // updatedAt = 0 means incomplete round.
        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, uint256(0), uint80(1))
        );

        vm.expectRevert(abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_IncompleteRound.selector));
        _sequencerFeed.currentUnitPrice(18);
    }

    /// @notice Price at exactly the threshold boundary: should succeed.
    function test_priceAtExactThresholdBoundary() public {
        // updatedAt = block.timestamp - THRESHOLD, so block.timestamp == THRESHOLD + updatedAt.
        // The condition is block.timestamp > THRESHOLD + updatedAt, so this should NOT revert.
        uint256 updatedAt = block.timestamp - _THRESHOLD;

        vm.mockCall(
            _mockPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1500e8), block.timestamp, updatedAt, uint80(1))
        );

        uint256 price = _baseFeed.currentUnitPrice(18);
        assertEq(price, 1500e18, "price at exact threshold boundary should succeed");
    }

    /// @notice Grace period at exact boundary: sequencer restarted exactly grace period ago should still revert.
    function test_gracePeriodExactBoundary() public {
        // startedAt = block.timestamp - GRACE_PERIOD.
        // The condition is block.timestamp <= GRACE_PERIOD_TIME + startedAt,
        // which is block.timestamp <= block.timestamp, which is true. So should revert.
        uint256 startedAt = block.timestamp - _GRACE_PERIOD;
        _mockSequencer(int256(0), startedAt);
        _mockHealthyPrice(2000e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting.selector,
                block.timestamp,
                _GRACE_PERIOD,
                startedAt
            )
        );
        _sequencerFeed.currentUnitPrice(18);
    }

    /// @notice Decimal adjustment: price with fewer decimals scaled up correctly.
    function test_decimalScaling() public {
        _mockHealthyPrice(1e8, block.timestamp); // 1.00000000 with 8 decimals

        uint256 price18 = _baseFeed.currentUnitPrice(18);
        assertEq(price18, 1e18, "1e8 at 8 decimals should scale to 1e18 at 18 decimals");

        uint256 price8 = _baseFeed.currentUnitPrice(8);
        assertEq(price8, 1e8, "1e8 at 8 decimals should stay 1e8 at 8 decimals");

        uint256 price6 = _baseFeed.currentUnitPrice(6);
        assertEq(price6, 1e6, "1e8 at 8 decimals should scale to 1e6 at 6 decimals");
    }
}
