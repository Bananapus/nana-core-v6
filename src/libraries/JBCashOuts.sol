// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./JBConstants.sol";

/// @notice Cash out calculations.
library JBCashOuts {
    /// @notice Thrown when the desired output cannot be achieved (e.g., cash out tax rate is 100%).
    error JBCashOuts_DesiredOutputNotAchievable();

    /// @notice Returns the amount of surplus terminal tokens which can be reclaimed based on the total surplus, the
    /// number of tokens being cashed out, the total token supply, and the ruleset's cash out tax rate.
    /// @dev For single-chain projects, `totalSupply` is the local supply and `taxSurplus` is 0.
    /// For omnichain projects, `totalSupply` should include tokens on other chains (to prevent tax bypass)
    /// and `taxSurplus` should include surplus on other chains (for proportional reclaim).
    /// @param surplus The local surplus of terminal tokens (also serves as the cap on reclaimable amount).
    /// @param cashOutCount The number of tokens being cashed out, as a fixed point number with 18 decimals.
    /// @param totalSupply The total token supply used for both the proportional reclaim and tax calculations.
    /// For omnichain projects, this includes tokens on other chains so the tax cannot be bypassed.
    /// @param taxSurplus The global surplus across all chains, used for the proportional reclaim base when > 0.
    /// When 0, the proportional base uses `surplus` / `totalSupply` (existing single-chain behavior).
    /// When > 0, the proportional base uses `taxSurplus` / `totalSupply`, capped at `surplus`.
    /// @param cashOutTaxRate The current ruleset's cash out tax rate.
    /// @return reclaimableSurplus The amount of surplus tokens that can be reclaimed.
    function cashOutFrom(
        uint256 surplus,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 taxSurplus,
        uint256 cashOutTaxRate
    )
        internal
        pure
        returns (uint256)
    {
        // If nothing is being cashed out, nothing can be reclaimed.
        if (cashOutCount == 0) return 0;

        // If the cash out tax rate is the max, no surplus can be reclaimed.
        if (cashOutTaxRate == JBConstants.MAX_CASH_OUT_TAX_RATE) return 0;

        // If the entire supply is being cashed out, return the entire local surplus.
        if (cashOutCount >= totalSupply) return surplus;

        // Get a reference to the linear proportion.
        uint256 base;
        if (taxSurplus > 0) {
            // Cross-chain: proportional claim based on global surplus and global supply.
            base = mulDiv(taxSurplus, cashOutCount, totalSupply);
            // Cap at local surplus — can't reclaim more than what's locally available.
            if (base > surplus) base = surplus;
        } else {
            // Single-chain: proportional claim based on local surplus and local supply.
            base = mulDiv(surplus, cashOutCount, totalSupply);
        }

        // These conditions are all part of the same curve.
        // Edge conditions are separated to minimize the operations performed in those cases.
        if (cashOutTaxRate == 0) {
            return base;
        }

        // Apply the tax.
        uint256 result = mulDiv(
            base,
            (JBConstants.MAX_CASH_OUT_TAX_RATE - cashOutTaxRate)
                + mulDiv(cashOutTaxRate, cashOutCount, totalSupply),
            JBConstants.MAX_CASH_OUT_TAX_RATE
        );

        // Final cap: never exceed local surplus.
        return result > surplus ? surplus : result;
    }

    /// @notice Returns the minimum number of tokens that must be cashed out to receive at least `desiredOutput` of
    /// surplus terminal tokens. This is the inverse of `cashOutFrom`.
    /// @dev Due to integer rounding in `cashOutFrom`, the returned count may yield slightly more than `desiredOutput`.
    /// When `desiredOutput >= surplus`, returns `totalSupply` (cashing out everything yields the full surplus).
    /// @param surplus The local surplus of terminal tokens (also serves as the cap).
    /// @param desiredOutput The minimum amount of surplus tokens the caller wants to receive.
    /// @param totalSupply The total token supply used for both the proportional reclaim and tax calculations.
    /// @param taxSurplus The global surplus across all chains (0 = use local surplus).
    /// @param cashOutTaxRate The current ruleset's cash out tax rate.
    /// @return count The minimum number of tokens to cash out.
    function minCashOutCountFor(
        uint256 surplus,
        uint256 desiredOutput,
        uint256 totalSupply,
        uint256 taxSurplus,
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

        // Linear case (no tax): binary search still needed when taxSurplus is set (different base formula).
        if (cashOutTaxRate == 0 && taxSurplus == 0) {
            uint256 count = mulDiv(desiredOutput, totalSupply, surplus);
            // Round up if the floor division undershoots.
            if (mulDiv(surplus, count, totalSupply) < desiredOutput) count++;
            return count;
        }

        // General case: binary search for the minimum c such that
        // cashOutFrom(surplus, c, totalSupply, taxSurplus, cashOutTaxRate) >= desiredOutput.
        //
        // The forward formula is monotonically non-decreasing in c, so binary search is valid. We know:
        //   - cashOutFrom(surplus, 0, ...) = 0 < desiredOutput
        //   - cashOutFrom(surplus, totalSupply, ...) = surplus > desiredOutput
        // so a valid answer always exists in [1, totalSupply].

        uint256 lo = 1;
        uint256 hi = totalSupply;

        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (
                cashOutFrom({
                    surplus: surplus,
                    cashOutCount: mid,
                    totalSupply: totalSupply,
                    taxSurplus: taxSurplus,
                    cashOutTaxRate: cashOutTaxRate
                }) >= desiredOutput
            ) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        return lo;
    }
}
