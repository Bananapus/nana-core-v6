// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "../interfaces/IJBPriceFeed.sol";

/// @notice A price feed that composes two other price feeds into their quotient, pricing a pair that neither leg can
/// price on its own. `JBPrices` only ever resolves a pair through one direct feed or one inverted feed, so a pair
/// that is reachable only by chaining two feeds through a shared intermediate currency has no route without this.
/// @dev Both legs must be denominated in the same intermediate currency, and that currency cancels out: given
/// `NUMERATOR` priced as "intermediate per A" and `DENOMINATOR` priced as "intermediate per B", the result is
/// "B per A". The argument order is the direction convention — `NUMERATOR` prices the currency whose unit is being
/// priced, and `DENOMINATOR` prices the currency the result is denominated in.
/// @dev Worked example, USD as the intermediate currency. `NUMERATOR` is the Chainlink USDC/USD feed reporting
/// `1.0001` USD per USDC, and `DENOMINATOR` is the Chainlink ETH/USD feed reporting `2000` USD per ETH. A call to
/// `currentUnitPrice(18)` reads `1.0001e36` from the numerator leg and `2000e18` from the denominator leg, and
/// returns `1.0001e36 / 2000e18 = 5.0005e14`, which is `0.00050005` ETH per USDC in 18-decimal fixed point. Passing
/// the same two feeds in the opposite order would instead price USDC per ETH.
/// @dev This contract deliberately performs no staleness, round-completeness, or L2 sequencer-uptime validation. Each
/// leg is responsible for its own liveness guarantees — `JBChainlinkV3PriceFeed` enforces its staleness threshold and
/// rejects negative or incomplete rounds, and `JBChainlinkV3SequencerPriceFeed` additionally enforces the sequencer
/// grace period. Those checks revert underneath this call and propagate out of it uncaught, so a second layer of
/// validation here would be redundant and would only add a way for the two layers to disagree.
contract JBRatioPriceFeed is IJBPriceFeed {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the denominator feed is the zero address, since a composed price has no meaning without
    /// both legs.
    error JBRatioPriceFeed_ZeroDenominator();

    /// @notice Thrown when the denominator leg reports a price of zero, which has no reciprocal. The quotient is
    /// undefined rather than free, so this reverts instead of reporting a price that would value a payment at nothing.
    error JBRatioPriceFeed_ZeroDenominatorPrice();

    /// @notice Thrown when the numerator feed is the zero address, since a composed price has no meaning without both
    /// legs.
    error JBRatioPriceFeed_ZeroNumerator();

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The extra fixed-point precision the numerator leg is quoted with, which the division by the denominator
    /// leg then cancels out.
    /// @dev Both legs must be measured against this same scale for the quotient to land on the requested precision, so
    /// the two uses below are bound to this one value.
    uint256 internal constant _HEADROOM_DECIMALS = 18;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The feed whose price the result is divided by. Its currency is the one the result is denominated in.
    IJBPriceFeed public immutable DENOMINATOR;

    /// @notice The feed whose price the result is divided from. Its currency is the one the result prices a unit of.
    IJBPriceFeed public immutable NUMERATOR;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param numerator The feed pricing one unit of the currency being priced, denominated in the intermediate
    /// currency.
    /// @param denominator The feed pricing one unit of the currency the result is denominated in, denominated in the
    /// same intermediate currency.
    constructor(IJBPriceFeed numerator, IJBPriceFeed denominator) {
        if (numerator == IJBPriceFeed(address(0))) revert JBRatioPriceFeed_ZeroNumerator();
        if (denominator == IJBPriceFeed(address(0))) revert JBRatioPriceFeed_ZeroDenominator();

        DENOMINATOR = denominator;
        NUMERATOR = numerator;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Gets the current price (per 1 unit) from the feed.
    /// @dev The result is floored. At small `decimals` a ratio below one unit of the requested precision floors to
    /// zero, which `JBPrices` treats as an unavailable feed and rolls past to its remaining backups.
    /// @param decimals The number of decimals the return value should use.
    /// @return The current unit price from the feed, as a fixed point number with the specified number of decimals.
    function currentUnitPrice(uint256 decimals) public view virtual override returns (uint256) {
        // Quote the numerator leg with the headroom included so the division below has digits to consume. Quoting it
        // at `decimals` first would floor the numerator before the ratio is taken, and at low `decimals` that floor
        // would dominate the result.
        uint256 numeratorPrice = NUMERATOR.currentUnitPrice(decimals + _HEADROOM_DECIMALS);

        // Quote the denominator leg at the headroom scale, which is the scale the numerator's extra digits are
        // measured against.
        uint256 denominatorPrice = DENOMINATOR.currentUnitPrice(_HEADROOM_DECIMALS);

        // A zero denominator has no reciprocal. Revert rather than divide, so a broken leg surfaces as an unavailable
        // feed instead of a price of nothing.
        if (denominatorPrice == 0) revert JBRatioPriceFeed_ZeroDenominatorPrice();

        // `(numerator * 10^(decimals + 18)) / (denominator * 10^18)` is `(numerator / denominator) * 10^decimals`, so
        // the headroom cancels and the quotient lands on the requested precision.
        return numeratorPrice / denominatorPrice;
    }
}
