// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

/// @notice Harness that exposes the internal `_simulateCycledRulesetBasedOn` for direct testing.
contract JBRulesetsHarness is JBRulesets {
    constructor(IJBDirectory directory) JBRulesets(directory) {}

    /// @notice Public wrapper for the internal function under test.
    function exposed_simulateCycledRulesetBasedOn(
        uint256 projectId,
        JBRuleset memory baseRuleset,
        bool allowMidRuleset
    )
        external
        view
        returns (JBRuleset memory)
    {
        return _simulateCycledRulesetBasedOn(projectId, baseRuleset, allowMidRuleset);
    }
}

/// @notice Tests for duration underflow fix in `_simulateCycledRulesetBasedOn`.
///
/// The fix guards against arithmetic underflow when `baseRuleset.duration >= block.timestamp`.
/// Without the fix, `block.timestamp - baseRuleset.duration + 1` wraps around to ~2^256,
/// causing `deriveStartFrom` to loop or revert.
///
/// NOTE: Through `currentOf`, the vulnerable code path (line 229) is structurally unreachable
/// with `duration >= block.timestamp` because:
///   - A queued successor starts at `base.start + k * base.duration` (k >= 1)
///   - So `block.timestamp >= base.start + base.duration > base.duration`
///   - Therefore `block.timestamp > base.duration`, meaning no underflow
///
/// The fix is defensive — it prevents underflow if the function is called with crafted parameters
/// or if future code changes introduce a new call path. These tests exercise the internal
/// function directly via a harness to verify the fix works.
contract TestDurationUnderflow is TestBaseWorkflow {
    JBRulesetsHarness private _harness;

    function setUp() public override {
        super.setUp();
        _harness = new JBRulesetsHarness(jbDirectory());
    }

    // ──────────────────────────────────────────────────────────────────────
    // Helper: build a minimal base ruleset struct for direct testing.
    // ──────────────────────────────────────────────────────────────────────

    function _makeBaseRuleset(uint48 start, uint32 duration, uint112 weight) internal pure returns (JBRuleset memory) {
        return JBRuleset({
            cycleNumber: 1,
            id: start, // rulesetId = start timestamp by convention
            basedOnId: 0,
            start: start,
            duration: duration,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
    }

    // ──────────────────────────────────────────────────────────────────────
    // Direct harness tests — exercise the fix at line 606.
    //
    // foundry.toml sets block_timestamp = 1643802347 (~1.64 billion).
    // A duration > 1643802347 triggers the underflow guard.
    //
    // Without the fix, `block.timestamp - duration + 1` wraps to ~2^256
    // and causes `deriveStartFrom` to loop indefinitely or revert.
    // With the fix, `mustStartAtOrAfter = 1` is used instead, and
    // `deriveStartFrom` returns `base.start + duration` (next cycle).
    // ──────────────────────────────────────────────────────────────────────

    /// @notice duration > block.timestamp: the fix prevents underflow.
    function test_harness_durationExceedsTimestamp_doesNotRevert() public view {
        // duration = 2 billion > block_timestamp (~1.64 billion) → fix kicks in.
        JBRuleset memory base = _makeBaseRuleset({start: 1, duration: uint32(2_000_000_000), weight: 1000e18});

        // Without the fix this reverts. With the fix, mustStartAtOrAfter = 1.
        JBRuleset memory result = _harness.exposed_simulateCycledRulesetBasedOn(1, base, true);

        // Should return a valid ruleset (cycle 2 since deriveStartFrom returns base.start + duration).
        assertGt(result.cycleNumber, 0, "Cycle number should be positive");
        assertEq(result.duration, 2_000_000_000, "Duration should be preserved");
    }

    /// @notice duration == block.timestamp: exact boundary of the guard.
    function test_harness_durationEqualsTimestamp_doesNotRevert() public view {
        // Use the exact block_timestamp as duration → duration >= block.timestamp → guard fires.
        uint32 exactDuration = uint32(block.timestamp);
        JBRuleset memory base = _makeBaseRuleset({start: 1, duration: exactDuration, weight: 1000e18});

        JBRuleset memory result = _harness.exposed_simulateCycledRulesetBasedOn(1, base, true);

        assertGt(result.cycleNumber, 0, "Cycle number should be positive");
        assertEq(result.duration, exactDuration, "Duration should match");
    }

    /// @notice duration = type(uint32).max: maximum possible duration.
    function test_harness_maxDuration_doesNotRevert() public view {
        JBRuleset memory base = _makeBaseRuleset({start: 1, duration: type(uint32).max, weight: 1000e18});

        JBRuleset memory result = _harness.exposed_simulateCycledRulesetBasedOn(1, base, true);

        assertGt(result.cycleNumber, 0, "Cycle number should be positive");
        assertEq(result.duration, type(uint32).max, "Duration should be max uint32");
    }

    /// @notice Normal case: duration < block.timestamp. No underflow even without the fix.
    function test_harness_normalDuration_noUnderflow() public view {
        // block_timestamp = 1643802347 >> 7 days. Normal case.
        JBRuleset memory base =
            _makeBaseRuleset({start: uint48(block.timestamp - 30 days), duration: uint32(7 days), weight: 1000e18});

        JBRuleset memory result = _harness.exposed_simulateCycledRulesetBasedOn(1, base, true);

        assertGt(result.cycleNumber, 1, "Should be past cycle 1 after 30 days");
        assertEq(result.duration, uint32(7 days), "Duration should match");
    }

    /// @notice allowMidRuleset = false: the duration branch is never taken.
    function test_harness_allowMidRulesetFalse_doesNotRevert() public view {
        JBRuleset memory base = _makeBaseRuleset({start: 1, duration: type(uint32).max, weight: 1000e18});

        // allowMidRuleset = false → mustStartAtOrAfter = block.timestamp + 1, no subtraction.
        JBRuleset memory result = _harness.exposed_simulateCycledRulesetBasedOn(1, base, false);

        assertGt(result.cycleNumber, 0, "Cycle number should be positive");
    }

    // ──────────────────────────────────────────────────────────────────────
    // Integration tests — currentOf with large durations
    //
    // These exercise the normal `currentOf` path (early return at line 191).
    // The underflow path (line 229) is not reachable here, but these tests
    // verify the protocol works correctly with large durations end-to-end.
    // ──────────────────────────────────────────────────────────────────────

    function _launchProject(uint32 duration) internal returns (uint256) {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = duration;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokens = new JBAccountingContext[](1);
        tokens[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokens});

        return jbController()
            .launchProjectFor({
                owner: multisig(),
                projectUri: "test",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: terminalConfigs,
                memo: ""
            });
    }

    /// @notice currentOf with a large duration (cycle 1, no cycling needed).
    function test_currentOf_largeDuration() public {
        uint256 projectId = _launchProject(uint32(2_000_000_000));

        JBRuleset memory ruleset = jbRulesets().currentOf(projectId);

        assertEq(ruleset.cycleNumber, 1, "Should be cycle 1");
        assertGt(ruleset.start, 0, "Should have a valid start time");
        assertEq(ruleset.duration, 2_000_000_000, "Duration should match");
    }

    /// @notice currentOf with max uint32 duration.
    function test_currentOf_maxDuration() public {
        uint256 projectId = _launchProject(type(uint32).max);

        JBRuleset memory ruleset = jbRulesets().currentOf(projectId);

        assertEq(ruleset.cycleNumber, 1, "Should be cycle 1");
        assertEq(ruleset.duration, type(uint32).max, "Duration should match");
    }

    /// @notice Sanity: currentOf with a normal duration still works.
    function test_currentOf_normalDuration() public {
        uint256 projectId = _launchProject(uint32(7 days));

        JBRuleset memory ruleset = jbRulesets().currentOf(projectId);

        assertEq(ruleset.cycleNumber, 1, "Should be cycle 1");
        assertEq(ruleset.duration, uint32(7 days), "Duration should match");
    }
}
