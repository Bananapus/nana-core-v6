// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {JBChainlinkV3PriceFeed} from "./JBChainlinkV3PriceFeed.sol";

/// @notice Extends `JBChainlinkV3PriceFeed` with L2 sequencer uptime checks (for Optimism, Arbitrum, etc.). Reverts if
/// the sequencer is down or has not been back online for at least `GRACE_PERIOD_TIME` seconds — preventing stale
/// prices from being used immediately after an outage.
contract JBChainlinkV3SequencerPriceFeed is JBChainlinkV3PriceFeed {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the sequencer uptime round is invalid (e.g. the uptime contract is not yet initialized).
    error JBChainlinkV3SequencerPriceFeed_InvalidRound(uint256 startedAt);

    /// @notice Thrown when the L2 sequencer is down or has restarted too recently for the grace period to elapse.
    error JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting(
        uint256 timestamp, uint256 gracePeriodTime, uint256 startedAt
    );

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice How long the sequencer must be re-active in order to return a price.
    uint256 public immutable GRACE_PERIOD_TIME;

    /// @notice The Chainlink sequencer feed that prices are reported from.
    AggregatorV2V3Interface public immutable SEQUENCER_FEED;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param feed The Chainlink feed to report prices from.
    /// @param threshold How many seconds old a price update may be.
    /// @param sequencerFeed The Chainlink feed to report sequencer status.
    /// @param gracePeriod How long the sequencer should have been re-active before returning prices.
    constructor(
        AggregatorV3Interface feed,
        uint256 threshold,
        AggregatorV2V3Interface sequencerFeed,
        uint256 gracePeriod
    )
        JBChainlinkV3PriceFeed(feed, threshold)
    {
        GRACE_PERIOD_TIME = gracePeriod;
        SEQUENCER_FEED = sequencerFeed;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Gets the current price (per 1 unit) from the feed.
    /// @param decimals The number of decimals the return value should use.
    /// @return The current unit price from the feed, as a fixed point number with the specified number of decimals.
    function currentUnitPrice(uint256 decimals) public view override returns (uint256) {
        // Fetch sequencer status.
        (, int256 answer, uint256 startedAt,,) = SEQUENCER_FEED.latestRoundData();

        // Check if round is valid to prevent an edge-case where Arbitrum uptime contract is not init.
        if (startedAt == 0) revert JBChainlinkV3SequencerPriceFeed_InvalidRound({startedAt: startedAt});

        // Revert if sequencer has too recently restarted or is currently down.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= GRACE_PERIOD_TIME + startedAt || answer != 0) {
            revert JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting({
                timestamp: block.timestamp, gracePeriodTime: GRACE_PERIOD_TIME, startedAt: startedAt
            });
        }

        return super.currentUnitPrice(decimals);
    }
}
