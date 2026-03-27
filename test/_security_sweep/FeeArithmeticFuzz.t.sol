// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {Test} from "forge-std/Test.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBCashOuts} from "../../src/libraries/JBCashOuts.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";

/// @notice Fuzz tests for fee arithmetic and bonding curve math.
/// Attack hypotheses:
///   H1: Fee forward/backward roundtrip leaks value (payer charged less than protocol expects)
///   H2: Bonding curve sequential cashouts extract more than single cashout (superadditivity)
///   H3: Rounding accumulation across many small cashouts drains surplus
///   H4: minCashOutCountFor + cashOutFrom roundtrip breaks guarantee
///   H5: Bonding curve cashOutCount >= totalSupply edge case leaks surplus
contract FeeArithmeticFuzz is Test {
    uint256 constant FEE = 25; // 2.5%
    uint256 constant MAX_FEE = JBConstants.MAX_FEE; // 1000
    uint256 constant MAX_CASH_OUT_TAX_RATE = JBConstants.MAX_CASH_OUT_TAX_RATE; // 10_000

    // ═══════════════════════════════════════════════════════════════════
    //  H1: Fee forward/backward roundtrip - protocol must never undercharge
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Forward fee applied to gross amount, then backward fee on net amount,
    ///         must reconstruct the original gross amount or slightly more (never less).
    function testFuzz_feeRoundtrip_neverUndercharges(uint256 grossAmount) public pure {
        // Bound to realistic range - avoid zero and extreme values
        grossAmount = bound(grossAmount, 1, type(uint128).max);

        // Forward: fee from gross amount
        uint256 forwardFee = JBFees.feeAmountFrom(grossAmount, FEE);
        uint256 netAmount = grossAmount - forwardFee;

        // Backward: fee needed to yield netAmount
        uint256 backwardFee = JBFees.feeAmountResultingIn(netAmount, FEE);

        // Reconstructed gross = netAmount + backwardFee
        uint256 reconstructed = netAmount + backwardFee;

        // INVARIANT: reconstructed must be >= original gross (never undercharges)
        assertGe(reconstructed, grossAmount, "H1: Fee roundtrip undercharged - protocol loses value");

        // Also check the overshoot is bounded (at most 1 wei)
        assertLe(
            reconstructed - grossAmount,
            1,
            "H1: Fee roundtrip overshoot exceeds 1 wei"
        );
    }

    /// @notice Backward fee then forward fee must yield at least the desired net amount.
    function testFuzz_feeBackwardForward_neverUnderpays(uint256 desiredNet) public pure {
        desiredNet = bound(desiredNet, 1, type(uint128).max);

        // Backward: how much fee to add to get desiredNet after fee?
        uint256 feeToAdd = JBFees.feeAmountResultingIn(desiredNet, FEE);
        uint256 grossAmount = desiredNet + feeToAdd;

        // Forward: take fee from gross
        uint256 forwardFee = JBFees.feeAmountFrom(grossAmount, FEE);
        uint256 actualNet = grossAmount - forwardFee;

        // INVARIANT: actual net must be >= desired (payer never gets shortchanged)
        assertGe(actualNet, desiredNet, "H1b: Backward+forward yields less than desired");
    }

    /// @notice Fee accumulation across N splits must not exceed single-amount fee.
    function testFuzz_feeSplitAccumulation_bounded(uint256 totalAmount, uint8 numSplits) public pure {
        totalAmount = bound(totalAmount, 100, type(uint128).max);
        numSplits = uint8(bound(uint256(numSplits), 2, 50));

        // Fee on total amount
        uint256 singleFee = JBFees.feeAmountFrom(totalAmount, FEE);

        // Sum of fees on split amounts
        uint256 splitSize = totalAmount / numSplits;
        uint256 remainder = totalAmount - (splitSize * numSplits);
        uint256 accumulatedFee = 0;

        for (uint256 i = 0; i < numSplits; i++) {
            uint256 amount = splitSize + (i == numSplits - 1 ? remainder : 0);
            accumulatedFee += JBFees.feeAmountFrom(amount, FEE);
        }

        // INVARIANT: accumulated fee should be <= single fee (rounding can only reduce individual fees)
        assertLe(accumulatedFee, singleFee, "H1c: Split fees exceed single fee");

        // And the loss should be bounded by (numSplits - 1) wei
        assertLe(
            singleFee - accumulatedFee,
            uint256(numSplits) - 1,
            "H1c: Rounding loss exceeds N-1 wei bound"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H2: Bonding curve sequential cashouts must not extract more than single
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Cashing out tokens in two batches must yield <= cashing out all at once.
    function testFuzz_bondingCurve_noSuperadditivity(
        uint256 surplus,
        uint256 totalSupply,
        uint256 cashOutCount,
        uint256 cashOutTaxRate,
        uint256 splitPoint
    ) public pure {
        surplus = bound(surplus, 1e6, type(uint128).max);
        totalSupply = bound(totalSupply, 2, type(uint128).max);
        cashOutCount = bound(cashOutCount, 2, totalSupply);
        cashOutTaxRate = bound(cashOutTaxRate, 1, MAX_CASH_OUT_TAX_RATE - 1);
        splitPoint = bound(splitPoint, 1, cashOutCount - 1);

        // Single cashout
        uint256 singleReclaim = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);

        // Sequential: first batch
        uint256 firstReclaim = JBCashOuts.cashOutFrom(surplus, splitPoint, totalSupply, cashOutTaxRate);

        // After first batch: surplus reduced, supply reduced
        uint256 remainingSurplus = surplus - firstReclaim;
        uint256 remainingSupply = totalSupply - splitPoint;
        uint256 secondBatch = cashOutCount - splitPoint;

        uint256 secondReclaim = 0;
        if (remainingSupply > 0 && remainingSurplus > 0 && secondBatch > 0) {
            secondReclaim = JBCashOuts.cashOutFrom(remainingSurplus, secondBatch, remainingSupply, cashOutTaxRate);
        }

        uint256 totalSequential = firstReclaim + secondReclaim;

        // INVARIANT: sequential must not exceed single (subadditivity with tax)
        assertLe(
            totalSequential,
            singleReclaim + 1, // Allow 1 wei rounding tolerance
            "H2: Sequential cashout extracts more than single - superadditivity violation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H3: Many tiny cashouts - rounding accumulation
    // ═══════════════════════════════════════════════════════════════════

    /// @notice 100 cashouts of 1 token must not extract more than 100 tokens at once.
    function testFuzz_bondingCurve_tinyBatchRounding(
        uint256 surplus,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    ) public pure {
        surplus = bound(surplus, 1e18, type(uint96).max);
        totalSupply = bound(totalSupply, 200, type(uint96).max);
        cashOutTaxRate = bound(cashOutTaxRate, 1, MAX_CASH_OUT_TAX_RATE - 1);

        uint256 batchSize = 100;
        if (batchSize > totalSupply) batchSize = totalSupply / 2;
        if (batchSize == 0) return;

        // Single large cashout
        uint256 singleReclaim = JBCashOuts.cashOutFrom(surplus, batchSize, totalSupply, cashOutTaxRate);

        // Sequential tiny cashouts
        uint256 currentSurplus = surplus;
        uint256 currentSupply = totalSupply;
        uint256 totalTinyReclaim = 0;

        for (uint256 i = 0; i < batchSize; i++) {
            if (currentSupply == 0 || currentSurplus == 0) break;
            uint256 reclaim = JBCashOuts.cashOutFrom(currentSurplus, 1, currentSupply, cashOutTaxRate);
            totalTinyReclaim += reclaim;
            currentSurplus -= reclaim;
            currentSupply -= 1;
        }

        // INVARIANT: tiny batch total must not exceed single batch
        assertLe(
            totalTinyReclaim,
            singleReclaim + batchSize, // Allow batchSize wei rounding tolerance
            "H3: Tiny cashout rounding accumulates to exploit level"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H4: minCashOutCountFor guarantee - returned count must achieve desired output
    // ═══════════════════════════════════════════════════════════════════

    /// @notice minCashOutCountFor must return a count that, when used in cashOutFrom, yields >= desiredOutput.
    function testFuzz_minCashOutCountFor_achievesDesired(
        uint256 surplus,
        uint256 totalSupply,
        uint256 desiredOutput,
        uint256 cashOutTaxRate
    ) public pure {
        surplus = bound(surplus, 1e6, type(uint96).max);
        totalSupply = bound(totalSupply, 10, type(uint96).max);
        cashOutTaxRate = bound(cashOutTaxRate, 0, MAX_CASH_OUT_TAX_RATE - 1);
        desiredOutput = bound(desiredOutput, 1, surplus - 1);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);

        // Count must be within valid range
        assertLe(count, totalSupply, "H4: minCashOutCountFor exceeds totalSupply");

        // Forward computation must yield >= desired
        uint256 actualOutput = JBCashOuts.cashOutFrom(surplus, count, totalSupply, cashOutTaxRate);
        assertGe(actualOutput, desiredOutput, "H4: minCashOutCountFor does not achieve desired output");
    }

    /// @notice minCashOutCountFor must return the MINIMUM - count-1 must NOT achieve desired output.
    function testFuzz_minCashOutCountFor_isMinimal(
        uint256 surplus,
        uint256 totalSupply,
        uint256 desiredOutput,
        uint256 cashOutTaxRate
    ) public pure {
        surplus = bound(surplus, 1e10, type(uint96).max);
        totalSupply = bound(totalSupply, 100, type(uint96).max);
        cashOutTaxRate = bound(cashOutTaxRate, 0, MAX_CASH_OUT_TAX_RATE - 1);
        desiredOutput = bound(desiredOutput, 1, surplus / 2);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);

        if (count > 1 && count <= totalSupply) {
            uint256 outputAtCountMinus1 = JBCashOuts.cashOutFrom(surplus, count - 1, totalSupply, cashOutTaxRate);
            assertLt(
                outputAtCountMinus1,
                desiredOutput,
                "H4b: count-1 also achieves desired - minCashOutCountFor not minimal"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H5: Bonding curve cashOutCount == totalSupply returns exactly surplus
    // ═══════════════════════════════════════════════════════════════════

    /// @notice When cashing out the entire supply, must get exactly the surplus regardless of tax rate.
    function testFuzz_bondingCurve_fullCashout_returnsSurplus(
        uint256 surplus,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    ) public pure {
        surplus = bound(surplus, 1, type(uint128).max);
        totalSupply = bound(totalSupply, 1, type(uint128).max);
        cashOutTaxRate = bound(cashOutTaxRate, 0, MAX_CASH_OUT_TAX_RATE);

        uint256 reclaim = JBCashOuts.cashOutFrom(surplus, totalSupply, totalSupply, cashOutTaxRate);

        if (cashOutTaxRate == MAX_CASH_OUT_TAX_RATE) {
            // Max tax rate: nothing returned
            assertEq(reclaim, 0, "H5: Max tax rate should return 0");
        } else {
            // Full supply cashout: entire surplus returned
            assertEq(reclaim, surplus, "H5: Full supply cashout must return entire surplus");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H6: Bonding curve monotonicity - more tokens must yield more surplus
    // ═══════════════════════════════════════════════════════════════════

    /// @notice cashOutFrom must be monotonically non-decreasing in cashOutCount.
    function testFuzz_bondingCurve_monotonicity(
        uint256 surplus,
        uint256 totalSupply,
        uint256 countA,
        uint256 countB,
        uint256 cashOutTaxRate
    ) public pure {
        surplus = bound(surplus, 1e6, type(uint128).max);
        totalSupply = bound(totalSupply, 2, type(uint128).max);
        countA = bound(countA, 1, totalSupply - 1);
        countB = bound(countB, countA, totalSupply);
        cashOutTaxRate = bound(cashOutTaxRate, 0, MAX_CASH_OUT_TAX_RATE - 1);

        uint256 reclaimA = JBCashOuts.cashOutFrom(surplus, countA, totalSupply, cashOutTaxRate);
        uint256 reclaimB = JBCashOuts.cashOutFrom(surplus, countB, totalSupply, cashOutTaxRate);

        assertLe(reclaimA, reclaimB, "H6: Bonding curve is not monotonic");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H7: cashOutFrom never returns more than surplus
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_bondingCurve_boundedBySurplus(
        uint256 surplus,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    ) public pure {
        surplus = bound(surplus, 1, type(uint128).max);
        totalSupply = bound(totalSupply, 1, type(uint128).max);
        cashOutCount = bound(cashOutCount, 0, totalSupply);
        cashOutTaxRate = bound(cashOutTaxRate, 0, MAX_CASH_OUT_TAX_RATE);

        uint256 reclaim = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);

        assertLe(reclaim, surplus, "H7: Reclaim exceeds surplus - critical invariant broken");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H8: Fee on zero amount
    // ═══════════════════════════════════════════════════════════════════

    function test_feeOnZero() public pure {
        assertEq(JBFees.feeAmountFrom(0, FEE), 0, "H8: Fee on zero should be zero");
        assertEq(JBFees.feeAmountResultingIn(0, FEE), 0, "H8: Backward fee on zero should be zero");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  H9: Extreme bonding curve inputs - near overflow values
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_bondingCurve_extremeValues(
        uint256 surplus,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    ) public pure {
        // Use very large values near uint128.max
        surplus = bound(surplus, type(uint128).max / 2, type(uint128).max);
        totalSupply = bound(totalSupply, type(uint128).max / 2, type(uint128).max);
        cashOutTaxRate = bound(cashOutTaxRate, 0, MAX_CASH_OUT_TAX_RATE);

        uint256 cashOutCount = totalSupply / 2;

        // Should not revert (mulDiv handles overflow internally)
        uint256 reclaim = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);

        // Must still be bounded
        assertLe(reclaim, surplus, "H9: Extreme values cause reclaim > surplus");
    }
}
