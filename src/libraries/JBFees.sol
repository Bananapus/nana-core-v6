// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./../libraries/JBConstants.sol";

/// @notice Fee calculations.
library JBFees {
    /// @notice Returns the fee amount that, when added to `amountAfterFee`, produces the gross amount needed to yield
    /// `amountAfterFee` after the fee is deducted.
    /// @dev Use this to back-calculate the fee from a desired post-fee payout.
    /// @dev If a nonzero amount would otherwise produce a zero fee, returns 1 so feeable dust payouts cannot bypass
    /// protocol fees by splitting across tiny transfers.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountResultingIn(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        uint256 feeAmount =
            mulDiv(amountAfterFee, JBConstants.MAX_FEE, JBConstants.MAX_FEE - feePercent) - amountAfterFee;

        return feeAmount == 0 && amountAfterFee != 0 ? 1 : feeAmount;
    }

    /// @notice Returns the fee that would be taken from `amountBeforeFee`.
    /// @dev Use this to forward-calculate the fee from a known pre-fee amount.
    /// @dev If a nonzero amount would otherwise produce a zero fee, returns 1 so feeable dust payouts cannot bypass
    /// protocol fees by splitting across tiny transfers.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountFrom(uint256 amountBeforeFee, uint256 feePercent) internal pure returns (uint256) {
        uint256 feeAmount = mulDiv(amountBeforeFee, feePercent, JBConstants.MAX_FEE);

        return feeAmount == 0 && amountBeforeFee != 0 ? 1 : feeAmount;
    }
}
