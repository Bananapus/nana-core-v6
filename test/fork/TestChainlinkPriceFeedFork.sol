// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {JBChainlinkV3PriceFeed} from "../../src/JBChainlinkV3PriceFeed.sol";
import {JBPrices} from "../../src/JBPrices.sol";
import {IJBDirectory} from "../../src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "../../src/interfaces/IJBPermissions.sol";
import {IJBPriceFeed} from "../../src/interfaces/IJBPriceFeed.sol";
import {IJBProjects} from "../../src/interfaces/IJBProjects.sol";

/// @notice Fork tests for JBChainlinkV3PriceFeed and JBPrices against live Chainlink oracles on Ethereum mainnet.
contract TestChainlinkPriceFeedFork is Test {
    // Chainlink feed addresses (Ethereum mainnet).
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    // Staleness threshold (1 hour).
    uint256 constant THRESHOLD = 3600;

    // Currency identifiers (arbitrary nonzero values for JBPrices mapping keys).
    uint256 constant CURRENCY_ETH = 1;
    uint256 constant CURRENCY_USD = 2;
    uint256 constant CURRENCY_BTC = 3;

    // Pinned block for reproducibility.
    uint256 constant FORK_BLOCK = 22_000_000;

    JBChainlinkV3PriceFeed ethUsdPriceFeed;
    JBChainlinkV3PriceFeed btcUsdPriceFeed;
    JBPrices prices;
    address owner;

    function setUp() public {
        vm.createSelectFork("ethereum", FORK_BLOCK);

        owner = makeAddr("owner");

        // Deploy price feeds against real Chainlink aggregators.
        ethUsdPriceFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(ETH_USD_FEED), THRESHOLD);
        btcUsdPriceFeed = new JBChainlinkV3PriceFeed(AggregatorV3Interface(BTC_USD_FEED), THRESHOLD);

        // Deploy JBPrices with mock directory/permissions/projects (only price resolution is tested).
        prices = new JBPrices(
            IJBDirectory(makeAddr("directory")),
            IJBPermissions(makeAddr("permissions")),
            IJBProjects(makeAddr("projects")),
            owner,
            address(0)
        );
    }

    // ------------------------------------------------------------------
    // Live feed sanity checks
    // ------------------------------------------------------------------

    /// @notice Verify currentUnitPrice returns a sane ETH/USD price at the pinned block.
    function test_currentUnitPrice_liveEthUsd() public view {
        uint256 price18 = ethUsdPriceFeed.currentUnitPrice(18);

        // ETH price should be between $500 and $50,000.
        assertGt(price18, 500e18, "ETH price too low");
        assertLt(price18, 50_000e18, "ETH price too high");

        // Cross-check against raw latestRoundData.
        (, int256 rawPrice,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        uint256 feedDecimals = AggregatorV3Interface(ETH_USD_FEED).decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 expected18 = uint256(rawPrice) * 10 ** (18 - feedDecimals);
        assertEq(price18, expected18, "Price mismatch vs raw feed");
    }

    // ------------------------------------------------------------------
    // Decimal scaling
    // ------------------------------------------------------------------

    /// @notice Verify correct scaling across 6, 8, 18, and 27 decimals.
    function test_currentUnitPrice_differentDecimals() public view {
        uint256 price6 = ethUsdPriceFeed.currentUnitPrice(6);
        uint256 price8 = ethUsdPriceFeed.currentUnitPrice(8);
        uint256 price18 = ethUsdPriceFeed.currentUnitPrice(18);
        uint256 price27 = ethUsdPriceFeed.currentUnitPrice(27);

        // Raw feed is 8 decimals — price8 should match it exactly.
        (, int256 rawPrice,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price8, uint256(rawPrice), "8-decimal mismatch");

        // 6 decimals = raw / 100 (truncated).
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price6, uint256(rawPrice) / 1e2, "6-decimal mismatch");

        // 18 decimals = raw * 1e10.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price18, uint256(rawPrice) * 1e10, "18-decimal mismatch");

        // 27 decimals = raw * 1e19.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price27, uint256(rawPrice) * 1e19, "27-decimal mismatch");
    }

    // ------------------------------------------------------------------
    // JBPrices integration — direct feed
    // ------------------------------------------------------------------

    /// @notice Register ETH/USD feed and resolve via pricePerUnitOf.
    function test_pricePerUnitOf_directFeed() public {
        vm.prank(owner);
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(ethUsdPriceFeed)));

        uint256 priceFromPrices = prices.pricePerUnitOf(0, CURRENCY_USD, CURRENCY_ETH, 18);
        uint256 priceFromFeed = ethUsdPriceFeed.currentUnitPrice(18);

        assertEq(priceFromPrices, priceFromFeed, "Direct feed mismatch");
    }

    // ------------------------------------------------------------------
    // JBPrices integration — inverse feed
    // ------------------------------------------------------------------

    /// @notice Register ETH/USD feed but query USD/ETH — verify inverse calculation.
    function test_pricePerUnitOf_inverseFeed() public {
        vm.prank(owner);
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(ethUsdPriceFeed)));

        uint256 inversePrice = prices.pricePerUnitOf(0, CURRENCY_ETH, CURRENCY_USD, 18);

        // inverse = (1e18 * 1e18) / ethUsdPrice. For ETH ~$2000, inverse ~0.0005e18 = 5e14.
        // Sane range: $500–$50k → inverse 2e13–2e15.
        assertGt(inversePrice, 2e13, "Inverse price too low");
        assertLt(inversePrice, 2e15, "Inverse price too high");

        // Verify round-trip: price * inverse ≈ 1e18 (within mulDiv rounding).
        uint256 directPrice = ethUsdPriceFeed.currentUnitPrice(18);
        uint256 product = (directPrice * inversePrice) / 1e18;
        // mulDiv truncation can cause up to ~1e4 wei error at these magnitudes.
        assertApproxEqAbs(product, 1e18, 1e4, "Round-trip mismatch");
    }

    // ------------------------------------------------------------------
    // JBPrices — same currency
    // ------------------------------------------------------------------

    /// @notice pricePerUnitOf(X, X, 18) should return 1e18 without any feed.
    function test_pricePerUnitOf_sameCurrency() public view {
        uint256 price = prices.pricePerUnitOf(0, CURRENCY_ETH, CURRENCY_ETH, 18);
        assertEq(price, 1e18, "Same currency should be 1e18");
    }

    // ------------------------------------------------------------------
    // JBPrices — default fallback
    // ------------------------------------------------------------------

    /// @notice Feed registered at projectId=0 should be used when querying projectId=99.
    function test_pricePerUnitOf_defaultFallback() public {
        vm.prank(owner);
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(ethUsdPriceFeed)));

        uint256 defaultPrice = prices.pricePerUnitOf(0, CURRENCY_USD, CURRENCY_ETH, 18);
        uint256 fallbackPrice = prices.pricePerUnitOf(99, CURRENCY_USD, CURRENCY_ETH, 18);

        assertEq(fallbackPrice, defaultPrice, "Fallback should match default");
    }

    // ------------------------------------------------------------------
    // Stale price revert
    // ------------------------------------------------------------------

    /// @notice Warping past the threshold should cause a StalePrice revert.
    function test_stalePriceReverts() public {
        // Snapshot updatedAt from the feed at this block.
        (,,, uint256 updatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        // Warp far enough that the feed's updatedAt + threshold < block.timestamp.
        uint256 warpTo = block.timestamp + 7200;
        vm.warp(warpTo);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector, warpTo, THRESHOLD, updatedAt
            )
        );
        ethUsdPriceFeed.currentUnitPrice(18);
    }

    // ------------------------------------------------------------------
    // Feed immutability
    // ------------------------------------------------------------------

    /// @notice Registering the same currency pair twice should revert.
    function test_feedImmutability() public {
        vm.prank(owner);
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(ethUsdPriceFeed)));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPrices.JBPrices_PriceFeedAlreadyExists.selector, IJBPriceFeed(address(ethUsdPriceFeed))
            )
        );
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(btcUsdPriceFeed)));
    }

    // ------------------------------------------------------------------
    // Multiple feeds
    // ------------------------------------------------------------------

    /// @notice Register both ETH/USD and BTC/USD and verify independent resolution.
    function test_multipleFeeds_ethUsd_btcUsd() public {
        vm.startPrank(owner);
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(ethUsdPriceFeed)));
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_BTC, IJBPriceFeed(address(btcUsdPriceFeed)));
        vm.stopPrank();

        uint256 ethUsd = prices.pricePerUnitOf(0, CURRENCY_USD, CURRENCY_ETH, 18);
        uint256 btcUsd = prices.pricePerUnitOf(0, CURRENCY_USD, CURRENCY_BTC, 18);

        // ETH/USD: $500–$50,000.
        assertGt(ethUsd, 500e18, "ETH/USD too low");
        assertLt(ethUsd, 50_000e18, "ETH/USD too high");

        // BTC/USD: $10,000–$500,000.
        assertGt(btcUsd, 10_000e18, "BTC/USD too low");
        assertLt(btcUsd, 500_000e18, "BTC/USD too high");

        // BTC should be more expensive than ETH.
        assertGt(btcUsd, ethUsd, "BTC should cost more than ETH");
    }

    // ------------------------------------------------------------------
    // Cross-price derivation
    // ------------------------------------------------------------------

    /// @notice Derive ETH/BTC price from ETH/USD and BTC/USD feeds.
    function test_crossPriceDerived() public {
        vm.startPrank(owner);
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_ETH, IJBPriceFeed(address(ethUsdPriceFeed)));
        prices.addPriceFeedFor(0, CURRENCY_USD, CURRENCY_BTC, IJBPriceFeed(address(btcUsdPriceFeed)));
        vm.stopPrank();

        uint256 ethUsd = prices.pricePerUnitOf(0, CURRENCY_USD, CURRENCY_ETH, 18);
        uint256 btcUsd = prices.pricePerUnitOf(0, CURRENCY_USD, CURRENCY_BTC, 18);

        // ETH/BTC = ethUsd / btcUsd (how many BTC per 1 ETH).
        uint256 ethPerBtc = (ethUsd * 1e18) / btcUsd;

        // Should be between 0.01 and 0.1 (at 18 decimals: 1e16–1e17).
        assertGt(ethPerBtc, 1e16, "ETH/BTC ratio too low");
        assertLt(ethPerBtc, 1e17, "ETH/BTC ratio too high");
    }
}
