// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {JBCashOuts} from "../../src/libraries/JBCashOuts.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";

/// @title CashOutInverseProperties
/// @notice Formal verification of `JBCashOuts.minCashOutCountFor` — the inverse of the bonding curve `cashOutFrom`.
/// @dev The forward curve is proven in `BondingCurveProperties`; its inverse had no property/symbolic coverage.
///      `minCashOutCountFor` binary-searches over `cashOutFrom` (512-bit `mulDiv` inside a loop), which is
///      intractable for a full symbolic proof — so the defining inverse relationship is proven by fuzz
///      (`testFuzz_*`, CI-gated), while the two closed-form early-return branches (no loop, no `mulDiv`) are proven
///      symbolically over their full domain by Halmos (`check_*`).
contract CashOutInverseProperties is Test {
    uint256 constant MAX_TAX = JBConstants.MAX_CASH_OUT_TAX_RATE; // 10_000

    /// @dev External wrapper so `vm.expectRevert` sees the revert at a lower call depth. `minCashOutCountFor` is an
    /// internal library function, so calling it directly inlines it into the test frame and `expectRevert` can't
    /// catch it.
    function minCashOutCountFor(
        uint256 surplus,
        uint256 desiredOutput,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        external
        pure
        returns (uint256)
    {
        return JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);
    }

    // =========================================================================
    // Property 1 (fuzz): tight inverse — count-1 undershoots, count meets the desired output
    // =========================================================================
    /// @notice For any achievable request (`0 < desired <= surplus`, non-max tax), the returned count is exactly the
    ///         minimum: cashing out `count` yields at least `desired`, and cashing out `count - 1` yields strictly
    ///         less. This is the defining correctness property of the inverse and guarantees callers never burn more
    ///         tokens than necessary to reach their target reclaim.
    function testFuzz_minCashOut_tightInverse(
        uint128 surplus,
        uint128 desiredOutput,
        uint128 totalSupply,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(totalSupply > 0);
        vm.assume(cashOutTaxRate < MAX_TAX);
        vm.assume(desiredOutput > 0 && desiredOutput <= surplus);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);

        assertGe(count, 1, "achievable request needs at least 1 token");
        assertLe(count, totalSupply, "count never exceeds total supply");

        // count meets the target.
        assertGe(
            JBCashOuts.cashOutFrom(surplus, count, totalSupply, cashOutTaxRate),
            desiredOutput,
            "count reclaims at least the desired output"
        );
        // count - 1 falls short: the count is minimal.
        assertLt(
            JBCashOuts.cashOutFrom(surplus, count - 1, totalSupply, cashOutTaxRate),
            desiredOutput,
            "count-1 reclaims strictly less than desired (minimality)"
        );
    }

    // =========================================================================
    // Property 2 (fuzz): the linear (zero-tax) branch is the exact ceiling of the proportional inverse
    // =========================================================================
    /// @notice With no cash-out tax the curve is linear (`out = surplus * count / totalSupply`), so the minimum
    ///         count is `ceil(desired * totalSupply / surplus)`. This pins the closed form the implementation uses.
    function testFuzz_minCashOut_linearBranchIsCeilDiv(
        uint128 surplus,
        uint128 desiredOutput,
        uint128 totalSupply
    )
        public
        pure
    {
        vm.assume(surplus > 0 && totalSupply > 0);
        vm.assume(desiredOutput > 0 && desiredOutput < surplus);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, 0);

        uint256 floorDiv = (uint256(desiredOutput) * totalSupply) / surplus;
        uint256 expected = ((uint256(desiredOutput) * totalSupply) % surplus == 0) ? floorDiv : floorDiv + 1;

        assertEq(count, expected, "linear branch equals ceil(desired * supply / surplus)");
    }

    // =========================================================================
    // Property 3 (fuzz): a 100% cash-out tax makes any positive output unachievable
    // =========================================================================
    /// @notice At the max tax rate no surplus is ever reclaimable, so any request for positive output must revert
    ///         rather than return a count that would burn tokens for nothing.
    function testFuzz_minCashOut_maxTaxReverts(uint128 surplus, uint128 desiredOutput, uint128 totalSupply) public {
        vm.assume(desiredOutput > 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBCashOuts.JBCashOuts_DesiredOutputNotAchievable.selector, uint256(desiredOutput), MAX_TAX, MAX_TAX
            )
        );
        this.minCashOutCountFor(surplus, desiredOutput, totalSupply, MAX_TAX);
    }

    // =========================================================================
    // Property 4 (Halmos + fuzz): zero desired output always needs zero tokens, for every tax rate
    // =========================================================================
    /// @notice The `desiredOutput == 0` short-circuit is checked before every other branch (including the max-tax
    ///         revert), so it returns 0 for the full input domain. Pure branch logic — Halmos proves it exhaustively.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_minCashOut_zeroDesiredIsZero(
        uint256 surplus,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        public
        pure
    {
        assert(JBCashOuts.minCashOutCountFor(surplus, 0, totalSupply, cashOutTaxRate) == 0);
    }

    function testFuzz_minCashOut_zeroDesiredIsZero(
        uint256 surplus,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        public
        pure
    {
        assertEq(JBCashOuts.minCashOutCountFor(surplus, 0, totalSupply, cashOutTaxRate), 0);
    }

    // =========================================================================
    // Property 5 (Halmos + fuzz): desired >= surplus requires the entire supply
    // =========================================================================
    /// @notice When the caller wants at least the whole surplus, the only way to reclaim it all is to cash out the
    ///         entire supply, so the function returns `totalSupply`. Pure branch logic (no loop / no `mulDiv`), so
    ///         Halmos proves it over the full domain (non-max tax; the desired-vs-surplus check runs after the
    ///         max-tax guard).
    // forge-lint: disable-next-line(mixed-case-function)
    function check_minCashOut_desiredGeSurplusIsTotalSupply(
        uint256 surplus,
        uint256 desiredOutput,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(desiredOutput > 0);
        vm.assume(desiredOutput >= surplus);
        vm.assume(cashOutTaxRate < MAX_TAX);
        assert(JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate) == totalSupply);
    }

    function testFuzz_minCashOut_desiredGeSurplusIsTotalSupply(
        uint128 surplus,
        uint128 desiredOutput,
        uint128 totalSupply,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(desiredOutput > 0);
        vm.assume(desiredOutput >= surplus);
        vm.assume(cashOutTaxRate < MAX_TAX);
        assertEq(JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate), totalSupply);
    }
}
