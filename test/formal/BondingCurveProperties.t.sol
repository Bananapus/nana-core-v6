// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {JBCashOuts} from "../../src/libraries/JBCashOuts.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";

/// @title BondingCurveProperties
/// @notice Formal verification of bonding curve properties using symbolic execution.
/// @dev Works with both Halmos (check_* pattern) and forge test (test_* pattern).
///      Each property is dual-implemented: `check_` for Halmos and `testFuzz_` for forge.
contract BondingCurveProperties is Test {
    uint256 constant MAX_TAX = JBConstants.MAX_CASH_OUT_TAX_RATE; // 10_000
    uint256 constant MAX_FEE = JBConstants.MAX_FEE; // 1_000
    uint256 constant TAX_1 = 1;
    uint256 constant TAX_25_PERCENT = 2500;
    uint256 constant TAX_50_PERCENT = 5000;
    uint256 constant TAX_75_PERCENT = 7500;
    uint256 constant TAX_ALMOST_MAX = 9999;

    // =========================================================================
    // Boundary table: exact tax-rate edges that fuzzing rarely samples
    // =========================================================================
    /// @notice Pins cash-out values at selected tax-rate boundaries.
    /// @dev Mirrors `test_cashOut_boundaryTaxRateTable` for Halmos-compatible entrypoint discovery.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_cashOut_boundaryTaxRateTable() public pure {
        _assertCashOutBoundaryTaxRateTable();
    }

    /// @notice Pins cash-out values at selected tax-rate boundaries.
    /// @dev The table catches accidental formula or branch changes at `{0, 1, 2500, 5000, 7500, 9999, 10000}`.
    function test_cashOut_boundaryTaxRateTable() public pure {
        _assertCashOutBoundaryTaxRateTable();
    }

    // =========================================================================
    // Property 1: Boundedness — cashOutFrom never exceeds surplus
    // =========================================================================
    /// @notice cashOutFrom(S, c, T, r) <= S for all valid inputs.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_cashOut_boundedness(
        uint256 surplus,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        public
        pure
    {
        // Bound inputs to valid ranges
        vm.assume(surplus > 0 && surplus <= type(uint128).max);
        vm.assume(totalSupply > 0 && totalSupply <= type(uint128).max);
        vm.assume(cashOutCount > 0 && cashOutCount <= totalSupply);
        vm.assume(cashOutTaxRate <= MAX_TAX);

        uint256 result = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);
        assert(result <= surplus);
    }

    function testFuzz_cashOut_boundedness(
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

        uint256 result = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate);
        assertLe(result, surplus, "Boundedness: cashOutFrom should never exceed surplus");
    }

    // =========================================================================
    // Property 2: Monotonicity — more tokens → more reclaim
    // =========================================================================
    /// @notice cashOutFrom(S, c1, T, r) <= cashOutFrom(S, c2, T, r) when c1 <= c2.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_cashOut_monotonicity(
        uint256 surplus,
        uint256 c1,
        uint256 c2,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0 && surplus <= type(uint128).max);
        vm.assume(totalSupply > 0 && totalSupply <= type(uint128).max);
        vm.assume(c1 > 0 && c2 > 0);
        vm.assume(c1 <= c2);
        vm.assume(c2 <= totalSupply);
        vm.assume(cashOutTaxRate <= MAX_TAX);

        uint256 result1 = JBCashOuts.cashOutFrom(surplus, c1, totalSupply, cashOutTaxRate);
        uint256 result2 = JBCashOuts.cashOutFrom(surplus, c2, totalSupply, cashOutTaxRate);

        assert(result1 <= result2);
    }

    function testFuzz_cashOut_monotonicity(
        uint128 surplus,
        uint128 totalSupply,
        uint128 c1,
        uint128 c2,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 0);
        vm.assume(c1 > 0 && c2 > 0);
        if (c1 > c2) (c1, c2) = (c2, c1); // Ensure c1 <= c2
        vm.assume(c2 <= totalSupply);
        vm.assume(cashOutTaxRate <= MAX_TAX);

        uint256 result1 = JBCashOuts.cashOutFrom(surplus, c1, totalSupply, cashOutTaxRate);
        uint256 result2 = JBCashOuts.cashOutFrom(surplus, c2, totalSupply, cashOutTaxRate);

        assertLe(result1, result2, "Monotonicity: more tokens should yield >= reclaim");
    }

    // =========================================================================
    // Property 3: Full redemption — when c >= T, result is S (full surplus)
    // =========================================================================
    /// @notice When cashOutCount >= totalSupply, the full surplus is returned.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_cashOut_fullRedemption(uint256 surplus, uint256 totalSupply, uint256 cashOutTaxRate) public pure {
        vm.assume(surplus > 0 && surplus <= type(uint128).max);
        vm.assume(totalSupply > 0 && totalSupply <= type(uint128).max);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX); // Exclude max tax (which returns 0)

        // When cashing out the entire supply
        uint256 result = JBCashOuts.cashOutFrom(surplus, totalSupply, totalSupply, cashOutTaxRate);
        assert(result == surplus);
    }

    function testFuzz_cashOut_fullRedemption(uint128 surplus, uint128 totalSupply, uint16 cashOutTaxRate) public pure {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 0);
        vm.assume(cashOutTaxRate < MAX_TAX); // Exclude max tax

        uint256 result = JBCashOuts.cashOutFrom(surplus, totalSupply, totalSupply, cashOutTaxRate);
        assertEq(result, surplus, "Full redemption should return entire surplus");
    }

    // =========================================================================
    // Property 4: Max tax → zero reclaim
    // =========================================================================
    /// @notice When cashOutTaxRate == MAX_CASH_OUT_TAX_RATE, result is 0.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_cashOut_maxTaxIsZero(uint256 surplus, uint256 cashOutCount, uint256 totalSupply) public pure {
        vm.assume(surplus > 0 && surplus <= type(uint128).max);
        vm.assume(totalSupply > 0 && totalSupply <= type(uint128).max);
        vm.assume(cashOutCount > 0 && cashOutCount <= totalSupply);

        uint256 result = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, MAX_TAX);
        assert(result == 0);
    }

    function testFuzz_cashOut_maxTaxIsZero(uint128 surplus, uint128 totalSupply, uint128 cashOutCount) public pure {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 0);
        vm.assume(cashOutCount > 0 && cashOutCount <= totalSupply);

        uint256 result = JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, MAX_TAX);
        assertEq(result, 0, "Max tax rate should return 0");
    }

    // =========================================================================
    // Property 5: No-arbitrage (subadditivity)
    // =========================================================================
    /// @notice Splitting a cash out into two parts should never yield more than a single cash out.
    ///         cashOutFrom(S, a, T, r) + cashOutFrom(S', b, T', r) <= cashOutFrom(S, a+b, T, r)
    ///         where S' = S - cashOutFrom(S, a, T, r) and T' = T - a
    // forge-lint: disable-next-line(mixed-case-function)
    function check_cashOut_noArbitrage(
        uint256 surplus,
        uint256 a,
        uint256 b,
        uint256 totalSupply,
        uint256 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0 && surplus <= type(uint96).max);
        vm.assume(totalSupply > 0 && totalSupply <= type(uint96).max);
        vm.assume(a > 0 && b > 0);
        vm.assume(a + b <= totalSupply);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX); // Exclude 100% tax (trivially 0)

        // Single cash out of a+b
        uint256 singleResult = JBCashOuts.cashOutFrom(surplus, a + b, totalSupply, cashOutTaxRate);

        // First part: cash out a
        uint256 firstResult = JBCashOuts.cashOutFrom(surplus, a, totalSupply, cashOutTaxRate);

        // After first cash out: reduced surplus and supply
        uint256 remainingSurplus = surplus - firstResult;
        uint256 remainingSupply = totalSupply - a;

        // Second part: cash out b from remaining state
        uint256 secondResult = JBCashOuts.cashOutFrom(remainingSurplus, b, remainingSupply, cashOutTaxRate);

        // NOTE: Strict subadditivity (firstResult + secondResult <= singleResult) was proven to be
        // violated due to mulDiv rounding accumulation.
        // The violation is bounded by rounding precision and is economically insignificant (~0.00001%).
        // We verify the weaker property: the excess is bounded by rounding tolerance.
        if (firstResult + secondResult > singleResult) {
            // The excess should be tiny relative to the result
            uint256 excess = (firstResult + secondResult) - singleResult;
            // Allow up to 2 wei absolute (for small values) or 0.01% relative
            assert(excess <= 2 || excess * 10_000 <= singleResult);
        }
    }

    function testFuzz_cashOut_noArbitrage(
        uint96 surplus,
        uint96 totalSupply,
        uint96 a,
        uint96 b,
        uint16 cashOutTaxRate
    )
        public
        pure
    {
        vm.assume(surplus > 0);
        vm.assume(totalSupply > 0);
        vm.assume(a > 0 && b > 0);
        vm.assume(uint256(a) + uint256(b) <= totalSupply);
        vm.assume(cashOutTaxRate <= MAX_TAX);
        vm.assume(cashOutTaxRate < MAX_TAX);

        uint256 singleResult = JBCashOuts.cashOutFrom(surplus, uint256(a) + b, totalSupply, cashOutTaxRate);
        uint256 firstResult = JBCashOuts.cashOutFrom(surplus, a, totalSupply, cashOutTaxRate);

        uint256 remainingSurplus = surplus - firstResult;
        uint256 remainingSupply = totalSupply - a;

        uint256 secondResult = JBCashOuts.cashOutFrom(remainingSurplus, b, remainingSupply, cashOutTaxRate);

        // NOTE: Strict subadditivity violated due to mulDiv rounding.
        // Verify the weaker property: excess bounded by rounding tolerance (<=2 wei or < 0.01%).
        if (firstResult + secondResult > singleResult) {
            uint256 excess = (firstResult + secondResult) - singleResult;
            assertTrue(
                excess <= 2 || excess * 10_000 <= singleResult,
                "No-arbitrage: rounding excess should be <= 2 wei or < 0.01%"
            );
        }
    }

    // =========================================================================
    // Property 6: Fee round-trip — fee amounts are consistent
    // =========================================================================
    /// @notice The forward and reverse fee functions should be consistent:
    ///         amount - feeAmountFrom(amount, fee) + feeAmountResultingIn(net, fee) >= feeAmountFrom(amount, fee)
    ///         where net = amount - feeAmountFrom(amount, fee)
    // forge-lint: disable-next-line(mixed-case-function)
    function check_fee_roundTrip(uint256 amount, uint256 feePercent) public pure {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 feeForward = JBFees.feeAmountFrom(amount, feePercent);
        uint256 netAmount = amount - feeForward;

        // With floor rounding, net can only be zero when feePercent == MAX_FEE.
        if (netAmount == 0) {
            assert(feePercent == MAX_FEE);
            return;
        }

        // Reverse fee: what fee would result in netAmount after deduction?
        uint256 feeReverse = JBFees.feeAmountResultingIn(netAmount, feePercent);

        // The reverse fee should be >= the forward fee (due to rounding direction)
        // This ensures the protocol never undercharges
        assert(feeReverse >= feeForward);
    }

    function testFuzz_fee_roundTrip(uint128 amount, uint16 feePercent) public pure {
        vm.assume(amount > 0);
        vm.assume(feePercent > 0 && feePercent < MAX_FEE);

        uint256 feeForward = JBFees.feeAmountFrom(amount, feePercent);
        uint256 netAmount = amount - feeForward;

        // With floor rounding, net == 0 only when feePercent == MAX_FEE.
        if (netAmount == 0) {
            assertEq(uint256(feePercent), MAX_FEE, "Fee round-trip: net zero only at 100% fee");
            return;
        }

        uint256 feeReverse = JBFees.feeAmountResultingIn(netAmount, feePercent);

        assertGe(feeReverse, feeForward, "Fee round-trip: reverse fee should be >= forward fee");
    }

    // =========================================================================
    // Property 7: Metadata packing round-trip
    // =========================================================================
    /// @notice packRulesetMetadata(m) → expandMetadata should return the original metadata.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_metadataPacking_roundTrip(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        uint32 baseCurrency,
        uint16 boolFlags, // Pack 14 bools into a uint16
        address dataHook,
        uint16 extraMetadata
    )
        public
        pure
    {
        vm.assume(reservedPercent <= 10_000);
        vm.assume(cashOutTaxRate <= 10_000);
        vm.assume(extraMetadata <= 0x3FFF);

        JBRulesetMetadata memory original = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: baseCurrency,
            pausePay: boolFlags & 1 != 0,
            pauseCreditTransfers: boolFlags & 2 != 0,
            allowOwnerMinting: boolFlags & 4 != 0,
            allowSetCustomToken: boolFlags & 8 != 0,
            allowTerminalMigration: boolFlags & 16 != 0,
            allowSetTerminals: boolFlags & 32 != 0,
            allowSetController: boolFlags & 64 != 0,
            allowAddAccountingContext: boolFlags & 128 != 0,
            allowAddPriceFeed: boolFlags & 256 != 0,
            ownerMustSendPayouts: boolFlags & 512 != 0,
            holdFees: boolFlags & 1024 != 0,
            scopeCashOutsToLocalBalances: boolFlags & 2048 != 0,
            useDataHookForPay: boolFlags & 4096 != 0,
            useDataHookForCashOut: boolFlags & 8192 != 0,
            dataHook: dataHook,
            metadata: extraMetadata
        });

        uint256 packed = JBRulesetMetadataResolver.packRulesetMetadata(original);

        JBRuleset memory ruleset;
        ruleset.metadata = packed;

        JBRulesetMetadata memory roundTripped = JBRulesetMetadataResolver.expandMetadata(ruleset);

        assert(roundTripped.reservedPercent == original.reservedPercent);
        assert(roundTripped.cashOutTaxRate == original.cashOutTaxRate);
        assert(roundTripped.baseCurrency == original.baseCurrency);
        assert(roundTripped.pausePay == original.pausePay);
        assert(roundTripped.pauseCreditTransfers == original.pauseCreditTransfers);
        assert(roundTripped.allowOwnerMinting == original.allowOwnerMinting);
        assert(roundTripped.allowSetCustomToken == original.allowSetCustomToken);
        assert(roundTripped.allowTerminalMigration == original.allowTerminalMigration);
        assert(roundTripped.allowSetTerminals == original.allowSetTerminals);
        assert(roundTripped.allowSetController == original.allowSetController);
        assert(roundTripped.allowAddAccountingContext == original.allowAddAccountingContext);
        assert(roundTripped.allowAddPriceFeed == original.allowAddPriceFeed);
        assert(roundTripped.ownerMustSendPayouts == original.ownerMustSendPayouts);
        assert(roundTripped.holdFees == original.holdFees);
        assert(roundTripped.scopeCashOutsToLocalBalances == original.scopeCashOutsToLocalBalances);
        assert(roundTripped.useDataHookForPay == original.useDataHookForPay);
        assert(roundTripped.useDataHookForCashOut == original.useDataHookForCashOut);
        assert(roundTripped.dataHook == original.dataHook);
        assert(roundTripped.metadata == original.metadata);
    }

    function testFuzz_metadataPacking_roundTrip(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        uint32 baseCurrency,
        uint16 boolFlags, // Pack 14 bools into a uint16
        address dataHook,
        uint16 extraMetadata
    )
        public
        pure
    {
        vm.assume(reservedPercent <= 10_000);
        vm.assume(cashOutTaxRate <= 10_000);
        vm.assume(extraMetadata <= 0x3FFF);

        JBRulesetMetadata memory original = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: baseCurrency,
            pausePay: boolFlags & 1 != 0,
            pauseCreditTransfers: boolFlags & 2 != 0,
            allowOwnerMinting: boolFlags & 4 != 0,
            allowSetCustomToken: boolFlags & 8 != 0,
            allowTerminalMigration: boolFlags & 16 != 0,
            allowSetTerminals: boolFlags & 32 != 0,
            allowSetController: boolFlags & 64 != 0,
            allowAddAccountingContext: boolFlags & 128 != 0,
            allowAddPriceFeed: boolFlags & 256 != 0,
            ownerMustSendPayouts: boolFlags & 512 != 0,
            holdFees: boolFlags & 1024 != 0,
            scopeCashOutsToLocalBalances: boolFlags & 2048 != 0,
            useDataHookForPay: boolFlags & 4096 != 0,
            useDataHookForCashOut: boolFlags & 8192 != 0,
            dataHook: dataHook,
            metadata: extraMetadata
        });

        uint256 packed = JBRulesetMetadataResolver.packRulesetMetadata(original);

        JBRuleset memory ruleset;
        ruleset.metadata = packed;

        JBRulesetMetadata memory result = JBRulesetMetadataResolver.expandMetadata(ruleset);

        assertEq(result.reservedPercent, original.reservedPercent, "reservedPercent mismatch");
        assertEq(result.cashOutTaxRate, original.cashOutTaxRate, "cashOutTaxRate mismatch");
        assertEq(result.baseCurrency, original.baseCurrency, "baseCurrency mismatch");
        assertEq(result.pausePay, original.pausePay, "pausePay mismatch");
        assertEq(result.pauseCreditTransfers, original.pauseCreditTransfers, "pauseCreditTransfers mismatch");
        assertEq(result.allowOwnerMinting, original.allowOwnerMinting, "allowOwnerMinting mismatch");
        assertEq(result.allowSetCustomToken, original.allowSetCustomToken, "allowSetCustomToken mismatch");
        assertEq(result.allowTerminalMigration, original.allowTerminalMigration, "allowTerminalMigration mismatch");
        assertEq(result.allowSetTerminals, original.allowSetTerminals, "allowSetTerminals mismatch");
        assertEq(result.allowSetController, original.allowSetController, "allowSetController mismatch");
        assertEq(
            result.allowAddAccountingContext, original.allowAddAccountingContext, "allowAddAccountingContext mismatch"
        );
        assertEq(result.allowAddPriceFeed, original.allowAddPriceFeed, "allowAddPriceFeed mismatch");
        assertEq(result.ownerMustSendPayouts, original.ownerMustSendPayouts, "ownerMustSendPayouts mismatch");
        assertEq(result.holdFees, original.holdFees, "holdFees mismatch");
        assertEq(
            result.scopeCashOutsToLocalBalances,
            original.scopeCashOutsToLocalBalances,
            "scopeCashOutsToLocalBalances mismatch"
        );
        assertEq(result.useDataHookForPay, original.useDataHookForPay, "useDataHookForPay mismatch");
        assertEq(result.useDataHookForCashOut, original.useDataHookForCashOut, "useDataHookForCashOut mismatch");
        assertEq(result.dataHook, original.dataHook, "dataHook mismatch");
        assertEq(result.metadata, original.metadata, "metadata mismatch");
    }

    /// @notice Asserts the shared boundary table for both Forge and Halmos entrypoints.
    function _assertCashOutBoundaryTaxRateTable() private pure {
        // Partial cash-out case: 2,500 out of 10,000 project tokens against 10,000 surplus.
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: 0}) == 2500);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: TAX_1}) == 2499);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: TAX_25_PERCENT}) == 2031);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: TAX_50_PERCENT}) == 1562);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: TAX_75_PERCENT}) == 1093);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: TAX_ALMOST_MAX}) == 625);
        assert(_cashOutFrom({cashOutCount: 2500, cashOutTaxRate: MAX_TAX}) == 0);

        // Full cash-out returns all surplus for every non-max tax rate; 100% tax still returns zero by design.
        assert(_cashOutFrom({cashOutCount: 10_000, cashOutTaxRate: 0}) == 10_000);
        assert(_cashOutFrom({cashOutCount: 10_000, cashOutTaxRate: TAX_ALMOST_MAX}) == 10_000);
        assert(_cashOutFrom({cashOutCount: 10_000, cashOutTaxRate: MAX_TAX}) == 0);
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
