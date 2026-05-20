// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

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
}
