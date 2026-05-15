// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./../libraries/JBConstants.sol";

/// @notice Fee calculations.
library JBFees {
    /// @notice Returns the fee amount that, when added to `amountAfterFee`, produces the gross amount needed to yield
    /// `amountAfterFee` after the fee is deducted.
    /// @dev Use this to back-calculate the fee from a desired post-fee payout.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountResultingIn(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv(amountAfterFee, JBConstants.MAX_FEE, JBConstants.MAX_FEE - feePercent) - amountAfterFee;
    }

    /// @notice Returns the fee that would be taken from `amountBeforeFee`.
    /// @dev Use this to forward-calculate the fee from a known pre-fee amount.
    /// @dev Fee rounding error is bounded by N-1 wei (N = number of splits). Economically
    /// insignificant. Rounds down (mulDiv floors), so the fee beneficiary may receive up to 1 wei less per split.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountFrom(uint256 amountBeforeFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv(amountBeforeFee, feePercent, JBConstants.MAX_FEE);
    }

    /// @notice Specialization of `feeAmountFrom` that hardcodes the standard protocol fee
    /// (`JBConstants.FEE / JBConstants.MAX_FEE` = 25 / 1000 = 1 / 40). Both numerator and denominator are
    /// compile-time constants so callers don't need to pass them every call.
    /// @dev Pre-reduced: `mulDiv(amount, 25, 1000)` ≡ `amount / 40` (gcd(25, 1000) = 25). Plain integer
    /// division is exact (rounds down) and shaves the entire `mulDiv` 512-bit pipeline at every fee site.
    /// If `JBConstants.FEE` or `JBConstants.MAX_FEE` changes, the constant `40` here MUST be reduced again.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @return The fee amount, as a fixed point number with the same number of decimals as `amountBeforeFee`.
    function standardFeeAmountFrom(uint256 amountBeforeFee) internal pure returns (uint256) {
        return amountBeforeFee / 40;
    }

    /// @notice Specialization of `feeAmountResultingIn` that hardcodes the standard protocol fee
    /// (`JBConstants.FEE / JBConstants.MAX_FEE`). Use to back-calculate the standard fee from a known
    /// post-fee payout.
    /// @dev Pre-reduced: `mulDiv(amount, 1000, 1000 - 25) - amount` ≡ `mulDiv(amount, 40, 39) - amount`
    /// (gcd(1000, 975) = 25). `mulDiv` (not raw `*`) preserves overflow-safety for the rare wildly-large
    /// inputs and matches the rounding behavior of `feeAmountResultingIn` exactly. If `JBConstants.FEE` or
    /// `JBConstants.MAX_FEE` changes, the constants `40` and `39` here MUST be reduced again.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @return The fee amount that, when added to `amountAfterFee`, yields the gross pre-fee amount.
    function standardFeeAmountResultingIn(uint256 amountAfterFee) internal pure returns (uint256) {
        return mulDiv(amountAfterFee, 40, 39) - amountAfterFee;
    }
}
