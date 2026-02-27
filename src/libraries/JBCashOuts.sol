// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./JBConstants.sol";

/// @notice Cash out calculations.
library JBCashOuts {
    /// @notice Thrown when the desired output cannot be achieved (e.g., cash out tax rate is 100%).
    error JBCashOuts_DesiredOutputNotAchievable();

    /// @notice Returns the amount of surplus terminal tokens which can be reclaimed based on the total surplus, the
    /// number of tokens being cashed out, the total token supply, and the ruleset's cash out tax rate.
    /// @param surplus The total amount of surplus terminal tokens.
    /// @param cashOutCount The number of tokens being cashed out, as a fixed point number with 18 decimals.
    /// @param totalSupply The total token supply, as a fixed point number with 18 decimals.
    /// @param cashOutTaxRate The current ruleset's cash out tax rate.
    /// @return reclaimableSurplus The amount of surplus tokens that can be reclaimed.
    function cashOutFrom(
        uint256 surplus,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        internal
        pure
        returns (uint256)
    {
        // If the cash out tax rate is the max, no surplus can be reclaimed.
        if (cashOutTaxRate == JBConstants.MAX_CASH_OUT_TAX_RATE) return 0;

        // If the total supply is being cashed out, return the entire surplus.
        if (cashOutCount >= totalSupply) return surplus;

        // Get a reference to the linear proportion.
        uint256 base = mulDiv(surplus, cashOutCount, totalSupply);

        // These conditions are all part of the same curve.
        // Edge conditions are separated to minimize the operations performed in those cases.
        if (cashOutTaxRate == 0) {
            return base;
        }

        return mulDiv(
            base,
            (JBConstants.MAX_CASH_OUT_TAX_RATE - cashOutTaxRate) + mulDiv(cashOutTaxRate, cashOutCount, totalSupply),
            JBConstants.MAX_CASH_OUT_TAX_RATE
        );
    }

    /// @notice Returns the minimum number of tokens that must be cashed out to receive at least `desiredOutput` of
    /// surplus terminal tokens. This is the inverse of `cashOutFrom`.
    /// @dev Due to integer rounding in `cashOutFrom`, the returned count may yield slightly more than `desiredOutput`.
    /// When `desiredOutput >= surplus`, returns `totalSupply` (cashing out everything yields the full surplus).
    /// @param surplus The total amount of surplus terminal tokens.
    /// @param desiredOutput The minimum amount of surplus tokens the caller wants to receive.
    /// @param totalSupply The total token supply, as a fixed point number with 18 decimals.
    /// @param cashOutTaxRate The current ruleset's cash out tax rate.
    /// @return count The minimum number of tokens to cash out.
    function cashOutCountFor(
        uint256 surplus,
        uint256 desiredOutput,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        internal
        pure
        returns (uint256)
    {
        // If no output is desired, no tokens need to be cashed out.
        if (desiredOutput == 0) return 0;

        // If the cash out tax rate is at maximum, no output is achievable.
        if (cashOutTaxRate == JBConstants.MAX_CASH_OUT_TAX_RATE) {
            revert JBCashOuts_DesiredOutputNotAchievable();
        }

        // If the desired output meets or exceeds the surplus, the entire supply must be cashed out.
        if (desiredOutput >= surplus) return totalSupply;

        // Linear case (no tax): out = surplus * c / totalSupply, so c = ceil(out * totalSupply / surplus).
        if (cashOutTaxRate == 0) {
            uint256 count = mulDiv(desiredOutput, totalSupply, surplus);
            // Round up if the floor division undershoots.
            if (mulDiv(surplus, count, totalSupply) < desiredOutput) count++;
            return count;
        }

        // General case: binary search for the minimum c such that
        // cashOutFrom(surplus, c, totalSupply, cashOutTaxRate) >= desiredOutput.
        //
        // The forward formula out = (S*c/T) * [(m-r) + r*c/T] / m is monotonically non-decreasing in c,
        // so binary search is valid. We know:
        //   - cashOutFrom(surplus, 0, totalSupply, r) = 0 < desiredOutput
        //   - cashOutFrom(surplus, totalSupply, totalSupply, r) = surplus > desiredOutput
        // so a valid answer always exists in [1, totalSupply].

        uint256 lo = 1;
        uint256 hi = totalSupply;

        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (cashOutFrom(surplus, mid, totalSupply, cashOutTaxRate) >= desiredOutput) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        return lo;
    }
}
