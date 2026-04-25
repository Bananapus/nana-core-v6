// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";

import {JBChainlinkV3PriceFeed} from "../../src/JBChainlinkV3PriceFeed.sol";
import {JBChainlinkV3SequencerPriceFeed} from "../../src/JBChainlinkV3SequencerPriceFeed.sol";

/// @notice Fork tests for Chainlink price feed edge cases: negative prices, zero prices, incomplete rounds,
///         and combined sequencer+staleness failures. Uses vm.mockCall over real mainnet feeds to simulate
///         conditions that don't occur naturally at the pinned block.
contract TestChainlinkEdgeCasesFork is Test {
    // Chainlink feed addresses (Ethereum mainnet).
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Staleness threshold (1 hour).
    uint256 constant THRESHOLD = 3600;

    // Pinned block for reproducibility.
    uint256 constant FORK_BLOCK = 22_000_000;

    JBChainlinkV3PriceFeed feed;

    function setUp() public {
        vm.createSelectFork("ethereum", FORK_BLOCK);
        feed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(ETH_USD_FEED), THRESHOLD);
    }

    // ------------------------------------------------------------------
    // Negative price — reverts with NegativePrice
    // ------------------------------------------------------------------

    /// @notice A feed returning a negative price should revert.
    function test_negativePrice_reverts() public {
        (,,, uint256 realUpdatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        // Mock the feed to return a negative price with otherwise valid data.
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(-100), // price = negative
                block.timestamp, // startedAt
                realUpdatedAt, // updatedAt (valid, within threshold)
                uint80(1) // answeredInRound == roundId
            )
        );

        vm.expectRevert(abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, -100));
        feed.currentUnitPrice(18);

        // Verify the real feed still works after clearing the mock.
        vm.clearMockedCalls();
        uint256 price = feed.currentUnitPrice(18);
        assertGt(price, 0, "real feed should work after clearing mock");
    }

    // ------------------------------------------------------------------
    // Zero price — reverts with NegativePrice (price <= 0)
    // ------------------------------------------------------------------

    /// @notice A feed returning zero price should revert (NegativePrice covers <= 0).
    function test_zeroPrice_reverts() public {
        (,, , uint256 realUpdatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp, realUpdatedAt, uint80(1))
        );

        vm.expectRevert(abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, 0));
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Incomplete round — updatedAt == 0
    // ------------------------------------------------------------------

    /// @notice A feed returning updatedAt=0 indicates an incomplete round and should revert.
    function test_incompleteRound_updatedAtZero_reverts() public {
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(5), // roundId
                int256(2000e8), // price (valid)
                block.timestamp, // startedAt
                uint256(0), // updatedAt = 0 → incomplete
                uint80(5) // answeredInRound == roundId
            )
        );

        vm.expectRevert(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_IncompleteRound.selector);
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Incomplete round — answeredInRound < roundId
    // ------------------------------------------------------------------

    /// @notice answeredInRound lagging behind roundId indicates an incomplete round.
    function test_incompleteRound_answeredInRoundLag_reverts() public {
        (,,, uint256 realUpdatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(10), // roundId
                int256(2000e8), // price (valid)
                block.timestamp, // startedAt
                realUpdatedAt, // updatedAt (valid)
                uint80(9) // answeredInRound < roundId → incomplete
            )
        );

        vm.expectRevert(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_IncompleteRound.selector);
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Stale price boundary — exactly at threshold succeeds
    // ------------------------------------------------------------------

    /// @notice Price updated exactly THRESHOLD seconds ago should still be valid.
    function test_staleBoundary_exactThreshold_succeeds() public {
        uint256 updatedAt = block.timestamp - THRESHOLD;

        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, updatedAt, uint80(1))
        );

        // block.timestamp == THRESHOLD + updatedAt, so the > check passes (not stale).
        uint256 price = feed.currentUnitPrice(18);
        assertEq(price, 2000e18, "price should be valid at exact boundary");
    }

    /// @notice Price updated THRESHOLD+1 seconds ago should revert as stale.
    function test_staleBoundary_oneSecondPast_reverts() public {
        uint256 updatedAt = block.timestamp - THRESHOLD - 1;

        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, updatedAt, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector, block.timestamp, THRESHOLD, updatedAt
            )
        );
        feed.currentUnitPrice(18);
    }
}

