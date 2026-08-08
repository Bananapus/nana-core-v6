// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {JBChainlinkV3PriceFeed} from "../../src/JBChainlinkV3PriceFeed.sol";
import {JBRatioPriceFeed} from "../../src/periphery/JBRatioPriceFeed.sol";

/// @notice Fork tests checking a composed `JBRatioPriceFeed` against an independently reported price for the same
/// pair on Ethereum mainnet.
/// @dev Every unit test derives its expectation from the same two legs the contract divides, so an inverted or
/// mis-scaled composition would move both sides of those assertions together and pass. Ethereum mainnet is the only
/// chain carrying a direct Chainlink USDC/ETH aggregator, and that aggregator is a third source the composition never
/// reads. Checking the composition against it is the one assertion available here that does not restate the
/// implementation.
contract TestRatioPriceFeedFork is Test {
    // Chainlink aggregators (Ethereum mainnet).
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC_ETH_FEED = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    address constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Pinned block for reproducibility.
    uint256 constant FORK_BLOCK = 22_000_000;

    // The rounds each aggregator reports at the pinned block, asserted below so the numbers the tolerance was sized
    // against stay visible and a silent change of block cannot go unnoticed.
    int256 constant ETH_USD_ANSWER = 215_153_445_084;
    int256 constant USDC_ETH_ANSWER = 468_170_754_540_348;
    int256 constant USDC_USD_ANSWER = 99_987_000;

    // Staleness threshold. Both USDC-quoted aggregators publish on a 24-hour heartbeat, and the USDC/USD round at the
    // pinned block is ~21 hours old, so an hour-long threshold would reject an entirely current price. Leg liveness is
    // not what these tests are about — the unit suite covers staleness propagation.
    uint256 constant THRESHOLD = 25 hours;

    // How far the composed price may sit from the direct feed. The two paths are separate Chainlink products with
    // separate deviation thresholds and separate heartbeats, so they update at different moments and are expected to
    // disagree by a fraction of a percent. That disagreement is the oracles behaving normally, not a defect. The
    // observed gap at the pinned block is 0.74%, so 2% leaves real headroom while staying far tighter than the ~4.6
    // million-fold error an inverted composition produces. A failure here means the composition is inverted or
    // mis-scaled, not that the two oracles disagree.
    uint256 constant TOLERANCE = 0.02e18;

    JBChainlinkV3PriceFeed ethUsdFeed;
    JBChainlinkV3PriceFeed usdcEthFeed;
    JBChainlinkV3PriceFeed usdcUsdFeed;
    JBRatioPriceFeed ethPerUsdc;

    function setUp() public {
        vm.createSelectFork("ethereum", FORK_BLOCK);

        // Each aggregator goes through the same production adapter, so decimal handling is identical on both the
        // composed and the direct side of the comparison below.
        ethUsdFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(ETH_USD_FEED), THRESHOLD);
        usdcEthFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(USDC_ETH_FEED), THRESHOLD);
        usdcUsdFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(USDC_USD_FEED), THRESHOLD);

        // USD per USDC over USD per ETH, cancelling USD: ETH per USDC.
        ethPerUsdc = new JBRatioPriceFeed(usdcUsdFeed, ethUsdFeed);
    }

    // ------------------------------------------------------------------
    // Pinned block
    // ------------------------------------------------------------------

    /// @notice The three aggregators report the rounds the tolerance below was sized against.
    function test_pinnedBlock_aggregatorAnswers() public view {
        (, int256 ethUsdAnswer,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        (, int256 usdcEthAnswer,,,) = AggregatorV3Interface(USDC_ETH_FEED).latestRoundData();
        (, int256 usdcUsdAnswer,,,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();

        assertEq(ethUsdAnswer, ETH_USD_ANSWER, "ETH/USD answer moved");
        assertEq(usdcEthAnswer, USDC_ETH_ANSWER, "USDC/ETH answer moved");
        assertEq(usdcUsdAnswer, USDC_USD_ANSWER, "USDC/USD answer moved");

        assertEq(AggregatorV3Interface(ETH_USD_FEED).decimals(), 8, "ETH/USD decimals");
        assertEq(AggregatorV3Interface(USDC_ETH_FEED).decimals(), 18, "USDC/ETH decimals");
        assertEq(AggregatorV3Interface(USDC_USD_FEED).decimals(), 8, "USDC/USD decimals");
    }

    // ------------------------------------------------------------------
    // Independent cross-check
    // ------------------------------------------------------------------

    /// @notice The USDC/USD over ETH/USD composition lands on the direct USDC/ETH aggregator's price.
    function test_composedPrice_matchesDirectFeed() public view {
        uint256 composedPrice = ethPerUsdc.currentUnitPrice(18);
        uint256 directPrice = usdcEthFeed.currentUnitPrice(18);

        // The direct aggregator already reports 18 decimals, so the adapter passes its answer through untouched and
        // the comparison is against the raw round rather than a rescaling of it.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(directPrice, uint256(USDC_ETH_ANSWER), "direct feed should pass its answer through");

        assertApproxEqRel(composedPrice, directPrice, TOLERANCE, "composed price diverges from the direct feed");
    }

    /// @notice The composition is oriented as ETH per USDC rather than USDC per ETH.
    /// @dev A tolerance check alone cannot say which way round the quotient is, because inverting it is a change of
    /// many orders of magnitude rather than a few percent. These bounds span ETH anywhere from $100 to $100,000 while
    /// an inverted composition sits above 1e21, five orders outside the upper bound.
    function test_composedPrice_magnitudeRulesOutInversion() public view {
        uint256 composedPrice = ethPerUsdc.currentUnitPrice(18);

        assertGt(composedPrice, 1e13, "ETH per USDC below 0.00001");
        assertLt(composedPrice, 1e16, "ETH per USDC above 0.01, so the quotient is inverted");
    }

    /// @notice On live prices the two orientations sit millions apart, which is what makes the bounds above able to
    /// tell them apart at all.
    function test_composedPrice_orientationsAreOrdersApart() public {
        uint256 usdcPerEth = new JBRatioPriceFeed(ethUsdFeed, usdcUsdFeed).currentUnitPrice(18);

        assertGt(usdcPerEth, ethPerUsdc.currentUnitPrice(18) * 1_000_000, "orientations are not orders apart");
    }
}
