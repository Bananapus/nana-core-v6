// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBConstants} from "./../libraries/JBConstants.sol";

/// @notice Fee calculations.
library JBFees {
    /// @notice Returns the fee amount that, when added to `amountAfterFee`, produces the gross amount needed to yield
    /// `amountAfterFee` after the fee is deducted.
    /// @dev Use this to back-calculate the fee from a desired post-fee payout.
    /// @dev If a nonzero amount and nonzero fee would otherwise produce a zero fee, returns 1 so feeable dust payouts
    /// cannot bypass protocol fees by splitting across tiny transfers.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountResultingIn(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        uint256 feeAmount = mulDiv({
            x: amountAfterFee, y: JBConstants.MAX_FEE, denominator: JBConstants.MAX_FEE - feePercent
        }) - amountAfterFee;

        assembly {
            feeAmount := or(
                feeAmount,
                and(iszero(feeAmount), and(iszero(iszero(amountAfterFee)), iszero(iszero(feePercent))))
            )
        }
        return feeAmount;
    }

    /// @notice Returns the floor-rounded fee amount that, when added to `amountAfterFee`, produces the gross amount.
    /// @dev Use this for partial held-fee repayments where applying the 1-unit dust minimum could double charge
    /// across several repayments of the same held-fee entry.
    /// @param amountAfterFee The desired post-fee amount, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The floor-rounded fee amount.
    function feeAmountResultingInFloor(uint256 amountAfterFee, uint256 feePercent) internal pure returns (uint256) {
        return mulDiv({x: amountAfterFee, y: JBConstants.MAX_FEE, denominator: JBConstants.MAX_FEE - feePercent})
            - amountAfterFee;
    }

    /// @notice Returns the fee that would be taken from `amountBeforeFee`.
    /// @dev Use this to forward-calculate the fee from a known pre-fee amount.
    /// @dev If a nonzero amount and nonzero fee would otherwise produce a zero fee, returns 1 so feeable dust payouts
    /// cannot bypass protocol fees by splitting across tiny transfers.
    /// @param amountBeforeFee The amount before the fee is applied, as a fixed point number.
    /// @param feePercent The fee percent, out of `JBConstants.MAX_FEE`.
    /// @return The fee amount, as a fixed point number with the same number of decimals as the provided `amount`.
    function feeAmountFrom(uint256 amountBeforeFee, uint256 feePercent) internal pure returns (uint256) {
        uint256 feeAmount = mulDiv({x: amountBeforeFee, y: feePercent, denominator: JBConstants.MAX_FEE});

        assembly {
            feeAmount := or(
                feeAmount,
                and(iszero(feeAmount), and(iszero(iszero(amountBeforeFee)), iszero(iszero(feePercent))))
            )
        }
        return feeAmount;
    }
}
