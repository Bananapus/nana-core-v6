// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBCashOuts} from "../src/libraries/JBCashOuts.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";

/// @dev Wrapper so library reverts can be caught by vm.expectRevert (library calls are inlined otherwise).
contract CashOutCountForWrapper {
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
}

/// @title TestCashOutCountFor
/// @notice Tests for JBCashOuts.minCashOutCountFor — the inverse of the bonding curve.
contract TestCashOutCountFor is Test {
    uint256 constant MAX_TAX = JBConstants.MAX_CASH_OUT_TAX_RATE;

    CashOutCountForWrapper wrapper;

    function setUp() public {
        wrapper = new CashOutCountForWrapper();
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_zeroDesiredOutput() public pure {
        assertEq(JBCashOuts.minCashOutCountFor(100 ether, 0, 1000e18, 5000), 0);
    }

    function test_desiredOutputEqualsSurplus() public pure {
        uint256 count = JBCashOuts.minCashOutCountFor(100 ether, 100 ether, 1000e18, 5000);
        assertEq(count, 1000e18, "Should return totalSupply when desiredOutput == surplus");
    }

    function test_desiredOutputExceedsSurplus() public pure {
        uint256 count = JBCashOuts.minCashOutCountFor(100 ether, 200 ether, 1000e18, 5000);
        assertEq(count, 1000e18, "Should return totalSupply when desiredOutput > surplus");
    }

    function test_maxTaxRate_reverts() public {
        vm.expectRevert(JBCashOuts.JBCashOuts_DesiredOutputNotAchievable.selector);
        wrapper.minCashOutCountFor(100 ether, 50 ether, 1000e18, MAX_TAX);
    }

    function test_zeroTaxRate() public pure {
        // With 0 tax: out = S * c / T, so c = out * T / S.
        // surplus=100, desiredOutput=25, totalSupply=200 → c = 25*200/100 = 50.
        uint256 count = JBCashOuts.minCashOutCountFor(100, 25, 200, 0);
        assertEq(count, 50);
        assertGe(JBCashOuts.cashOutFrom(100, count, 200, 0), 25);
    }

    function test_zeroTaxRate_roundsUp() public pure {
        // surplus=7, desiredOutput=2, totalSupply=100.
        // Exact: c = 2*100/7 = 28.57... floor = 28. mulDiv(7, 28, 100) = 1 < 2. So c = 29.
        uint256 count = JBCashOuts.minCashOutCountFor(7, 2, 100, 0);
        assertGe(JBCashOuts.cashOutFrom(7, count, 100, 0), 2);
    }

    function test_zeroSurplus() public pure {
        // surplus=0, desiredOutput=1 → desiredOutput >= surplus → return totalSupply.
        uint256 count = JBCashOuts.minCashOutCountFor(0, 1, 1000e18, 5000);
        assertEq(count, 1000e18);
    }

    // =========================================================================
    // Specific examples
    // =========================================================================

    function test_halfTax_knownValues() public pure {
        // surplus=100, totalSupply=100, taxRate=5000 (50%).
        // Forward: cashOutFrom(100, 50, 100, 5000) = 37.
        uint256 forwardResult = JBCashOuts.cashOutFrom(100, 50, 100, 5000);
        assertEq(forwardResult, 37);

        // Inverse: to get 37 out, we need at least 50 tokens.
        uint256 count = JBCashOuts.minCashOutCountFor(100, 37, 100, 5000);
        assertEq(count, 50);
        assertGe(JBCashOuts.cashOutFrom(100, count, 100, 5000), 37);
    }

    function test_lowTax() public pure {
        // taxRate=1000 (10%).
        uint256 forwardResult = JBCashOuts.cashOutFrom(1000, 100, 1000, 1000);

        uint256 count = JBCashOuts.minCashOutCountFor(1000, forwardResult, 1000, 1000);
        assertGe(JBCashOuts.cashOutFrom(1000, count, 1000, 1000), forwardResult);
        assertLe(count, 100);
    }

    function test_highTax() public pure {
        // taxRate=9000 (90%).
        uint256 forwardResult = JBCashOuts.cashOutFrom(1000, 500, 1000, 9000);

        uint256 count = JBCashOuts.minCashOutCountFor(1000, forwardResult, 1000, 9000);
        assertGe(JBCashOuts.cashOutFrom(1000, count, 1000, 9000), forwardResult);
        assertLe(count, 500);
    }

    function test_realisticValues() public pure {
        // 10 ETH surplus, 1M tokens, 30% tax.
        uint256 surplus = 10 ether;
        uint256 totalSupply = 1_000_000e18;
        uint256 taxRate = 3000;
        uint256 cashOutAmount = 100_000e18;

        uint256 forwardResult = JBCashOuts.cashOutFrom(surplus, cashOutAmount, totalSupply, taxRate);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, forwardResult, totalSupply, taxRate);
        assertGe(JBCashOuts.cashOutFrom(surplus, count, totalSupply, taxRate), forwardResult);
        assertLe(count, cashOutAmount);
    }

    function test_smallSurplus_largeTotalSupply() public pure {
        // Edge case that trips up analytic formulas: surplus << totalSupply.
        uint256 surplus = 3178;
        uint256 totalSupply = 11_740_172_277_586_795;
        uint256 taxRate = 2;
        uint256 desiredOutput = 1589;

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, taxRate);
        assertGe(JBCashOuts.cashOutFrom(surplus, count, totalSupply, taxRate), desiredOutput);
    }

    // =========================================================================
    // Round-trip: minCashOutCountFor(S, cashOutFrom(S, c, T, r), T, r) <= c
    // =========================================================================

    function testFuzz_roundTrip_inverseOfForward(
        uint128 surplus,
        uint128 totalSupply,
        uint128 cashOutCount,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 0);
        vm.assume(cashOutCount > 0 && cashOutCount <= totalSupply);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX);

        uint256 output = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);
        vm.assume(output > 0);

        uint256 recoveredCount = JBCashOuts.minCashOutCountFor(surplus, output, totalSupply, cashOutTaxRate);

        // The recovered count should be <= the original count, because the forward function rounds down.
        assertLe(recoveredCount, cashOutCount, "Round-trip: recovered count should be <= original");
    }

    // =========================================================================
    // Correctness: cashOutFrom(S, minCashOutCountFor(S, out, T, r), T, r) >= out
    // =========================================================================

    function testFuzz_correctness_outputMeetsTarget(
        uint128 surplus,
        uint128 totalSupply,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 1);
        vm.assume(totalSupply > 0);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX);

        uint256 desiredOutput = uint256(surplus) / 2;
        vm.assume(desiredOutput > 0 && desiredOutput < surplus);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);

        uint256 actualOutput = JBCashOuts.cashOutFrom(surplus, count, totalSupply, cashOutTaxRate);
        assertGe(actualOutput, desiredOutput, "Correctness: output should meet or exceed target");
    }

    function testFuzz_correctness_fullRange(
        uint128 surplus,
        uint128 totalSupply,
        uint128 desiredOutput,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 0);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX);
        vm.assume(desiredOutput > 0 && desiredOutput < surplus);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);

        assertLe(count, totalSupply, "Count should not exceed totalSupply");

        uint256 actualOutput = JBCashOuts.cashOutFrom(surplus, count, totalSupply, cashOutTaxRate);
        assertGe(actualOutput, desiredOutput, "Output should meet target");
    }

    // =========================================================================
    // Monotonicity: larger desired output → larger or equal count
    // =========================================================================

    function testFuzz_monotonicity(
        uint128 surplus,
        uint128 totalSupply,
        uint128 out1,
        uint128 out2,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 2);
        vm.assume(totalSupply > 0);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX);
        vm.assume(out1 > 0 && out2 > 0);
        vm.assume(out1 < surplus && out2 < surplus);

        if (out1 > out2) (out1, out2) = (out2, out1);

        uint256 count1 = JBCashOuts.minCashOutCountFor(surplus, out1, totalSupply, cashOutTaxRate);
        uint256 count2 = JBCashOuts.minCashOutCountFor(surplus, out2, totalSupply, cashOutTaxRate);

        assertLe(count1, count2, "Monotonicity: larger output needs >= count");
    }

    // =========================================================================
    // Minimality: count - 1 should produce less than desiredOutput
    // =========================================================================

    function testFuzz_minimality(
        uint128 surplus,
        uint128 totalSupply,
        uint128 desiredOutput,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 1);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX);
        vm.assume(desiredOutput > 0 && desiredOutput < surplus);

        uint256 count = JBCashOuts.minCashOutCountFor(surplus, desiredOutput, totalSupply, cashOutTaxRate);

        vm.assume(count > 1);
        vm.assume(count < totalSupply);

        uint256 lesserOutput = JBCashOuts.cashOutFrom(surplus, count - 1, totalSupply, cashOutTaxRate);
        assertLt(lesserOutput, desiredOutput, "Minimality: count-1 should produce less than target");
    }
}
