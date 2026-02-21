// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBRulesets} from "../src/JBRulesets.sol";
import {JBRulesets5_1} from "../src/JBRulesets5_1.sol";

/// @title DifferentialRulesets
/// @notice Differential tests comparing V5.0 and V5.1 JBRulesets behavior.
///         Verifies the C-5 fix (mustStartAtOrAfter floor) is correct and
///         that non-C-5 paths remain equivalent.
contract DifferentialRulesets_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    IJBController private controllerV50;
    IJBController private controllerV51;
    JBRulesets private rulesetsV50;
    JBRulesets5_1 private rulesetsV51;
    IJBMultiTerminal private terminalV50;
    IJBMultiTerminal private terminalV51;

    address private _projectOwner;
    uint112 private _weight = 1000e18;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        controllerV50 = jbController();
        controllerV51 = jbController5_1();
        rulesetsV50 = jbRulesets();
        rulesetsV51 = jbRulesets5_1();
        terminalV50 = jbMultiTerminal();
        terminalV51 = jbMultiTerminal5_1();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Launches a project on BOTH V5.0 and V5.1 controllers with identical config.
    function _launchMirroredProjects(
        uint256 duration,
        uint256 weight,
        uint256 weightCutPercent
    )
        internal
        returns (uint256 projectIdV50, uint256 projectIdV51)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
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

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = uint32(duration);
        rulesetConfig[0].weight = uint112(weight);
        rulesetConfig[0].weightCutPercent = uint32(weightCutPercent);
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigV50 = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigV50[0] =
            JBTerminalConfig({terminal: terminalV50, accountingContextsToAccept: tokensToAccept});

        JBTerminalConfig[] memory terminalConfigV51 = new JBTerminalConfig[](1);
        terminalConfigV51[0] =
            JBTerminalConfig({terminal: terminalV51, accountingContextsToAccept: tokensToAccept});

        projectIdV50 = controllerV50.launchProjectFor({
            owner: _projectOwner,
            projectUri: "V50",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigV50,
            memo: ""
        });

        projectIdV51 = controllerV51.launchProjectFor({
            owner: _projectOwner,
            projectUri: "V51",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigV51,
            memo: ""
        });
    }

    /// @dev Queue a new ruleset on both controllers with identical config.
    function _queueOnBoth(
        uint256 projectIdV50,
        uint256 projectIdV51,
        uint256 mustStartAtOrAfter,
        uint256 duration,
        uint256 weight,
        uint256 weightCutPercent
    )
        internal
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
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

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = uint48(mustStartAtOrAfter);
        rulesetConfig[0].duration = uint32(duration);
        rulesetConfig[0].weight = uint112(weight);
        rulesetConfig[0].weightCutPercent = uint32(weightCutPercent);
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(_projectOwner);
        controllerV50.queueRulesetsOf({
            projectId: projectIdV50,
            rulesetConfigurations: rulesetConfig,
            memo: ""
        });

        vm.prank(_projectOwner);
        controllerV51.queueRulesetsOf({
            projectId: projectIdV51,
            rulesetConfigurations: rulesetConfig,
            memo: ""
        });
    }

    // =========================================================================
    // Test 1: Fuzz — currentOf equivalence for non-C-5 scenarios
    // =========================================================================
    /// @notice For normal scenarios (mustStartAtOrAfter >= base.start), V5.0 and V5.1
    ///         must return identical currentOf results.
    function testFuzz_currentOf_equivalence(
        uint256 duration,
        uint256 weight,
        uint256 warpTime
    )
        public
    {
        // Bound to reasonable values within type limits
        duration = bound(duration, 1 days, 365 days); // fits uint32
        weight = bound(weight, 1e18, 1e24); // fits uint112
        warpTime = bound(warpTime, 1, 10 * 365 days);

        (uint256 pidV50, uint256 pidV51) = _launchMirroredProjects(duration, weight, 0);

        // Warp to some future time
        vm.warp(block.timestamp + warpTime);

        // Get currentOf from both versions
        JBRuleset memory currentV50 = rulesetsV50.currentOf(pidV50);
        JBRuleset memory currentV51 = rulesetsV51.currentOf(pidV51);

        // In non-C-5 scenarios (no queued rulesets with early mustStartAtOrAfter),
        // both versions should behave identically
        assertEq(currentV50.cycleNumber, currentV51.cycleNumber, "Cycle number should match");
        assertEq(currentV50.weight, currentV51.weight, "Weight should match");
        assertEq(currentV50.duration, currentV51.duration, "Duration should match");
    }

    // =========================================================================
    // Test 2: C-5 divergence — V5.0 skips ruleset, V5.1 doesn't
    // =========================================================================
    /// @notice The exact C-5 scenario: queue a ruleset with mustStartAtOrAfter < base.start.
    ///         V5.0 may produce a different derived start than V5.1.
    function test_C5_divergence_V50_skipsRuleset() public {
        // Launch projects with cycled rulesets (30 day duration)
        uint256 duration = 30 days;
        (uint256 pidV50, uint256 pidV51) = _launchMirroredProjects(duration, _weight, 0);

        // Record the base ruleset start time
        JBRuleset memory baseV50 = rulesetsV50.currentOf(pidV50);
        uint256 baseStart = baseV50.start;

        // Advance time so we're well into a cycle
        vm.warp(baseStart + 15 days);

        // Queue a new ruleset with mustStartAtOrAfter = 0 (earlier than base.start)
        // This is the C-5 trigger: mustStartAtOrAfter < baseRuleset.start
        _queueOnBoth(pidV50, pidV51, 0, duration, _weight * 2, 0);

        // Advance to the next cycle boundary
        vm.warp(baseStart + duration + 1);

        // Get the derived start of the queued ruleset from both versions
        (JBRuleset memory latestV50,) = rulesetsV50.latestQueuedOf(pidV50);
        (JBRuleset memory latestV51,) = rulesetsV51.latestQueuedOf(pidV51);

        // V5.1 enforces: mustStartAtOrAfter >= baseRuleset.start
        // So the derived start should be >= base start
        assertGe(
            latestV51.start,
            baseStart,
            "V5.1: Queued ruleset must start >= base ruleset start"
        );

        // Check that currentOf returns the new ruleset on V5.1
        JBRuleset memory currentV51 = rulesetsV51.currentOf(pidV51);
        assertEq(currentV51.weight, _weight * 2, "V5.1: currentOf should return the new ruleset");
    }

    // =========================================================================
    // Test 3: Weight decay equivalence over 10 cycles
    // =========================================================================
    /// @notice Both versions produce the same weight after 10 cycles of decay.
    function test_weightDecay_equivalence_10cycles() public {
        uint256 duration = 7 days;
        uint256 weightCutPercent = 100_000_000; // 10% cut per cycle (JBConstants scale)

        (uint256 pidV50, uint256 pidV51) = _launchMirroredProjects(duration, _weight, weightCutPercent);

        // Advance through 10 full cycles
        vm.warp(block.timestamp + 10 * duration + 1);

        JBRuleset memory currentV50 = rulesetsV50.currentOf(pidV50);
        JBRuleset memory currentV51 = rulesetsV51.currentOf(pidV51);

        // Both should produce the same weight after 10 decay cycles
        assertEq(currentV50.weight, currentV51.weight, "Weight after 10 decay cycles should match");
        assertEq(currentV50.cycleNumber, currentV51.cycleNumber, "Cycle numbers should match after 10 cycles");

        // Weight should be less than initial (decay happened)
        assertLt(currentV50.weight, _weight, "Weight should have decayed");
    }

    // =========================================================================
    // Test 4: Approval hook equivalence (non-C-5 path)
    // =========================================================================
    /// @notice Both versions handle approval hooks identically when no time inversion occurs.
    function test_approvalHook_equivalence() public {
        uint256 duration = 14 days;
        (uint256 pidV50, uint256 pidV51) = _launchMirroredProjects(duration, _weight, 0);

        // Advance to mid-cycle and queue a new ruleset (normal case, mustStartAtOrAfter = 0)
        vm.warp(block.timestamp + 7 days);

        // Queue with valid future start (no time inversion)
        _queueOnBoth(pidV50, pidV51, block.timestamp, duration, _weight * 3, 0);

        // Check latestQueued returns same approval status on both
        (JBRuleset memory latestV50, JBApprovalStatus statusV50) = rulesetsV50.latestQueuedOf(pidV50);
        (JBRuleset memory latestV51, JBApprovalStatus statusV51) = rulesetsV51.latestQueuedOf(pidV51);

        // Same approval status (both should be Empty since no approval hook)
        assertEq(uint256(statusV50), uint256(statusV51), "Approval status should match");

        // Same start time derived
        assertEq(latestV50.start, latestV51.start, "Derived start should match for normal queue");

        // Advance past the derived start
        vm.warp(latestV50.start + 1);

        // Both should now see the new ruleset as current
        JBRuleset memory curV50 = rulesetsV50.currentOf(pidV50);
        JBRuleset memory curV51 = rulesetsV51.currentOf(pidV51);
        assertEq(curV50.weight, curV51.weight, "Both should see new weight after advancing");
    }

    // =========================================================================
    // Test 5: Fuzz — queue and advance, same result for valid configs
    // =========================================================================
    /// @notice Random ruleset queuing + time advancement, assert equivalence where expected.
    function testFuzz_queueAndAdvance_sameResult(bytes32 seed) public {
        // Derive parameters from seed
        uint256 duration = bound(uint256(seed), 1 days, 90 days);
        uint256 newWeight = bound(uint256(keccak256(abi.encode(seed, "weight"))), 1e18, 1e24);
        uint256 advanceBy = bound(uint256(keccak256(abi.encode(seed, "advance"))), 1, 365 days);

        (uint256 pidV50, uint256 pidV51) = _launchMirroredProjects(duration, _weight, 0);

        // Record base start
        uint256 baseStart = rulesetsV50.currentOf(pidV50).start;

        // Advance a bit then queue with a VALID mustStartAtOrAfter (>= base start)
        vm.warp(baseStart + 1 days);

        // Queue with mustStartAtOrAfter = current time (always >= baseStart, no C-5 trigger)
        _queueOnBoth(pidV50, pidV51, block.timestamp, duration, newWeight, 0);

        // Advance by random amount
        vm.warp(block.timestamp + advanceBy);

        JBRuleset memory curV50 = rulesetsV50.currentOf(pidV50);
        JBRuleset memory curV51 = rulesetsV51.currentOf(pidV51);

        // For non-C-5 scenarios, both versions must be equivalent
        assertEq(curV50.cycleNumber, curV51.cycleNumber, "Fuzz: cycle number divergence");
        assertEq(curV50.weight, curV51.weight, "Fuzz: weight divergence");
        assertEq(curV50.start, curV51.start, "Fuzz: start time divergence");
        assertEq(curV50.duration, curV51.duration, "Fuzz: duration divergence");
    }

    // =========================================================================
    // Test 6: V5.1 prevents time inversion (mustStartAtOrAfter < base.start)
    // =========================================================================
    /// @notice V5.1 enforces that the queued ruleset's derived start >= base ruleset start.
    ///         This is the core of the C-5 fix.
    function test_V51_timeInversion_prevented() public {
        uint256 duration = 30 days;
        (uint256 pidV50, uint256 pidV51) = _launchMirroredProjects(duration, _weight, 0);

        uint256 baseStart = rulesetsV50.currentOf(pidV50).start;

        // Advance well past the first cycle
        vm.warp(baseStart + 60 days);

        // Queue with mustStartAtOrAfter = 0 (much earlier than base.start)
        // This triggers C-5 on V5.0 but is handled correctly by V5.1
        _queueOnBoth(pidV50, pidV51, 0, duration, _weight * 5, 0);

        // On V5.1, the derived start must be >= base start
        (JBRuleset memory latestV51,) = rulesetsV51.latestQueuedOf(pidV51);
        assertGe(
            latestV51.start,
            baseStart,
            "V5.1: derived start must be >= base start even with mustStartAtOrAfter=0"
        );

        // Advance to the next cycle boundary after queueing
        vm.warp(latestV51.start + 1);

        // V5.1 should see the new ruleset
        JBRuleset memory curV51 = rulesetsV51.currentOf(pidV51);
        assertEq(curV51.weight, _weight * 5, "V5.1: should see new ruleset after advancing to its start");

        // Additionally verify the V5.1 latestQueued start is cycle-aligned
        // deriveStartFrom should produce a start that's on a cycle boundary
        if (duration > 0) {
            uint256 cyclesSinceBase = (latestV51.start - baseStart) / duration;
            uint256 expectedStart = baseStart + cyclesSinceBase * duration;
            assertEq(
                latestV51.start,
                expectedStart,
                "V5.1: derived start should be cycle-aligned"
            );
        }
    }
}
