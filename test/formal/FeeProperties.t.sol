// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";

/// @title FeeProperties
/// @notice Formal verification of fee arithmetic properties using symbolic execution.
/// @dev Works with both Halmos (check_* pattern) and forge test (testFuzz_* pattern).
///      Each property is dual-implemented: `check_` for Halmos and `testFuzz_` for forge.
contract FeeProperties is Test {
    uint256 constant MAX_FEE = JBConstants.MAX_FEE; // 1_000

    // =========================================================================
    // Property 1: Fee additivity error bound
    // =========================================================================
    /// @notice feeAmountFrom(a+b, fee) vs feeAmountFrom(a, fee) + feeAmountFrom(b, fee)
    ///         differ by at most 1 wei due to mulDiv rounding.
    function check_fee_additivity(uint256 a, uint256 b, uint256 feePercent) public pure {
        vm.assume(a > 0 && b > 0);
        vm.assume(a <= type(uint128).max && b <= type(uint128).max);
        vm.assume(a + b <= type(uint128).max); // No overflow
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 feeCombined = JBFees.feeAmountFrom(a + b, feePercent);
        uint256 feeSeparate = JBFees.feeAmountFrom(a, feePercent) + JBFees.feeAmountFrom(b, feePercent);

        // The difference should be at most 1 wei
        if (feeCombined >= feeSeparate) {
            assert(feeCombined - feeSeparate <= 1);
        } else {
            assert(feeSeparate - feeCombined <= 1);
        }
    }

    function testFuzz_fee_additivity(uint128 a, uint128 b, uint16 feePercent) public pure {
        vm.assume(a > 0 && b > 0);
        vm.assume(uint256(a) + uint256(b) <= type(uint128).max);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 feeCombined = JBFees.feeAmountFrom(uint256(a) + uint256(b), feePercent);
        uint256 feeSeparate = JBFees.feeAmountFrom(a, feePercent) + JBFees.feeAmountFrom(b, feePercent);

        uint256 diff = feeCombined >= feeSeparate ? feeCombined - feeSeparate : feeSeparate - feeCombined;

        assertLe(diff, 1, "Additivity: fee(a+b) and fee(a)+fee(b) should differ by at most 1 wei");
    }

    // =========================================================================
    // Property 2: Return fee consistency (protocol never undercharges)
    // =========================================================================
    /// @notice feeAmountResultingIn(netAmount, fee) >= feeAmountFrom(netAmount + feeAmountResultingIn(netAmount, fee),
    // fee) /         The reverse fee is always >= the forward fee on the gross amount, ensuring
    ///         the protocol never undercharges when returning held fees.
    function check_fee_returnConsistency(uint256 netAmount, uint256 feePercent) public pure {
        vm.assume(netAmount > 0 && netAmount <= type(uint128).max);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 reverseFee = JBFees.feeAmountResultingIn(netAmount, feePercent);
        uint256 grossAmount = netAmount + reverseFee;
        uint256 forwardFee = JBFees.feeAmountFrom(grossAmount, feePercent);

        // The reverse fee should be >= the forward fee on the reconstructed gross
        // This means the protocol never undercharges
        assert(reverseFee >= forwardFee);
    }

    function testFuzz_fee_returnConsistency(uint128 netAmount, uint16 feePercent) public pure {
        vm.assume(netAmount > 0);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 reverseFee = JBFees.feeAmountResultingIn(netAmount, feePercent);
        uint256 grossAmount = uint256(netAmount) + reverseFee;
        uint256 forwardFee = JBFees.feeAmountFrom(grossAmount, feePercent);

        assertGe(
            reverseFee,
            forwardFee,
            "Return consistency: reverse fee should be >= forward fee (protocol never undercharges)"
        );
    }

    // =========================================================================
    // Property 3: Fee-return round trip (reconstructed gross >= original, bounded overshoot)
    // =========================================================================
    /// @notice Take fee: fee1 = feeAmountFrom(amount, feePercent), net = amount - fee1.
    ///         Return fee: fee2 = feeAmountResultingIn(net, feePercent).
    ///         The reconstructed gross (net + fee2) should always be >= the original amount
    ///         (protocol never undercharges on fee return).
    ///         The overshoot is bounded by MAX_FEE / (MAX_FEE - feePercent): the rounding
    ///         error in fee1 (at most 1 wei of net) gets amplified by the fee ratio when
    ///         computing the reverse fee, plus 1 for the reverse mulDiv rounding itself.
    function check_fee_roundTrip(uint256 amount, uint256 feePercent) public pure {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 fee1 = JBFees.feeAmountFrom(amount, feePercent);
        uint256 net = amount - fee1;

        uint256 fee2 = JBFees.feeAmountResultingIn(net, feePercent);

        // Reconstructed gross should always be >= original (never undercharge)
        assert(net + fee2 >= amount);

        // Overshoot is bounded by the fee ratio amplification of rounding error.
        // The forward mulDiv floors by at most 1, making net up to 1 too large.
        // The reverse multiplies net by MAX_FEE/(MAX_FEE-fee), amplifying that error.
        uint256 maxOvershoot = MAX_FEE / (MAX_FEE - feePercent) + 1;
        assert(net + fee2 <= amount + maxOvershoot);
    }

    function testFuzz_fee_roundTrip(uint128 amount, uint16 feePercent) public pure {
        vm.assume(amount > 0);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 fee1 = JBFees.feeAmountFrom(amount, feePercent);
        uint256 net = uint256(amount) - fee1;

        uint256 fee2 = JBFees.feeAmountResultingIn(net, feePercent);

        assertGe(net + fee2, amount, "Round trip: reconstructed gross should be >= original (never undercharge)");

        uint256 maxOvershoot = MAX_FEE / (MAX_FEE - uint256(feePercent)) + 1;
        assertLe(
            net + fee2,
            uint256(amount) + maxOvershoot,
            "Round trip: overshoot should be bounded by fee ratio amplification"
        );
    }

    // =========================================================================
    // Property 4: Partial return monotonicity
    // =========================================================================
    /// @notice feeAmountResultingIn(a, fee) <= feeAmountResultingIn(b, fee) when a <= b.
    function check_fee_partialReturnMonotonicity(uint256 a, uint256 b, uint256 feePercent) public pure {
        vm.assume(a > 0 && b > 0);
        vm.assume(a <= type(uint128).max && b <= type(uint128).max);
        vm.assume(a <= b);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 feeA = JBFees.feeAmountResultingIn(a, feePercent);
        uint256 feeB = JBFees.feeAmountResultingIn(b, feePercent);

        assert(feeA <= feeB);
    }

    function testFuzz_fee_partialReturnMonotonicity(uint128 a, uint128 b, uint16 feePercent) public pure {
        vm.assume(a > 0 && b > 0);
        if (a > b) (a, b) = (b, a); // Ensure a <= b
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 feeA = JBFees.feeAmountResultingIn(a, feePercent);
        uint256 feeB = JBFees.feeAmountResultingIn(b, feePercent);

        assertLe(feeA, feeB, "Monotonicity: feeAmountResultingIn(a) <= feeAmountResultingIn(b) when a <= b");
    }

    // =========================================================================
    // Property 5: Held fee subtraction safety (fee never exceeds amount)
    // =========================================================================
    /// @notice For any heldFeeAmount > 0 and valid feePercent:
    ///         fee = feeAmountFrom(heldFeeAmount, feePercent) <= heldFeeAmount.
    ///         This guarantees leftover = heldFeeAmount - fee never underflows, and
    ///         leftover + fee == heldFeeAmount (exact decomposition).
    function check_fee_subtractionSafety(uint256 heldFeeAmount, uint256 feePercent) public pure {
        vm.assume(heldFeeAmount > 0 && heldFeeAmount <= type(uint128).max);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 fee = JBFees.feeAmountFrom(heldFeeAmount, feePercent);

        // Fee must never exceed the held amount (no underflow on subtraction)
        assert(fee <= heldFeeAmount);

        // Exact decomposition: leftover + fee == heldFeeAmount
        uint256 leftover = heldFeeAmount - fee;
        assert(leftover + fee == heldFeeAmount);
    }

    function testFuzz_fee_subtractionSafety(uint128 heldFeeAmount, uint16 feePercent) public pure {
        vm.assume(heldFeeAmount > 0);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 fee = JBFees.feeAmountFrom(heldFeeAmount, feePercent);

        assertLe(fee, heldFeeAmount, "Subtraction safety: fee should never exceed held amount");

        uint256 leftover = uint256(heldFeeAmount) - fee;
        assertEq(leftover + fee, heldFeeAmount, "Subtraction safety: leftover + fee should exactly equal held amount");
    }

    // =========================================================================
    // Property 6: Multi-split fee accumulation error bound
    // =========================================================================
    /// @notice After N splits each paying fee, total fee error vs single-payment fee
    ///         is bounded by N wei. For N=10: sum(feeAmountFrom(amount/N, fee), N times)
    ///         vs feeAmountFrom(amount, fee) differ by at most N.
    function check_fee_multiSplitAccumulation(uint256 amount, uint256 feePercent) public pure {
        vm.assume(amount >= 10); // Must be divisible into 10 parts
        vm.assume(amount <= type(uint128).max);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 N = 10;
        uint256 perSplit = amount / N;
        uint256 remainder = amount - (perSplit * N);

        // Single fee on total amount
        uint256 singleFee = JBFees.feeAmountFrom(amount, feePercent);

        // Sum of fees on each split
        uint256 splitFeeSum = 0;
        for (uint256 i = 0; i < N; i++) {
            // Last split gets any remainder from integer division
            uint256 splitAmount = (i == N - 1) ? perSplit + remainder : perSplit;
            splitFeeSum += JBFees.feeAmountFrom(splitAmount, feePercent);
        }

        // Difference should be bounded by N
        if (singleFee >= splitFeeSum) {
            assert(singleFee - splitFeeSum <= N);
        } else {
            assert(splitFeeSum - singleFee <= N);
        }
    }

    function testFuzz_fee_multiSplitAccumulation(uint128 amount, uint16 feePercent) public pure {
        vm.assume(amount >= 10);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 N = 10;
        uint256 perSplit = uint256(amount) / N;
        uint256 remainder = uint256(amount) - (perSplit * N);

        uint256 singleFee = JBFees.feeAmountFrom(amount, feePercent);

        uint256 splitFeeSum = 0;
        for (uint256 i = 0; i < N; i++) {
            uint256 splitAmount = (i == N - 1) ? perSplit + remainder : perSplit;
            splitFeeSum += JBFees.feeAmountFrom(splitAmount, feePercent);
        }

        uint256 diff = singleFee >= splitFeeSum ? singleFee - splitFeeSum : splitFeeSum - singleFee;

        assertLe(diff, N, "Multi-split accumulation: total rounding error should be bounded by N wei");
    }
}
