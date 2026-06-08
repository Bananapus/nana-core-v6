// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {JBFixedPointNumber} from "../../src/libraries/JBFixedPointNumber.sol";

/// @title FixedPointNumberProperties
/// @notice Formal verification of `JBFixedPointNumber.adjustDecimals` (decimal precision conversion,
///         e.g. 6-decimal USDC <-> 18-decimal internal accounting).
/// @dev Dual-implemented: `check_` for Halmos (symbolic value, CONCRETE decimal pairs so the
///      `10 ** diff` factor is a compile-time constant Halmos can reason about), `testFuzz_` for forge.
///      The protocol's real decimal pairs are {0, 6, 8, 18}; 6<->18 (1e12) is the widest realistic gap.
contract FixedPointNumberProperties is Test {
    // =========================================================================
    // Property 1: Identity — no change when decimals == targetDecimals
    // =========================================================================
    // forge-lint: disable-next-line(mixed-case-function)
    function check_adjust_identity(uint256 value) public pure {
        assert(JBFixedPointNumber.adjustDecimals(value, 18, 18) == value);
        assert(JBFixedPointNumber.adjustDecimals(value, 6, 6) == value);
        assert(JBFixedPointNumber.adjustDecimals(value, 0, 0) == value);
    }

    function testFuzz_adjust_identity(uint256 value, uint8 decimals) public pure {
        vm.assume(decimals <= 36);
        assertEq(
            JBFixedPointNumber.adjustDecimals(value, decimals, decimals),
            value,
            "Identity: equal decimals must be a no-op"
        );
    }

    // =========================================================================
    // Property 2: Zero maps to zero (in every direction)
    // =========================================================================
    // forge-lint: disable-next-line(mixed-case-function)
    function check_adjust_zero() public pure {
        assert(JBFixedPointNumber.adjustDecimals(0, 6, 18) == 0);
        assert(JBFixedPointNumber.adjustDecimals(0, 18, 6) == 0);
        assert(JBFixedPointNumber.adjustDecimals(0, 0, 18) == 0);
    }

    // =========================================================================
    // Property 3: Scale-up is exact and perfectly reversible (no precision loss)
    // =========================================================================
    /// @notice For target > decimals: result == value * 10**k exactly, and scaling back down recovers value.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_adjust_scaleUpReversible(uint256 value) public pure {
        vm.assume(value <= type(uint128).max); // 1e12 * 2^128 < 2^256, so no overflow on the widest (6->18) gap
        uint256 up = JBFixedPointNumber.adjustDecimals(value, 6, 18);
        assert(up == value * 1e12); // exact scaling
        assert(up / 1e12 == value); // injective
        assert(JBFixedPointNumber.adjustDecimals(up, 18, 6) == value); // round-trip recovers original
    }

    function testFuzz_adjust_scaleUpReversible(uint128 value) public pure {
        uint256 up = JBFixedPointNumber.adjustDecimals(value, 6, 18);
        assertEq(up, uint256(value) * 1e12, "Scale-up: must be exact multiplication");
        assertEq(JBFixedPointNumber.adjustDecimals(up, 18, 6), value, "Scale-up then down must recover original");
    }

    // =========================================================================
    // Property 4: Scale-down floors, and down-then-up never gains, loses < 10**k
    // =========================================================================
    /// @notice For target < decimals: result == value / 10**k (floor). Re-scaling up never exceeds the
    ///         original and the lost amount is strictly bounded by 10**k (the truncated remainder).
    // forge-lint: disable-next-line(mixed-case-function)
    function check_adjust_scaleDownFloorBounded(uint256 value) public pure {
        uint256 down = JBFixedPointNumber.adjustDecimals(value, 18, 6);
        assert(down == value / 1e12); // floor semantics
        uint256 reup = JBFixedPointNumber.adjustDecimals(down, 6, 18);
        assert(reup <= value); // never creates value
        assert(value - reup < 1e12); // loss bounded by 10**k (the discarded remainder)
    }

    function testFuzz_adjust_scaleDownFloorBounded(uint256 value) public pure {
        uint256 down = JBFixedPointNumber.adjustDecimals(value, 18, 6);
        assertEq(down, value / 1e12, "Scale-down must floor");
        uint256 reup = JBFixedPointNumber.adjustDecimals(down, 6, 18);
        assertLe(reup, value, "Down-then-up must never gain value");
        assertLt(value - reup, 1e12, "Precision loss must be bounded by 10**k");
    }

    // =========================================================================
    // Property 5: Monotonic in value (both directions)
    // =========================================================================
    // forge-lint: disable-next-line(mixed-case-function)
    function check_adjust_monotonic(uint256 a, uint256 b) public pure {
        vm.assume(a <= b);
        vm.assume(b <= type(uint128).max); // bound the scale-up branch against overflow
        assert(JBFixedPointNumber.adjustDecimals(a, 6, 18) <= JBFixedPointNumber.adjustDecimals(b, 6, 18));
        assert(JBFixedPointNumber.adjustDecimals(a, 18, 6) <= JBFixedPointNumber.adjustDecimals(b, 18, 6));
    }

    function testFuzz_adjust_monotonic(uint128 a, uint128 b) public pure {
        if (a > b) (a, b) = (b, a);
        assertLe(
            JBFixedPointNumber.adjustDecimals(a, 6, 18),
            JBFixedPointNumber.adjustDecimals(b, 6, 18),
            "Monotonic (scale-up)"
        );
        assertLe(
            JBFixedPointNumber.adjustDecimals(a, 18, 6),
            JBFixedPointNumber.adjustDecimals(b, 18, 6),
            "Monotonic (scale-down)"
        );
    }
}