/// @notice Fork tests for combined sequencer + price feed edge cases on Arbitrum.
///         Covers sequencer down + price stale simultaneously, grace period exact boundary,
///         and invalid sequencer round (startedAt=0).
contract TestSequencerEdgeCasesFork is Test {
    // Chainlink feed addresses (Arbitrum mainnet).
    address constant ARB_ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant ARB_SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    uint256 constant THRESHOLD = 3600;
    uint256 constant GRACE_PERIOD = 3600;
    uint256 constant FORK_BLOCK = 300_000_000;

    JBChainlinkV3SequencerPriceFeed feed;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_ARBITRUM_MAINNET", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc, FORK_BLOCK);

        feed = new JBChainlinkV3SequencerPriceFeed(
            AggregatorV3Interface(ARB_ETH_USD_FEED),
            THRESHOLD,
            AggregatorV2V3Interface(ARB_SEQUENCER_FEED),
            GRACE_PERIOD
        );
    }

    modifier skipIfNoRpc() {
        if (address(feed) == address(0)) return;
        _;
    }

    // ------------------------------------------------------------------
    // Sequencer down + price stale simultaneously
    // ------------------------------------------------------------------

    /// @notice When sequencer is down AND price is stale, the sequencer check should revert first
    ///         (sequencer is checked before price staleness).
    function test_sequencerDown_andPriceStale_revertsSequencer() public skipIfNoRpc {
        // Mock sequencer as down.
        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp - 7200, block.timestamp, uint80(1))
        );

        // Also mock price as stale (updatedAt far in the past).
        vm.mockCall(
            ARB_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, block.timestamp - 7200, uint80(1))
        );

        // Should revert with sequencer error, not stale price error.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting.selector,
                block.timestamp,
                GRACE_PERIOD,
                block.timestamp - 7200
            )
        );
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Sequencer up, past grace period, but price is stale
    // ------------------------------------------------------------------

    /// @notice Sequencer healthy but price feed stale should revert with StalePrice.
    function test_sequencerUp_priceFeedStale_revertsStale() public skipIfNoRpc {
        // Mock sequencer as healthy (up, past grace period).
        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp - GRACE_PERIOD - 100, block.timestamp, uint80(1))
        );

        // Mock price as stale.
        uint256 staleUpdatedAt = block.timestamp - THRESHOLD - 1;
        vm.mockCall(
            ARB_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), block.timestamp, staleUpdatedAt, uint80(1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector,
                block.timestamp,
                THRESHOLD,
                staleUpdatedAt
            )
        );
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Invalid sequencer round (startedAt == 0)
    // ------------------------------------------------------------------

    /// @notice Sequencer feed returning startedAt=0 indicates an uninitialized contract.
    function test_sequencerInvalidRound_startedAtZero_reverts() public skipIfNoRpc {
        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1),
                int256(0), // answer=0 (up)
                uint256(0), // startedAt=0 → invalid
                block.timestamp,
                uint80(1)
            )
        );

        vm.expectRevert(JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_InvalidRound.selector);
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Grace period exact boundary
    // ------------------------------------------------------------------

    /// @notice At exactly block.timestamp == GRACE_PERIOD + startedAt, the <= check still reverts.
    function test_gracePeriod_exactBoundary_reverts() public skipIfNoRpc {
        uint256 startedAt = block.timestamp - GRACE_PERIOD;

        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), startedAt, block.timestamp, uint80(1))
        );

        // block.timestamp <= GRACE_PERIOD_TIME + startedAt → block.timestamp <= block.timestamp → true → reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting.selector,
                block.timestamp,
                GRACE_PERIOD,
                startedAt
            )
        );
        feed.currentUnitPrice(18);
    }

    /// @notice One second past grace period boundary should succeed.
    function test_gracePeriod_oneSecondPast_succeeds() public skipIfNoRpc {
        uint256 startedAt = block.timestamp - GRACE_PERIOD - 1;

        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), startedAt, block.timestamp, uint80(1))
        );

        // Sequencer healthy, grace period elapsed → delegates to price feed.
        uint256 price = feed.currentUnitPrice(18);
        assertGt(price, 500e18, "ETH price too low");
        assertLt(price, 50_000e18, "ETH price too high");
    }

    // ------------------------------------------------------------------
    // Sequencer up, price negative
    // ------------------------------------------------------------------

    /// @notice Sequencer healthy but price feed returns negative → NegativePrice error.
    function test_sequencerUp_priceNegative_revertsNegativePrice() public skipIfNoRpc {
        // Mock sequencer as healthy.
        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp - GRACE_PERIOD - 100, block.timestamp, uint80(1))
        );

        // Mock price as negative.
        vm.mockCall(
            ARB_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(-500e8), block.timestamp, block.timestamp, uint80(1))
        );
        // Also mock decimals since the parent calls it.
        vm.mockCall(ARB_ETH_USD_FEED, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8)));

        vm.expectRevert(
            abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, -500e8)
        );
        feed.currentUnitPrice(18);
    }
}
