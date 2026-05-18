// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./JBConstants.sol";

/// @notice Fee calculations.
library JBFees {
    /// @notice Returns the fee that would be taken from `amountBeforeFee`.
    /// @dev Use this to forward-calculate the fee from a known pre-fee amount.
    /// @dev Fee rounding error is bounded by N-1 wei (N = number of splits). Economically
    /// insignificant. Rounds down (mulDiv floors), so the fee beneficiary may receive up to 1 wei less per split.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as `amountBeforeFee`.
    function feeAmountFrom(uint256 amountBeforeFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv({x: amountBeforeFee, y: feePercent, denominator: JBConstants.MAX_FEE});
    }

    /// @notice Returns the fee amount that, when added to `amountAfterFee`, produces the gross amount needed to yield
    /// `amountAfterFee` after the fee is deducted.
    /// @dev Use this to back-calculate the fee from a desired post-fee payout.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as `amountAfterFee`.
    function feeAmountResultingIn(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv({x: amountAfterFee, y: JBConstants.MAX_FEE, denominator: JBConstants.MAX_FEE - feePercent})
            - amountAfterFee;
    }

    /// @notice Returns the standard protocol fee taken from `amountBeforeFee`.
    /// @dev The standard fee is `25 / 1_000`, pre-reduced to `1 / 40`. If `JBConstants.STANDARD_FEE` or
    /// `JBConstants.MAX_FEE` changes, this denominator must be reduced again.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @return The fee amount, as a fixed point number with the same number of decimals as `amountBeforeFee`.
    function standardFeeAmountFrom(uint256 amountBeforeFee) internal pure returns (uint256) {
        // `JBConstants.STANDARD_FEE / JBConstants.MAX_FEE` is currently `1 / 40`.
        return amountBeforeFee / 40;
    }

    /// @notice Back-calculates the standard protocol fee from a known post-fee amount.
    /// @dev `1 / (1 - 25 / 1_000) - 1` reduces to `40 / 39 - 1`. If `JBConstants.STANDARD_FEE` or
    /// `JBConstants.MAX_FEE` changes, these constants must be reduced again.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @return The fee amount that, when added to `amountAfterFee`, yields the gross pre-fee amount.
    function standardFeeAmountResultingIn(uint256 amountAfterFee) internal pure returns (uint256) {
        // Use `mulDiv` instead of `amountAfterFee * 40 / 39` to preserve overflow safety.
        return mulDiv({x: amountAfterFee, y: 40, denominator: 39}) - amountAfterFee;
    }
}
