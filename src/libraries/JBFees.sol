// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./../libraries/JBConstants.sol";

/// @notice Utility functions for calculating the protocol fee (2.5%) in both directions: forward (fee from a pre-fee
/// amount) and backward (the pre-fee amount that would yield a given post-fee amount). Used by `JBMultiTerminal`
/// during payouts, surplus allowance usage, and cash outs.
/// @dev Fee dust protection: if a nonzero amount with a nonzero fee would otherwise round to 0, returns 1 wei to
/// prevent fee bypass via many tiny transfers.
library JBFees {
    /// @notice Returns the fee that would be taken from `amountBeforeFee`.
    /// @dev Use this to forward-calculate the fee from a known pre-fee amount.
    /// @dev If a nonzero amount and nonzero fee would otherwise produce a zero fee, returns 1 so feeable dust payouts
    /// cannot bypass protocol fees by splitting across tiny transfers.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountFrom(uint256 amountBeforeFee, uint256 feePercent) internal pure returns (uint256) {
        uint256 feeAmount = feeAmountFromFloor({amountBeforeFee: amountBeforeFee, feePercent: feePercent});

        return feeAmount == 0 && amountBeforeFee != 0 && feePercent != 0 ? 1 : feeAmount;
    }

    /// @notice Returns the floor-rounded fee that would be taken from `amountBeforeFee`.
    /// @dev Fee rounding error is bounded by N-1 wei (N = number of splits). Economically insignificant. Rounds down
    /// (mulDiv floors), so the fee beneficiary may receive up to 1 wei less per split.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The floor-rounded fee amount, as a fixed point number with the same number of decimals as the provided
    /// `amount`.
    function feeAmountFromFloor(uint256 amountBeforeFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv(amountBeforeFee, feePercent, JBConstants.MAX_FEE);
    }

    /// @notice Returns the fee amount that, when added to `amountAfterFee`, produces the gross amount needed to yield
    /// `amountAfterFee` after the fee is deducted.
    /// @dev Use this to back-calculate the fee from a desired post-fee payout.
    /// @dev If a nonzero amount and nonzero fee would otherwise produce a zero fee, returns 1 so feeable dust payouts
    /// cannot bypass protocol fees by splitting across tiny transfers.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountResultingIn(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        uint256 feeAmount = feeAmountResultingInFloor({amountAfterFee: amountAfterFee, feePercent: feePercent});

        return feeAmount == 0 && amountAfterFee != 0 && feePercent != 0 ? 1 : feeAmount;
    }

    /// @notice Returns the floor-rounded fee amount that, when added to `amountAfterFee`, produces the gross amount
    /// needed to yield `amountAfterFee` after the fee is deducted.
    /// @dev Use this when adjusting an existing held-fee entry, where applying the 1-unit minimum again would double
    /// charge dust.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The floor-rounded fee amount, as a fixed point number with the same number of decimals as the provided
    /// `amount`.
    function feeAmountResultingInFloor(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv(amountAfterFee, JBConstants.MAX_FEE, JBConstants.MAX_FEE - feePercent) - amountAfterFee;
    }

    /// @notice Returns the floor-rounded fee amount resulting in `amountAfterFee` for a 2.5% fee.
    /// @dev Equivalent to `feeAmountResultingInFloor(amountAfterFee, 25)`, but avoids the generic `mulDiv` path.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @return The floor-rounded fee amount.
    function feeAmountResultingInFloorForFee25(uint256 amountAfterFee) internal pure returns (uint256) {
        // The specialized denominator is `(JBConstants.MAX_FEE - 25) / 25`.
        return amountAfterFee / 39;
    }
}
