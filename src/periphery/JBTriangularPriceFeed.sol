// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBPriceFeed} from "../interfaces/IJBPriceFeed.sol";

/// @notice A composite price feed that triangulates two existing feeds sharing a common quote ("pivot") currency to
/// price a pair that has no direct feed.
/// @dev Composes `NUMERATOR` (the pivot priced per unit of the target pair's *unit* currency) and `DENOMINATOR` (the
/// pivot priced per unit of the target pair's *pricing* currency) into "pricing currency per unit currency". The
/// pivot is implicit in the two legs supplied at construction — it is never hardcoded — so different instances can
/// triangulate through different pivots, and `JBPrices` stays a plain registry with no triangulation logic.
///
/// Worked example (ETH<->USDC has no direct feed, triangulate through USD): supply
/// `NUMERATOR` = the USD-per-USDC feed and `DENOMINATOR` = the USD-per-ETH feed. `currentUnitPrice` then returns
/// "ETH per 1 USDC", and registering this feed for the `(pricingCurrency = ETH, unitCurrency = USDC)` pair lets
/// `JBPrices` auto-invert it to "USDC per 1 ETH" for the opposite direction.
///
/// Safety: this feed inherits each leg's staleness/validity reverts. If either leg reverts (stale, negative, or
/// incomplete round) the composite reverts, so a stale or invalid leg can never yield a usable composite price.
contract JBTriangularPriceFeed is IJBPriceFeed {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The feed pricing one unit of the target pair's *unit* currency in the shared pivot currency.
    IJBPriceFeed public immutable NUMERATOR;

    /// @notice The feed pricing one unit of the target pair's *pricing* currency in the shared pivot currency.
    IJBPriceFeed public immutable DENOMINATOR;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param numerator The feed pricing the unit currency in the pivot currency (e.g. a USD-per-USDC feed).
    /// @param denominator The feed pricing the pricing currency in the pivot currency (e.g. a USD-per-ETH feed).
    constructor(IJBPriceFeed numerator, IJBPriceFeed denominator) {
        NUMERATOR = numerator;
        DENOMINATOR = denominator;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBPriceFeed
    /// @dev Returns `numerator / denominator` at the requested precision, which cancels the shared pivot unit and
    /// yields "pricing currency per 1 unit currency".
    function currentUnitPrice(uint256 decimals) external view override returns (uint256) {
        return mulDiv(NUMERATOR.currentUnitPrice(decimals), 10 ** decimals, DENOMINATOR.currentUnitPrice(decimals));
    }
}
