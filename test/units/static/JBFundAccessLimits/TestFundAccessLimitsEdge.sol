// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";

/// @notice Edge case tests for JBFundAccessLimits append behavior and packing.
/// The key finding is that setFundAccessLimitsFor uses .push() (append), not replace.
/// If called twice for the same rulesetId, limits accumulate rather than being replaced.
contract TestFundAccessLimitsEdge_Local is JBTest {
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));
    JBFundAccessLimits public limits;

    uint256 constant PROJECT_ID = 1;
    uint256 constant RULESET_ID = 100;
    address constant TERMINAL = address(0xBEEF);
    address constant TOKEN = address(0xCAFE);

    function setUp() public {
        limits = new JBFundAccessLimits(directory);

        // Mock controllerOf to return this contract (so we can call setFundAccessLimitsFor).
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(this))
        );
    }

    // ───────────────────── Append-not-replace bug
    // ─────────────────────

    /// @notice BUG: Calling setFundAccessLimitsFor twice accumulates limits instead of replacing.
    /// If a controller ever calls this twice for the same rulesetId (e.g., custom controller,
    /// reentrancy, or migration bug), limits double.
    function test_doubleSetting_accumulatesLimits() external {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 1000, currency: 1});

        JBFundAccessLimitGroup[] memory groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: TERMINAL, token: TOKEN, payoutLimits: payoutLimits, surplusAllowances: new JBCurrencyAmount[](0)
        });

        // First call — sets limit to 1000.
        limits.setFundAccessLimitsFor(PROJECT_ID, RULESET_ID, groups);

        // Verify first limit.
        uint256 limit1 = limits.payoutLimitOf(PROJECT_ID, RULESET_ID, TERMINAL, TOKEN, 1);
        assertEq(limit1, 1000, "First limit should be 1000");

        // Second call with SAME rulesetId — BUG: this APPENDS, not replaces.
        limits.setFundAccessLimitsFor(PROJECT_ID, RULESET_ID, groups);

        // Query all limits — should have 2 entries now (both with currency=1, amount=1000).
        JBCurrencyAmount[] memory allLimits = limits.payoutLimitsOf(PROJECT_ID, RULESET_ID, TERMINAL, TOKEN);

        // BUG CONFIRMED: Two entries instead of one.
        assertEq(allLimits.length, 2, "BUG: Limits accumulated instead of being replaced");
        assertEq(allLimits[0].amount, 1000, "First accumulated limit");
        assertEq(allLimits[1].amount, 1000, "Second accumulated limit");

        // The payoutLimitOf function returns the FIRST match, so it still returns 1000.
        // But the surplus calculation iterates ALL limits, effectively doubling the payout limit.
        uint256 limitQuery = limits.payoutLimitOf(PROJECT_ID, RULESET_ID, TERMINAL, TOKEN, 1);
        assertEq(limitQuery, 1000, "Query returns first match only");
    }

    // ───────────────────── Zero amount skipped
    // ─────────────────────

    /// @notice Zero-amount limits are not stored (filtered by amount > 0 check).
    function test_zeroAmount_skipped() external {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](2);
        payoutLimits[0] = JBCurrencyAmount({amount: 0, currency: 1}); // Should be skipped.
        payoutLimits[1] = JBCurrencyAmount({amount: 500, currency: 2});

        JBFundAccessLimitGroup[] memory groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: TERMINAL, token: TOKEN, payoutLimits: payoutLimits, surplusAllowances: new JBCurrencyAmount[](0)
        });

        limits.setFundAccessLimitsFor(PROJECT_ID, RULESET_ID, groups);

        // Only the non-zero limit should be stored.
        JBCurrencyAmount[] memory allLimits = limits.payoutLimitsOf(PROJECT_ID, RULESET_ID, TERMINAL, TOKEN);
        assertEq(allLimits.length, 1, "Zero-amount limit should not be stored");
        assertEq(allLimits[0].amount, 500, "Only non-zero limit stored");
        assertEq(allLimits[0].currency, 2, "Correct currency stored");
    }

    // ───────────────────── Currency ordering validation
    // ─────────────────────

    /// @notice Duplicate currencies in payout limits should revert.
    function test_currencyOrdering_rejectsEqual() external {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](2);
        payoutLimits[0] = JBCurrencyAmount({amount: 100, currency: 1});
        payoutLimits[1] = JBCurrencyAmount({amount: 200, currency: 1}); // Same currency!

        JBFundAccessLimitGroup[] memory groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: TERMINAL, token: TOKEN, payoutLimits: payoutLimits, surplusAllowances: new JBCurrencyAmount[](0)
        });

        vm.expectRevert(JBFundAccessLimits.JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering.selector);
        limits.setFundAccessLimitsFor(PROJECT_ID, RULESET_ID, groups);
    }

    /// @notice Descending currency order should revert.
    function test_currencyOrdering_rejectsDescending() external {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](2);
        payoutLimits[0] = JBCurrencyAmount({amount: 100, currency: 2});
        payoutLimits[1] = JBCurrencyAmount({amount: 200, currency: 1}); // Descending!

        JBFundAccessLimitGroup[] memory groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: TERMINAL, token: TOKEN, payoutLimits: payoutLimits, surplusAllowances: new JBCurrencyAmount[](0)
        });

        vm.expectRevert(JBFundAccessLimits.JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering.selector);
        limits.setFundAccessLimitsFor(PROJECT_ID, RULESET_ID, groups);
    }

    // ───────────────────── Packing round-trip
    // ─────────────────────

    /// @notice Fuzz: packed amount + currency unpack correctly for all inputs.
    function testFuzz_packingRoundTrip(uint224 amount, uint32 currency) external {
        // Skip zero amounts (they're filtered out).
        vm.assume(amount > 0);
        // Skip currency 0 since ordering requires > 0 for the first element.
        vm.assume(currency > 0);

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: amount, currency: currency});

        JBFundAccessLimitGroup[] memory groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: TERMINAL, token: TOKEN, payoutLimits: payoutLimits, surplusAllowances: new JBCurrencyAmount[](0)
        });

        // Use a unique rulesetId for each fuzz run to avoid accumulation bug.
        uint256 rulesetId = uint256(keccak256(abi.encode(amount, currency)));
        limits.setFundAccessLimitsFor(PROJECT_ID, rulesetId, groups);

        // Verify round-trip.
        JBCurrencyAmount[] memory result = limits.payoutLimitsOf(PROJECT_ID, rulesetId, TERMINAL, TOKEN);
        assertEq(result.length, 1, "Should have exactly one limit");
        assertEq(result[0].amount, amount, "Amount should round-trip correctly");
        assertEq(result[0].currency, currency, "Currency should round-trip correctly");
    }

    // ───────────────────── Query nonexistent returns zero
    // ─────────────────────

    /// @notice Querying a currency with no limit returns 0 (implicit default).
    function test_queryNonexistentCurrency_returnsZero() external view {
        uint256 limit = limits.payoutLimitOf(PROJECT_ID, RULESET_ID, TERMINAL, TOKEN, 999);
        assertEq(limit, 0, "Nonexistent currency should return 0");
    }
}
