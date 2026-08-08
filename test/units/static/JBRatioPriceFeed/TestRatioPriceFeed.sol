// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {JBTest} from "../../../helpers/JBTest.sol";
import {JBChainlinkV3PriceFeed} from "../../../../src/JBChainlinkV3PriceFeed.sol";
import {JBPrices} from "../../../../src/JBPrices.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBPriceFeed} from "../../../../src/interfaces/IJBPriceFeed.sol";
import {IJBProjects} from "../../../../src/interfaces/IJBProjects.sol";
import {JBCurrencyIds} from "../../../../src/libraries/JBCurrencyIds.sol";
import {JBRatioPriceFeed} from "../../../../src/periphery/JBRatioPriceFeed.sol";
import {MockPriceFeed} from "../../../mock/MockPriceFeed.sol";

/// @notice A Chainlink aggregator whose reported round can be set field by field.
contract MockRatioAggregator {
    uint8 internal _decimals;
    int256 internal _price;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 price_) {
        _decimals = decimals_;
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (uint80(1), _price, block.timestamp, _updatedAt, uint80(1));
    }

    function setPrice(int256 price_) external {
        _price = price_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }
}

/// @notice Tests for `JBRatioPriceFeed`.
/// @dev The legs are real `JBChainlinkV3PriceFeed` instances over mock aggregators so the composition is exercised
/// end to end, including each leg's own decimal adjustment.
contract TestRatioPriceFeed_Local is JBTest {
    /// @notice How many seconds old a leg's price may be.
    uint256 internal constant _THRESHOLD = 1 hours;

    /// @notice The ETH/USD aggregator, reporting `2000` USD per ETH in 8 decimals.
    MockRatioAggregator internal _ethUsdAggregator;

    /// @notice The USDC/USD aggregator, reporting `1` USD per USDC in 8 decimals.
    MockRatioAggregator internal _usdcUsdAggregator;

    /// @notice The ETH/USD leg.
    JBChainlinkV3PriceFeed internal _ethUsdFeed;

    /// @notice The USDC/USD leg.
    JBChainlinkV3PriceFeed internal _usdcUsdFeed;

    /// @notice USDC/USD over ETH/USD, i.e. ETH per USDC.
    JBRatioPriceFeed internal _ethPerUsdc;

    function setUp() external {
        // Start well past the staleness threshold so a stale `updatedAt` can be expressed without underflowing.
        vm.warp(_THRESHOLD + 1 days);

        _usdcUsdAggregator = new MockRatioAggregator({decimals_: 8, price_: 100_000_000});
        _ethUsdAggregator = new MockRatioAggregator({decimals_: 8, price_: 200_000_000_000});

        _usdcUsdFeed = new JBChainlinkV3PriceFeed({
            feed: AggregatorV3Interface(address(_usdcUsdAggregator)), threshold: _THRESHOLD
        });
        _ethUsdFeed = new JBChainlinkV3PriceFeed({
            feed: AggregatorV3Interface(address(_ethUsdAggregator)), threshold: _THRESHOLD
        });

        _ethPerUsdc = new JBRatioPriceFeed({numerator: _usdcUsdFeed, denominator: _ethUsdFeed});
    }

    //*********************************************************************//
    // --- Construction -------------------------------------------------- //
    //*********************************************************************//

    /// @notice The legs are stored in the order they were passed.
    function test_constructor_storesLegs() external view {
        assertEq(address(_ethPerUsdc.NUMERATOR()), address(_usdcUsdFeed), "numerator should be the USDC/USD leg");
        assertEq(address(_ethPerUsdc.DENOMINATOR()), address(_ethUsdFeed), "denominator should be the ETH/USD leg");
    }

    /// @notice A zero-address numerator is rejected.
    function test_constructor_revertsOnZeroNumerator() external {
        vm.expectRevert(JBRatioPriceFeed.JBRatioPriceFeed_ZeroNumerator.selector);
        new JBRatioPriceFeed({numerator: IJBPriceFeed(address(0)), denominator: _ethUsdFeed});
    }

    /// @notice A zero-address denominator is rejected.
    function test_constructor_revertsOnZeroDenominator() external {
        vm.expectRevert(JBRatioPriceFeed.JBRatioPriceFeed_ZeroDenominator.selector);
        new JBRatioPriceFeed({numerator: _usdcUsdFeed, denominator: IJBPriceFeed(address(0))});
    }

    /// @notice Both legs zero is rejected on the numerator, which is checked first.
    function test_constructor_revertsOnBothZero() external {
        vm.expectRevert(JBRatioPriceFeed.JBRatioPriceFeed_ZeroNumerator.selector);
        new JBRatioPriceFeed({numerator: IJBPriceFeed(address(0)), denominator: IJBPriceFeed(address(0))});
    }

    //*********************************************************************//
    // --- Happy path ---------------------------------------------------- //
    //*********************************************************************//

    /// @notice At 18 decimals, `1 USD/USDC` over `2000 USD/ETH` is `0.0005` ETH per USDC.
    function test_currentUnitPrice_at18Decimals() external view {
        assertEq(_ethPerUsdc.currentUnitPrice(18), 500_000_000_000_000, "0.0005e18 ETH per USDC");
    }

    /// @notice The same ratio expressed in 6 decimals is `0.000500` -> `500`.
    function test_currentUnitPrice_at6Decimals() external view {
        assertEq(_ethPerUsdc.currentUnitPrice(6), 500, "0.0005e6 ETH per USDC");
    }

    /// @notice The same ratio expressed in 0 decimals floors to zero, since it is far below one whole ETH.
    function test_currentUnitPrice_at0Decimals() external view {
        assertEq(_ethPerUsdc.currentUnitPrice(0), 0, "0.0005 floors to 0 whole ETH");
    }

    /// @notice Swapping the legs prices the opposite direction: USDC per ETH.
    function test_currentUnitPrice_reversedLegsPriceTheInverse() external {
        JBRatioPriceFeed usdcPerEth = new JBRatioPriceFeed({numerator: _ethUsdFeed, denominator: _usdcUsdFeed});

        assertEq(usdcPerEth.currentUnitPrice(6), 2_000_000_000, "2000e6 USDC per ETH");
        assertEq(usdcPerEth.currentUnitPrice(0), 2000, "2000 whole USDC per ETH");
    }

    /// @notice Legs reporting in different decimals compose to the same ratio, since each leg normalizes itself.
    function test_currentUnitPrice_legDecimalsDoNotMatter() external {
        // An 18-decimal USDC/USD aggregator reporting the same `1` USD per USDC.
        MockRatioAggregator wideAggregator = new MockRatioAggregator({decimals_: 18, price_: 1e18});
        JBChainlinkV3PriceFeed wideFeed =
            new JBChainlinkV3PriceFeed({feed: AggregatorV3Interface(address(wideAggregator)), threshold: _THRESHOLD});

        JBRatioPriceFeed wideRatio = new JBRatioPriceFeed({numerator: wideFeed, denominator: _ethUsdFeed});

        assertEq(wideRatio.currentUnitPrice(18), 500_000_000_000_000, "0.0005e18 regardless of leg decimals");
    }

    /// @notice The numerator leg is quoted with 18 decimals of headroom and the denominator leg at 18 decimals.
    /// @dev This is the contract that makes the quotient land on the requested precision.
    function test_currentUnitPrice_quotesLegsWithHeadroom() external {
        vm.expectCall(address(_usdcUsdFeed), abi.encodeCall(IJBPriceFeed.currentUnitPrice, (uint256(24))));
        vm.expectCall(address(_ethUsdFeed), abi.encodeCall(IJBPriceFeed.currentUnitPrice, (uint256(18))));

        _ethPerUsdc.currentUnitPrice(6);
    }

    //*********************************************************************//
    // --- Not pegged ---------------------------------------------------- //
    //*********************************************************************//

    /// @notice A depegged numerator moves the output proportionally, proving the result tracks the feed rather than
    /// assuming a peg.
    function test_currentUnitPrice_depeggedNumeratorMovesOutput() external {
        // USDC trading at $0.95.
        _usdcUsdAggregator.setPrice(95_000_000);

        // 0.95 / 2000 = 0.000475.
        assertEq(_ethPerUsdc.currentUnitPrice(18), 475_000_000_000_000, "0.000475e18 ETH per USDC");
        assertEq(_ethPerUsdc.currentUnitPrice(6), 475, "0.000475e6 ETH per USDC");
    }

    /// @notice A moving denominator moves the output too.
    function test_currentUnitPrice_movingDenominatorMovesOutput() external {
        // ETH at $4000 halves the ETH price of a USDC.
        _ethUsdAggregator.setPrice(400_000_000_000);

        assertEq(_ethPerUsdc.currentUnitPrice(18), 250_000_000_000_000, "0.00025e18 ETH per USDC");
    }

    //*********************************************************************//
    // --- Precision and rounding ---------------------------------------- //
    //*********************************************************************//

    /// @notice A non-terminating ratio floors at the requested precision.
    function test_currentUnitPrice_floorsNonTerminatingRatio() external {
        // ETH at $3000 makes the ratio 1/3000 = 0.000333...
        _ethUsdAggregator.setPrice(300_000_000_000);

        assertEq(_ethPerUsdc.currentUnitPrice(18), 333_333_333_333_333, "0.000333333333333333e18, floored");
        assertEq(_ethPerUsdc.currentUnitPrice(6), 333, "0.000333e6, floored");
    }

    /// @notice The headroom keeps a sub-unit denominator usable at zero decimals.
    /// @dev Flooring each leg to the requested precision first would floor a `0.5` denominator to `0` and divide by
    /// zero. Quoting both legs against the headroom scale instead yields the true ratio.
    function test_currentUnitPrice_subUnitDenominatorAtZeroDecimals() external {
        // A denominator asset worth $0.50.
        MockRatioAggregator halfDollarAggregator = new MockRatioAggregator({decimals_: 8, price_: 50_000_000});
        JBChainlinkV3PriceFeed halfDollarFeed = new JBChainlinkV3PriceFeed({
            feed: AggregatorV3Interface(address(halfDollarAggregator)), threshold: _THRESHOLD
        });

        JBRatioPriceFeed ratio = new JBRatioPriceFeed({numerator: _usdcUsdFeed, denominator: halfDollarFeed});

        // 1.00 / 0.50 = 2.
        assertEq(ratio.currentUnitPrice(0), 2, "1 USDC buys 2 whole units");

        // 1.25 / 0.50 = 2.5, floored to 2.
        _usdcUsdAggregator.setPrice(125_000_000);
        assertEq(ratio.currentUnitPrice(0), 2, "2.5 floors to 2");
        assertEq(ratio.currentUnitPrice(18), 2_500_000_000_000_000_000, "2.5e18 at full precision");
    }

    /// @notice A ratio below one unit of the requested precision floors to zero rather than reverting, which
    /// `JBPrices` reads as an unavailable feed.
    function test_currentUnitPrice_belowPrecisionFloorsToZero() external view {
        // 0.0005 needs at least 4 decimals to be representable.
        assertEq(_ethPerUsdc.currentUnitPrice(3), 0, "below the representable floor");
        assertEq(_ethPerUsdc.currentUnitPrice(4), 5, "0.0005e4 == 5");
    }

    /// @notice For any leg prices, the result is the floor of the exact quotient at the requested precision.
    /// @dev Asserted through the defining inequality of a floored quotient rather than by recomputing the formula.
    function testFuzz_currentUnitPrice_isFlooredQuotient(
        uint64 numeratorRaw,
        uint64 denominatorRaw,
        uint8 decimals
    )
        external
    {
        numeratorRaw = uint64(bound(uint256(numeratorRaw), 1, type(uint64).max));
        denominatorRaw = uint64(bound(uint256(denominatorRaw), 1, type(uint64).max));
        decimals = uint8(bound(uint256(decimals), 0, 24));

        _usdcUsdAggregator.setPrice(int256(uint256(numeratorRaw)));
        _ethUsdAggregator.setPrice(int256(uint256(denominatorRaw)));

        uint256 result = _ethPerUsdc.currentUnitPrice(decimals);

        // The scaled legs the contract divides, read straight from the legs themselves.
        uint256 scaledNumerator = _usdcUsdFeed.currentUnitPrice(uint256(decimals) + 18);
        uint256 scaledDenominator = _ethUsdFeed.currentUnitPrice(18);

        assertLe(result * scaledDenominator, scaledNumerator, "result must not exceed the exact quotient");
        assertGt((result + 1) * scaledDenominator, scaledNumerator, "result must be the largest such integer");
    }

    //*********************************************************************//
    // --- Zero denominator ---------------------------------------------- //
    //*********************************************************************//

    /// @notice A denominator leg reporting zero reverts instead of returning a free price.
    function test_currentUnitPrice_revertsOnZeroDenominatorPrice() external {
        // A leg that answers, but with no usable price.
        IJBPriceFeed zeroFeed = new MockPriceFeed(0, 18);

        JBRatioPriceFeed ratio = new JBRatioPriceFeed({numerator: _usdcUsdFeed, denominator: zeroFeed});

        vm.expectRevert(JBRatioPriceFeed.JBRatioPriceFeed_ZeroDenominatorPrice.selector);
        ratio.currentUnitPrice(18);
    }

    /// @notice A numerator leg reporting zero yields zero rather than reverting, which reads as an unavailable feed.
    function test_currentUnitPrice_zeroNumeratorPriceReturnsZero() external {
        IJBPriceFeed zeroFeed = new MockPriceFeed(0, 18);

        JBRatioPriceFeed ratio = new JBRatioPriceFeed({numerator: zeroFeed, denominator: _ethUsdFeed});

        assertEq(ratio.currentUnitPrice(18), 0, "a zero numerator prices at zero");
    }

    //*********************************************************************//
    // --- Leg failures propagate ---------------------------------------- //
    //*********************************************************************//

    /// @notice A stale numerator leg reverts through this contract uncaught.
    function test_currentUnitPrice_staleNumeratorLegPropagates() external {
        uint256 staleAt = block.timestamp - _THRESHOLD - 1;
        _usdcUsdAggregator.setUpdatedAt(staleAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector, block.timestamp, _THRESHOLD, staleAt
            )
        );
        _ethPerUsdc.currentUnitPrice(18);
    }

    /// @notice A stale denominator leg reverts through this contract uncaught.
    function test_currentUnitPrice_staleDenominatorLegPropagates() external {
        uint256 staleAt = block.timestamp - _THRESHOLD - 1;
        _ethUsdAggregator.setUpdatedAt(staleAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_StalePrice.selector, block.timestamp, _THRESHOLD, staleAt
            )
        );
        _ethPerUsdc.currentUnitPrice(18);
    }

    /// @notice A leg reporting a non-positive price reverts through this contract uncaught.
    function test_currentUnitPrice_negativeLegPricePropagates() external {
        _ethUsdAggregator.setPrice(-1);

        vm.expectRevert(
            abi.encodeWithSelector(JBChainlinkV3PriceFeed.JBChainlinkV3PriceFeed_NegativePrice.selector, int256(-1))
        );
        _ethPerUsdc.currentUnitPrice(18);
    }

    //*********************************************************************//
    // --- Resolution through JBPrices ----------------------------------- //
    //*********************************************************************//

    /// @notice A token-keyed accounting currency resolves against ETH once the composed feed is registered.
    /// @dev `pricePerUnitOf` only tries one direct feed or one inverted feed, so the `{ETH, usdc}` pair has no route
    /// from the `{USD, usdc}` and `{USD, ETH}` defaults alone. Registering the composition supplies that route.
    function test_pricePerUnitOf_resolvesTokenKeyedPairAgainstEth() external {
        address owner = makeAddr("owner");
        uint256 usdcCurrency = uint32(uint160(makeAddr("usdc")));

        JBPrices prices = new JBPrices({
            directory: IJBDirectory(makeAddr("directory")),
            permissions: IJBPermissions(makeAddr("permissions")),
            projects: IJBProjects(makeAddr("projects")),
            owner: owner,
            trustedForwarder: address(0)
        });

        // Without the composed feed there is no path between a token-keyed USDC context and ETH.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPrices.JBPrices_PriceFeedNotFound.selector, uint256(1), uint256(JBCurrencyIds.ETH), usdcCurrency
            )
        );
        prices.pricePerUnitOf({
            projectId: 1, pricingCurrency: JBCurrencyIds.ETH, unitCurrency: usdcCurrency, decimals: 18
        });

        vm.prank(owner);
        prices.addPriceFeedFor({
            projectId: 0, pricingCurrency: JBCurrencyIds.ETH, unitCurrency: usdcCurrency, feed: _ethPerUsdc
        });

        assertEq(
            prices.pricePerUnitOf({
                projectId: 1, pricingCurrency: JBCurrencyIds.ETH, unitCurrency: usdcCurrency, decimals: 18
            }),
            500_000_000_000_000,
            "0.0005e18 ETH per USDC through JBPrices"
        );
    }
}
