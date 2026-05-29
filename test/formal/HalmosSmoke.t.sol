// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBCashOuts} from "../../src/libraries/JBCashOuts.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";

/// @notice Small Halmos entrypoints for proving bounded fee arithmetic before widening the symbolic domains.
/// @dev These checks avoid `forge-std` assumptions so Halmos can solve them as pure Solidity path conditions.
contract HalmosSmoke {
    uint256 private constant _MAX_CASH_OUT_TAX_RATE = JBConstants.MAX_CASH_OUT_TAX_RATE;
    uint256 private constant _TAX_1 = 1;
    uint256 private constant _TAX_25_PERCENT = 2500;
    uint256 private constant _TAX_50_PERCENT = 5000;
    uint256 private constant _TAX_75_PERCENT = 7500;
    uint256 private constant _TAX_ALMOST_MAX = 9999;

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

    /// @notice Proves a selected bonding-curve boundary table stays stable.
    /// @dev Symbolic cash-out domains were too expensive for the CI smoke target, so this pins the exact branch edges.
    function check_cashOutBoundaryTaxRateTable() public pure {
        // Partial cash-out case: 2,500 out of 10,000 project tokens against 10,000 surplus.
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: 0}) == 2500);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: _TAX_1}) == 2499);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: _TAX_25_PERCENT}) == 2031);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: _TAX_50_PERCENT}) == 1562);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: _TAX_75_PERCENT}) == 1093);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: _TAX_ALMOST_MAX}) == 625);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: _MAX_CASH_OUT_TAX_RATE}) == 0);

        // Full cash-out returns all surplus for every non-max tax rate; 100% tax still returns zero by design.
        assert(_cashOutFrom({cashOutCount: 10_000, cashOutTaxRate: 0}) == 10_000);
        assert(_cashOutFrom({cashOutCount: 10_000, cashOutTaxRate: _TAX_ALMOST_MAX}) == 10_000);
        assert(_cashOutFrom({cashOutCount: 10_000, cashOutTaxRate: _MAX_CASH_OUT_TAX_RATE}) == 0);
    }

    /// @notice Calls the cash-out library with the fixed 10,000-supply/10,000-surplus table inputs.
    /// @param cashOutCount The number of project tokens being cashed out in the table row.
    /// @param cashOutTaxRate The tax rate to apply to the table row.
    /// @return reclaimAmount The reclaim amount returned by the bonding-curve library.
    function _cashOutFrom(uint256 cashOutCount, uint256 cashOutTaxRate) private pure returns (uint256 reclaimAmount) {
        return JBCashOuts.cashOutFrom({
            surplus: 10_000, cashOutCount: cashOutCount, totalSupply: 10_000, cashOutTaxRate: cashOutTaxRate
        });
    }
}
