// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";

/// @notice Small Halmos entrypoints for proving bounded fee arithmetic before widening the symbolic domains.
/// @dev These checks avoid `forge-std` assumptions so Halmos can solve them as pure Solidity path conditions.
contract HalmosSmoke {
    /// @notice Proves a zero fee never charges, for the full uint256 amount domain.
    /// @param amount The amount before fees.
    function check_zeroFeeDoesNotCharge(uint256 amount) public pure {
        assert(JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: 0}) == 0);
    }

    /// @notice Proves a zero amount cannot produce a fee, for every supported fee percent.
    /// @param feePercent The fee percent, where 1000 is 100%.
    function check_zeroAmountHasNoFee(uint16 feePercent) public pure {
        if (feePercent > 1000) return;

        assert(JBFees.feeAmountFrom({amountBeforeFee: 0, feePercent: feePercent}) == 0);
    }

    /// @notice Proves the optimized standard-fee helper matches the generic fee formula over the full uint16 domain.
    /// @param amount The amount before fees.
    function check_standardFeeMatchesGeneric(uint16 amount) public pure {
        assert(
            JBFees.standardFeeAmountFrom({amountBeforeFee: uint256(amount)})
                == JBFees.feeAmountFrom({amountBeforeFee: uint256(amount), feePercent: JBConstants.STANDARD_FEE})
        );
    }

    /// @notice Proves the optimized standard reverse-fee helper matches the generic uint8 formula.
    /// @param amount The desired amount after fees.
    function check_standardFeeResultingInMatchesGeneric(uint8 amount) public pure {
        assert(
            JBFees.standardFeeAmountResultingIn({amountAfterFee: uint256(amount)})
                == JBFees.feeAmountResultingIn({amountAfterFee: uint256(amount), feePercent: JBConstants.STANDARD_FEE})
        );
    }

    /// @notice Proves the optimized standard-fee helper cannot exceed its input over the full uint256 domain.
    /// @param amount The amount before fees.
    function check_standardFeeDoesNotExceedAmount(uint256 amount) public pure {
        uint256 fee = JBFees.standardFeeAmountFrom({amountBeforeFee: amount});

        assert(fee <= amount);
        assert(amount - fee + fee == amount);
    }
}
