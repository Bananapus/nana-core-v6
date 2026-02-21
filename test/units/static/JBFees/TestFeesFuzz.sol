// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBFees} from "../../../../src/libraries/JBFees.sol";

/// @notice Fuzz tests for the JBFees library.
contract TestFeesFuzz_Local is JBTest {
    function setUp() external {}

    /// @notice feeAmountFrom with feePercent=0 returns 0.
    function testFuzz_feeAmountFrom_zeroPercent(uint256 amount) external pure {
        amount = bound(amount, 0, type(uint128).max);
        uint256 fee = JBFees.feeAmountFrom(amount, 0);
        assertEq(fee, 0, "fee with 0% should be 0");
    }

    /// @notice feeAmountFrom with amount=0 returns 0.
    function testFuzz_feeAmountFrom_zeroAmount(uint256 feePercent) external pure {
        feePercent = bound(feePercent, 0, JBConstants.MAX_FEE);
        uint256 fee = JBFees.feeAmountFrom(0, feePercent);
        assertEq(fee, 0, "fee on 0 amount should be 0");
    }

    /// @notice fee + remainder == amount (conservation).
    /// @dev feeAmountFrom(amount, percent) + (amount - feeAmountFrom(amount, percent)) == amount
    function testFuzz_feeAmountFrom_conservation(uint256 amount, uint256 feePercent) external pure {
        amount = bound(amount, 0, type(uint128).max);
        feePercent = bound(feePercent, 0, JBConstants.MAX_FEE);

        uint256 fee = JBFees.feeAmountFrom(amount, feePercent);
        uint256 remainder = amount - fee;

        assertEq(fee + remainder, amount, "fee + remainder must equal amount");
        assertLe(fee, amount, "fee must not exceed amount");
    }

    /// @notice fee is monotonically increasing with amount (for fixed percent).
    function testFuzz_feeAmountFrom_monotonic(uint256 amount1, uint256 amount2, uint256 feePercent) external pure {
        amount1 = bound(amount1, 0, type(uint64).max);
        amount2 = bound(amount2, amount1, type(uint64).max);
        feePercent = bound(feePercent, 0, JBConstants.MAX_FEE);

        uint256 fee1 = JBFees.feeAmountFrom(amount1, feePercent);
        uint256 fee2 = JBFees.feeAmountFrom(amount2, feePercent);

        assertLe(fee1, fee2, "fee should be monotonically increasing with amount");
    }

    /// @notice feeAmountFrom and feeAmountResultingIn are directionally consistent.
    /// @dev feeAmountResultingIn(afterFee, percent) >= fee from feeAmountFrom.
    ///      The reverse operation should always produce a fee that covers the forward fee.
    function testFuzz_feeSymmetry(uint256 amount, uint256 feePercent) external pure {
        amount = bound(amount, 1, type(uint64).max);
        feePercent = bound(feePercent, 1, JBConstants.MAX_FEE - 1); // Avoid 0% and 100%

        // Forward: calculate fee from amount
        uint256 fee = JBFees.feeAmountFrom(amount, feePercent);
        uint256 afterFee = amount - fee;

        // Reverse: from afterFee, what fee would produce afterFee as the result?
        uint256 reverseFee = JBFees.feeAmountResultingIn(afterFee, feePercent);

        // The reverse fee should always be >= the forward fee (it rounds up to ensure
        // the total with fee >= the original amount).
        assertGe(reverseFee, fee, "reverse fee should be >= forward fee");

        // And the total should be >= the original amount (reverse is conservative)
        assertGe(reverseFee + afterFee, amount, "reverse fee + afterFee should be >= amount");
    }

    /// @notice feeAmountFrom with MAX_FEE returns the full amount.
    function testFuzz_feeAmountFrom_maxPercent(uint256 amount) external pure {
        amount = bound(amount, 0, type(uint128).max);
        uint256 fee = JBFees.feeAmountFrom(amount, JBConstants.MAX_FEE);
        assertEq(fee, amount, "fee at MAX_FEE should equal amount");
    }
}
