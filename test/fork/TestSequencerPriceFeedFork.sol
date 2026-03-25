// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {JBChainlinkV3SequencerPriceFeed} from "../../src/JBChainlinkV3SequencerPriceFeed.sol";

/// @notice Fork tests for JBChainlinkV3SequencerPriceFeed against the live Arbitrum sequencer uptime feed and
/// ETH/USD Chainlink oracle.
contract TestSequencerPriceFeedFork is Test {
    // Chainlink feed addresses (Arbitrum mainnet).
    address constant ARB_ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant ARB_SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // Staleness threshold (1 hour).
    uint256 constant THRESHOLD = 3600;

    // Grace period after sequencer restart (1 hour).
    uint256 constant GRACE_PERIOD = 3600;

    // Pinned block for reproducibility (sequencer is up at this block).
    uint256 constant FORK_BLOCK = 300_000_000;

    JBChainlinkV3SequencerPriceFeed feed;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_ARBITRUM_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            // Skip all tests if no Arbitrum RPC is configured.
            return;
        }

        vm.createSelectFork(rpc, FORK_BLOCK);

        feed = new JBChainlinkV3SequencerPriceFeed(
            AggregatorV3Interface(ARB_ETH_USD_FEED),
            THRESHOLD,
            AggregatorV2V3Interface(ARB_SEQUENCER_FEED),
            GRACE_PERIOD
        );
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    modifier skipIfNoRpc() {
        if (address(feed) == address(0)) {
            return;
        }
        _;
    }

    // ------------------------------------------------------------------
    // 1. Normal operation — valid price returned
    // ------------------------------------------------------------------

    /// @notice Under normal conditions (sequencer up, grace period elapsed), currentUnitPrice returns a sane price.
    function test_normalOperation_returnsValidPrice() public view skipIfNoRpc {
        uint256 price18 = feed.currentUnitPrice(18);

        // ETH price should be between $500 and $50,000.
        assertGt(price18, 500e18, "ETH price too low");
        assertLt(price18, 50_000e18, "ETH price too high");

        // Cross-check against raw latestRoundData from the price feed.
        (, int256 rawPrice,,,) = AggregatorV3Interface(ARB_ETH_USD_FEED).latestRoundData();
        uint256 feedDecimals = AggregatorV3Interface(ARB_ETH_USD_FEED).decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 expected18 = uint256(rawPrice) * 10 ** (18 - feedDecimals);
        assertEq(price18, expected18, "Price mismatch vs raw feed");
    }

    // ------------------------------------------------------------------
    // 2. Sequencer down — reverts
    // ------------------------------------------------------------------

    /// @notice When the sequencer feed reports answer=1 (down), currentUnitPrice reverts.
    function test_sequencerDown_reverts() public skipIfNoRpc {
        // Mock the sequencer feed to report answer=1 (down).
        // latestRoundData() selector = 0xfeaf968c
        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(1), // answer = 1 → sequencer down
                block.timestamp - GRACE_PERIOD - 100, // startedAt (irrelevant when answer=1)
                block.timestamp, // updatedAt
                uint80(1) // answeredInRound
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3SequencerPriceFeed.JBChainlinkV3SequencerPriceFeed_SequencerDownOrRestarting.selector,
                block.timestamp,
                GRACE_PERIOD,
                block.timestamp - GRACE_PERIOD - 100
            )
        );
        feed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // 3. Grace period active — reverts
    // ------------------------------------------------------------------

    /// @notice When the sequencer just came back up (within grace period), currentUnitPrice reverts.
    function test_gracePeriodActive_reverts() public skipIfNoRpc {
        // Mock the sequencer feed: answer=0 (up) but startedAt is 1 second ago (within grace period).
        uint256 startedAt = block.timestamp - 1;

        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(0), // answer = 0 → sequencer up
                startedAt, // startedAt = very recent
                block.timestamp, // updatedAt
                uint80(1) // answeredInRound
            )
        );

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

    // ------------------------------------------------------------------
    // 4. Post-grace recovery — succeeds
    // ------------------------------------------------------------------

    /// @notice After the grace period has elapsed, currentUnitPrice succeeds again.
    function test_postGraceRecovery_succeeds() public skipIfNoRpc {
        // Mock the sequencer feed: answer=0 (up), startedAt is well before the grace period ended.
        uint256 startedAt = block.timestamp - GRACE_PERIOD - 100;

        vm.mockCall(
            ARB_SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(0), // answer = 0 → sequencer up
                startedAt, // startedAt = well in the past
                block.timestamp, // updatedAt
                uint80(1) // answeredInRound
            )
        );

        // The price feed itself is still the real Chainlink feed, so this should succeed.
        uint256 price18 = feed.currentUnitPrice(18);

        // Same sanity check: ETH price between $500 and $50,000.
        assertGt(price18, 500e18, "ETH price too low after recovery");
        assertLt(price18, 50_000e18, "ETH price too high after recovery");
    }
}
