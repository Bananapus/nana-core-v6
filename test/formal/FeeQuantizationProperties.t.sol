// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";

/// @title FeeQuantizationProperties
/// @notice Formalizes WHY the payout path's per-component fee-basis quantization
///         (`JBPayoutSplitGroupLib.sol:227` — `amountEligibleForFees += feeEligible - (feeEligible % 40)`)
///         is the correct defense against fee-aggregation rounding drift, and bounds the gap that an
///         un-quantized aggregation (the cash-out path) incurs — the cash-out fee-aggregation quantization gap.
/// @dev The standard fee is `STANDARD_FEE/MAX_FEE = 25/1000 = 1/40`, i.e. `standardFeeAmountFrom(x) == x/40`.
///      Dual-implemented: `check_` for Halmos (÷40 is a small constant — more tractable than ÷1e12),
///      `testFuzz_` for forge.
contract FeeQuantizationProperties is Test {
    uint256 constant Q = 40; // STANDARD_FEE/MAX_FEE reduced denominator

    function _quantize(uint256 c) internal pure returns (uint256) {
        return c - (c % Q); // the payout path's basis quantization
    }

    // =========================================================================
    // Property 1: Quantizing a component's fee basis never changes its floored fee, and never over-states it
    // =========================================================================
    // @dev `check_` uses a uint16 domain: division-by-40 over full uint256 is SMT-intractable (model-search
    //      timeout), but the bounded domain is exhaustively provable (same approach as HalmosSmoke's uint16
    //      fee checks). The `testFuzz_` twins cover the full uint128 domain.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_quantize_preservesFlooredFeeAndNeverExceeds(uint16 c) public pure {
        uint256 q = _quantize(c);
        assert(q <= c); // quantization only ever lowers the basis
        assert(JBFees.standardFeeAmountFrom(q) == JBFees.standardFeeAmountFrom(c)); // ⌊q/40⌋ == ⌊c/40⌋
    }

    function testFuzz_quantize_preservesFlooredFeeAndNeverExceeds(uint256 c) public pure {
        uint256 q = _quantize(c);
        assertLe(q, c);
        assertEq(JBFees.standardFeeAmountFrom(q), JBFees.standardFeeAmountFrom(c));
    }

    // =========================================================================
    // Property 2 (core of the quantization gap): quantized aggregation is EXACTLY additive — the aggregate fee on the
    // sum of quantized bases equals the sum of per-component floored fees (zero drift). This is what the
    // payout path achieves and the cash-out path does NOT.
    // =========================================================================
    // forge-lint: disable-next-line(mixed-case-function)
    function check_quantizedAggregation_isExactlyAdditive(uint16 a, uint16 b, uint16 c) public pure {
        uint256 qa = _quantize(a);
        uint256 qb = _quantize(b);
        uint256 qc = _quantize(c);
        uint256 aggregate = JBFees.standardFeeAmountFrom(qa + qb + qc);
        uint256 sumOfFloors =
            JBFees.standardFeeAmountFrom(a) + JBFees.standardFeeAmountFrom(b) + JBFees.standardFeeAmountFrom(c);
        assert(aggregate == sumOfFloors); // ZERO drift when bases are quantized
    }

    function testFuzz_quantizedAggregation_isExactlyAdditive(uint128 a, uint128 b, uint128 c) public pure {
        uint256 qa = _quantize(a);
        uint256 qb = _quantize(b);
        uint256 qc = _quantize(c);
        uint256 aggregate = JBFees.standardFeeAmountFrom(qa + qb + qc);
        uint256 sumOfFloors =
            JBFees.standardFeeAmountFrom(a) + JBFees.standardFeeAmountFrom(b) + JBFees.standardFeeAmountFrom(c);
        assertEq(aggregate, sumOfFloors, "Quantized aggregation must be exactly additive (no drift)");
    }

    // =========================================================================
    // Property 3 (the gap, bounded): WITHOUT quantization, the aggregate fee on the raw sum can EXCEED
    // the sum of per-component floored fees, but only by at most (N-1) wei (here N=3 ⇒ ≤2). Never undercharges.
    // This is the exact quantization phenomenon the cash-out path exhibits.
    // =========================================================================
    // forge-lint: disable-next-line(mixed-case-function)
    function check_unquantizedAggregation_gapBoundedByNMinus1(uint16 a, uint16 b, uint16 c) public pure {
        uint256 aggregate = JBFees.standardFeeAmountFrom(uint256(a) + b + c);
        uint256 sumOfFloors =
            JBFees.standardFeeAmountFrom(a) + JBFees.standardFeeAmountFrom(b) + JBFees.standardFeeAmountFrom(c);
        assert(aggregate >= sumOfFloors); // never undercharges
        assert(aggregate - sumOfFloors <= 2); // gap ≤ N-1 = 2 for 3 components
    }

    function testFuzz_unquantizedAggregation_gapBoundedByNMinus1(uint128 a, uint128 b, uint128 c) public pure {
        uint256 aggregate = JBFees.standardFeeAmountFrom(uint256(a) + b + c);
        uint256 sumOfFloors =
            JBFees.standardFeeAmountFrom(a) + JBFees.standardFeeAmountFrom(b) + JBFees.standardFeeAmountFrom(c);
        assertGe(aggregate, sumOfFloors, "Aggregate fee never undercharges vs sum of floors");
        assertLe(aggregate - sumOfFloors, 2, "Un-quantized gap bounded by N-1 (=2 for 3 components)");
    }
}
