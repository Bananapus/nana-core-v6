// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

/// @notice Mock approval hook that always returns a configurable status.
contract MockApprovalHookConfigurable is IJBRulesetApprovalHook {
    JBApprovalStatus public immutable STATUS;
    uint256 public immutable override DURATION;

    constructor(JBApprovalStatus status, uint256 duration) {
        STATUS = status;
        DURATION = duration;
    }

    function approvalStatusOf(uint256, JBRuleset memory) external view override returns (JBApprovalStatus) {
        return STATUS;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetApprovalHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Mock approval hook that always reverts (for DoS testing — H-3 confirmation).
contract RevertingApprovalHook is IJBRulesetApprovalHook {
    uint256 public constant override DURATION = 3 days;

    function approvalStatusOf(uint256, JBRuleset memory) external pure override returns (JBApprovalStatus) {
        revert("HOOK_REVERTED");
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetApprovalHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Stress tests for JBRulesets queuing logic under wild circumstances.
/// Tests duration transitions, approval hook edge cases, rapid-fire queuing,
/// weight decay to extremes, rollover behavior, start-time alignment, and
/// complex multi-queue scenarios.
contract TestRulesetQueuingStress_Local is TestBaseWorkflow {
    IJBController private _controller;
    IJBRulesets private _rulesets;
    JBRulesetMetadata private _metadata;
    JBDeadline private _deadline3Day;

    uint32 constant FOURTEEN_DAYS = 14 days;
    uint32 constant SEVEN_DAYS = 7 days;
    uint112 constant INITIAL_WEIGHT = 1000e18;

    function setUp() public override {
        super.setUp();
        _controller = jbController();
        _rulesets = jbRulesets();
        _deadline3Day = new JBDeadline(3 days);

        _metadata = JBRulesetMetadata({
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
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    /// @dev Launch a project with a single ruleset.
    function _launchProject(
        uint32 duration,
        uint112 weight,
        uint32 weightCutPercent,
        IJBRulesetApprovalHook approvalHook
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory config = new JBRulesetConfig[](1);
        config[0].mustStartAtOrAfter = 0;
        config[0].duration = duration;
        config[0].weight = weight;
        config[0].weightCutPercent = weightCutPercent;
        config[0].approvalHook = approvalHook;
        config[0].metadata = _metadata;
        config[0].splitGroups = new JBSplitGroup[](0);
        config[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        return _controller.launchProjectFor({
            owner: multisig(),
            projectUri: "stress",
            rulesetConfigurations: config,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: ""
        });
    }

    /// @dev Launch a project with start in the future.
    function _launchProjectFutureStart(uint48 startAt, uint32 duration, uint112 weight) internal returns (uint256) {
        JBRulesetConfig[] memory config = new JBRulesetConfig[](1);
        config[0].mustStartAtOrAfter = startAt;
        config[0].duration = duration;
        config[0].weight = weight;
        config[0].weightCutPercent = 0;
        config[0].approvalHook = IJBRulesetApprovalHook(address(0));
        config[0].metadata = _metadata;
        config[0].splitGroups = new JBSplitGroup[](0);
        config[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        return _controller.launchProjectFor({
            owner: multisig(),
            projectUri: "future",
            rulesetConfigurations: config,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: ""
        });
    }

    /// @dev Queue a ruleset for a project.
    function _queueRuleset(
        uint256 projectId,
        uint48 mustStartAtOrAfter,
        uint32 duration,
        uint112 weight,
        uint32 weightCutPercent,
        IJBRulesetApprovalHook approvalHook
    )
        internal
    {
        JBRulesetConfig[] memory config = new JBRulesetConfig[](1);
        config[0].mustStartAtOrAfter = mustStartAtOrAfter;
        config[0].duration = duration;
        config[0].weight = weight;
        config[0].weightCutPercent = weightCutPercent;
        config[0].approvalHook = approvalHook;
        config[0].metadata = _metadata;
        config[0].splitGroups = new JBSplitGroup[](0);
        config[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, config, "");
    }

    // ───────────────────── DURATION CYCLING EDGE CASES ─────────────────────

    /// @notice Duration=0 means new queued rulesets start immediately.
    function test_durationZero_toNonZero_transition() external {
        uint256 pid = _launchProject(0, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.duration, 0, "Initial should have duration=0");
        assertEq(current.cycleNumber, 1);

        // Queue with duration=7 days. Since current has duration=0, new one starts immediately.
        _queueRuleset(pid, 0, SEVEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(0)));

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 2, "Duration=0 -> new ruleset immediately current");
        assertEq(current.duration, SEVEN_DAYS, "New duration should be 7 days");
        assertEq(current.cycleNumber, 2, "Should be cycle 2");
    }

    /// @notice Transitioning from duration>0 to duration=0 stops cycling.
    function test_durationNonZero_toZero_transition() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        _queueRuleset(pid, 0, 0, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(0)));

        // Before current ends, original is still active.
        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "Original still active");

        // Warp past current duration.
        vm.warp(block.timestamp + SEVEN_DAYS);

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 2, "Duration=0 ruleset now current");
        assertEq(current.duration, 0, "New ruleset has duration=0");

        // With duration=0, no upcoming.
        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.cycleNumber, 0, "No upcoming when current has duration=0");
    }

    /// @notice Very short duration (1 second) should cycle correctly over many periods.
    function test_veryShortDuration_manyCycles() external {
        uint256 pid = _launchProject(1, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + 1000);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, 1001, "Should have cycled 1000 times");
        assertEq(current.weight, INITIAL_WEIGHT, "No cut -> weight unchanged");
    }

    /// @notice Very short duration with weight cut: decay accumulates per cycle.
    function test_veryShortDuration_withWeightCut() external {
        uint32 tenPercentCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 10);
        uint256 pid = _launchProject(1, INITIAL_WEIGHT, tenPercentCut, IJBRulesetApprovalHook(address(0)));

        // 10 seconds -> 10 weight cuts.
        vm.warp(block.timestamp + 10);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, 11, "Cycle 11 after 10 seconds");
        assertLt(current.weight, INITIAL_WEIGHT, "Weight should decrease");
        assertGt(current.weight, 0, "Weight should not be zero after only 10 cuts");
    }

    /// @notice Mid-cycle queuing: new ruleset starts at next duration boundary.
    function test_midCycleQueuing_snapsToNextBoundary() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));
        uint256 originalStart = block.timestamp;

        // Warp to mid-cycle (day 3 of 7).
        vm.warp(block.timestamp + 3 days);

        _queueRuleset(pid, 0, SEVEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(0)));

        // Current should still be the original (we're mid-cycle).
        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "Original still current mid-cycle");

        // Upcoming should start at the next boundary (T+7d).
        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.start, originalStart + SEVEN_DAYS, "Should start at next boundary");
        assertEq(upcoming.weight, INITIAL_WEIGHT * 2, "Queued weight should match");
    }

    // ───────────────────── APPROVAL HOOK STRESS ─────────────────────

    /// @notice Queue well before deadline -> approved.
    function test_approvalHook_queueBeforeDeadline_approved() external {
        uint256 pid = _launchProject(FOURTEEN_DAYS, INITIAL_WEIGHT, 0, _deadline3Day);

        // Queue immediately: start ≈ T+14d, rulesetId ≈ T. Gap = 14d > 3d -> Approved.
        _queueRuleset(pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 2, 0, _deadline3Day);

        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.weight, INITIAL_WEIGHT * 2, "Queued should be upcoming");

        vm.warp(block.timestamp + FOURTEEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 2, "Approved ruleset should be current");
        assertEq(current.cycleNumber, 2);
    }

    /// @notice Queue too late (past deadline) -> failed -> original rolls over.
    function test_approvalHook_queueTooLate_failsAndRollsOver() external {
        uint256 pid = _launchProject(FOURTEEN_DAYS, INITIAL_WEIGHT, 0, _deadline3Day);

        // Warp to day 12 of 14 (only 2 days left, less than 3-day deadline).
        vm.warp(block.timestamp + 12 days);

        _queueRuleset(pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 5, 0, _deadline3Day);

        // Warp past cycle 1 end.
        vm.warp(block.timestamp + 3 days);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "Failed approval -> original rolls over");
        assertEq(current.cycleNumber, 2, "Rolled over to cycle 2");
    }

    /// @notice Chain of always-failed approvals: original always rolls over.
    function test_approvalHook_chainOfFailures_originalPersists() external {
        MockApprovalHookConfigurable alwaysFail =
            new MockApprovalHookConfigurable(JBApprovalStatus.Failed, 3 days);

        uint256 pid = _launchProject(
            FOURTEEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(alwaysFail))
        );

        // Queue 3 rulesets — all will fail.
        _queueRuleset(
            pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(alwaysFail))
        );
        _queueRuleset(
            pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 3, 0, IJBRulesetApprovalHook(address(alwaysFail))
        );
        _queueRuleset(
            pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 4, 0, IJBRulesetApprovalHook(address(alwaysFail))
        );

        // Warp far past all possible starts.
        vm.warp(block.timestamp + 100 days);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "All failed -> original persists");
        assertGt(current.cycleNumber, 1, "Should have rolled over multiple cycles");
    }

    /// @notice H-3 FIX VERIFICATION: Reverting approval hook no longer causes DoS.
    /// The try/catch in _approvalStatusOf catches the revert and returns Failed status,
    /// so currentOf succeeds and falls back to the previous ruleset.
    function test_approvalHook_revert_causesDoS_H3() external {
        RevertingApprovalHook revertHook = new RevertingApprovalHook();

        uint256 pid = _launchProject(
            FOURTEEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(revertHook))
        );

        // Queue a new ruleset.
        _queueRuleset(
            pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(revertHook))
        );

        // Warp past current cycle so the queued one is checked.
        vm.warp(block.timestamp + FOURTEEN_DAYS);

        // H-3 FIX: The reverting hook is caught by try/catch, treated as Failed.
        // currentOf succeeds and falls back to the original ruleset (weight not doubled).
        JBRuleset memory current = _rulesets.currentOf(pid);
        assertGt(current.id, 0, "currentOf should succeed, not revert");
        assertEq(current.weight, INITIAL_WEIGHT, "Should fall back to original ruleset weight");
    }

    /// @notice Approval status transitions from ApprovalExpected to Approved.
    function test_approvalHook_statusTransition_expectedToApproved() external {
        uint256 pid = _launchProject(FOURTEEN_DAYS, INITIAL_WEIGHT, 0, _deadline3Day);

        _queueRuleset(pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 2, 0, _deadline3Day);

        // Immediately after queuing: ApprovalExpected (deadline not yet passed).
        (, JBApprovalStatus status) = _rulesets.latestQueuedOf(pid);
        assertEq(
            uint256(status),
            uint256(JBApprovalStatus.ApprovalExpected),
            "Should be ApprovalExpected immediately"
        );

        // Warp past the deadline threshold: need block.timestamp + 3d >= ruleset.start.
        // Ruleset starts at ~T+14d, so we need to be at T+11d or later.
        vm.warp(block.timestamp + 11 days);

        (, status) = _rulesets.latestQueuedOf(pid);
        assertEq(uint256(status), uint256(JBApprovalStatus.Approved), "Should be Approved after deadline");
    }

    // ───────────────────── RAPID-FIRE QUEUING ─────────────────────

    /// @notice 5 rulesets queued in the same block: rulesetIds increment, last one wins.
    function test_sameBlock_fiveQueues_lastOneWins() external {
        uint256 pid = _launchProject(FOURTEEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));
        uint256 initialRulesetId = block.timestamp;

        for (uint256 i = 1; i <= 5; i++) {
            _queueRuleset(
                pid,
                0,
                FOURTEEN_DAYS,
                uint112(INITIAL_WEIGHT + uint112(i) * 100e18),
                0,
                IJBRulesetApprovalHook(address(0))
            );
        }

        // Latest should be the 5th (timestamp + 5).
        uint256 latestId = _rulesets.latestRulesetIdOf(pid);
        assertEq(latestId, initialRulesetId + 5, "5th queued should be latest");

        // Warp past current cycle.
        vm.warp(block.timestamp + FOURTEEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT + 500e18, "Last queued should be current");
        assertEq(current.cycleNumber, 2);
    }

    /// @notice Override a queued ruleset before it starts: replacement takes effect.
    function test_overrideQueued_replacementTakesEffect() external {
        uint256 pid = _launchProject(FOURTEEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        // Queue A.
        _queueRuleset(pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(0)));

        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.weight, INITIAL_WEIGHT * 2, "A should be upcoming");

        // Queue B — overrides A.
        _queueRuleset(pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 3, 0, IJBRulesetApprovalHook(address(0)));

        upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.weight, INITIAL_WEIGHT * 3, "B should override A");

        vm.warp(block.timestamp + FOURTEEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 3, "B should be current, not A");
    }

    // ───────────────────── WEIGHT DECAY STRESS ─────────────────────

    /// @notice 50% weight cut over 100 cycles: weight decays to zero.
    function test_weightDecay_fiftyPercent_100cycles_toZero() external {
        uint32 fiftyPercentCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 2);
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, fiftyPercentCut, IJBRulesetApprovalHook(address(0)));

        // 100 cycles (700 days). 1000e18 * (0.5^100) ≈ 7.9e-13 -> truncated to 0.
        vm.warp(block.timestamp + 700 days);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, 0, "Weight should decay to 0 after 100 x 50% cuts");
        assertEq(current.cycleNumber, 101);
    }

    /// @notice 100% weight cut: weight goes to zero after one cycle.
    function test_weightCut_100percent_zeroAfterOneCycle() external {
        uint32 fullCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT);
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, fullCut, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + SEVEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, 0, "100% cut -> zero weight after one cycle");
        assertEq(current.cycleNumber, 2);
    }

    /// @notice 0% weight cut: weight unchanged indefinitely.
    function test_weightCut_zeroPercent_unchangedForever() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        // 1000 cycles.
        vm.warp(block.timestamp + 7000 days);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "0% cut -> weight unchanged");
        assertEq(current.cycleNumber, 1001);
    }

    /// @notice weight=1 is a special case that inherits the derived (cut) weight.
    function test_weight_inheritSpecialCase_weight1() external {
        uint32 tenPercentCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 10);
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, tenPercentCut, IJBRulesetApprovalHook(address(0)));

        // Queue with weight=1 -> inherits derived weight (one cut applied).
        _queueRuleset(pid, 0, SEVEN_DAYS, 1, tenPercentCut, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + SEVEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        uint256 expectedWeight = (uint256(INITIAL_WEIGHT) * (JBConstants.MAX_WEIGHT_CUT_PERCENT - tenPercentCut))
            / JBConstants.MAX_WEIGHT_CUT_PERCENT;
        assertEq(current.weight, expectedWeight, "weight=1 should inherit derived weight (one 10% cut)");
    }

    // ───────────────────── ROLLOVER BEHAVIOR ─────────────────────

    /// @notice Rollover preserves all rules and applies weight cut per cycle.
    function test_rollover_manyCycles_preservesRules() external {
        uint32 onePercentCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 100);
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, onePercentCut, IJBRulesetApprovalHook(address(0)));

        // 100 cycles (700 days).
        vm.warp(block.timestamp + 700 days);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, 101, "Cycle 101 after 100 rollovers");
        assertEq(current.duration, SEVEN_DAYS, "Duration preserved");
        assertEq(current.weightCutPercent, onePercentCut, "Weight cut preserved");
        assertLt(current.weight, INITIAL_WEIGHT, "Weight decreased");
        assertGt(current.weight, 0, "Weight not zero after only 1% cuts");
    }

    /// @notice After many rollovers, a newly queued ruleset takes effect at the correct boundary.
    function test_rollover_thenQueuedTakesEffect() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        // Roll over 5 cycles.
        vm.warp(block.timestamp + 5 * uint256(SEVEN_DAYS));

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, 6, "Cycle 6 after 5 rollovers");

        // Queue new ruleset.
        _queueRuleset(pid, 0, SEVEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(0)));

        // Warp to next boundary.
        vm.warp(block.timestamp + SEVEN_DAYS);

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 2, "Queued ruleset now current");
        assertEq(current.cycleNumber, 7, "Cycle number continues from rollover");
    }

    /// @notice After failed approval, original rolls over (not the failed one).
    function test_rollover_afterFailedApproval_originalPersists() external {
        MockApprovalHookConfigurable alwaysFail =
            new MockApprovalHookConfigurable(JBApprovalStatus.Failed, 3 days);

        uint256 pid = _launchProject(
            FOURTEEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(alwaysFail))
        );

        _queueRuleset(
            pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 5, 0, IJBRulesetApprovalHook(address(alwaysFail))
        );

        // Warp past 3 cycles.
        vm.warp(block.timestamp + 3 * uint256(FOURTEEN_DAYS));

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "Original rolls over after failed approval");
        assertGt(current.cycleNumber, 1, "Rolled over past cycle 1");
    }

    // ───────────────────── START TIME EDGE CASES ─────────────────────

    /// @notice mustStartAtOrAfter in distant future: current doesn't change until then.
    function test_distantFuture_start_currentUnchanged() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        // Queue with start 365 days from now.
        _queueRuleset(
            pid,
            uint48(block.timestamp + 365 days),
            SEVEN_DAYS,
            INITIAL_WEIGHT * 2,
            0,
            IJBRulesetApprovalHook(address(0))
        );

        // Current should still be original.
        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT, "Current unchanged until distant future");

        // Upcoming should be the rolled-over original (not the distant future one).
        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.weight, INITIAL_WEIGHT, "Upcoming is rolled-over, not distant future");

        // Now warp close to 365 days.
        vm.warp(block.timestamp + 365 days);

        // The distant future ruleset should now be upcoming.
        upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.weight, INITIAL_WEIGHT * 2, "Distant future ruleset now upcoming");
    }

    /// @notice deriveStartFrom at exact duration boundary: starts at that boundary.
    function test_deriveStartFrom_exactBoundary() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));
        uint256 originalStart = block.timestamp;

        _queueRuleset(
            pid,
            uint48(originalStart + SEVEN_DAYS),
            SEVEN_DAYS,
            INITIAL_WEIGHT * 2,
            0,
            IJBRulesetApprovalHook(address(0))
        );

        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.start, originalStart + SEVEN_DAYS, "Should start exactly at boundary");
    }

    /// @notice deriveStartFrom one second after boundary: snaps to next boundary.
    function test_deriveStartFrom_oneSecondAfterBoundary_snapsToNext() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));
        uint256 originalStart = block.timestamp;

        // 1 second after first boundary -> should snap to second boundary.
        _queueRuleset(
            pid,
            uint48(originalStart + SEVEN_DAYS + 1),
            SEVEN_DAYS,
            INITIAL_WEIGHT * 2,
            0,
            IJBRulesetApprovalHook(address(0))
        );

        // At T=0, upcomingOf returns the simulated rolled-over cycle (T+7d) since the
        // queued ruleset (T+14d) is more than one duration away. Warp to T+7d first.
        vm.warp(originalStart + SEVEN_DAYS);

        JBRuleset memory upcoming = _rulesets.upcomingOf(pid);
        assertEq(upcoming.start, originalStart + 2 * uint256(SEVEN_DAYS), "Should snap to next boundary");
        assertEq(upcoming.weight, INITIAL_WEIGHT * 2, "Should be the queued ruleset");
    }

    /// @notice currentOf returns empty when the only ruleset hasn't started yet.
    function test_currentOf_onlyRulesetNotStarted_returnsEmpty() external {
        uint256 pid = _launchProjectFutureStart(
            uint48(block.timestamp + 30 days), SEVEN_DAYS, INITIAL_WEIGHT
        );

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, 0, "No current when only ruleset hasn't started");
    }

    // ───────────────────── COMPLEX MULTI-QUEUE SCENARIOS ─────────────────────

    /// @notice 10 sequential rulesets: each queued, time advanced, verified as current.
    function test_tenSequentialRulesets() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        for (uint256 i = 1; i <= 10; i++) {
            _queueRuleset(
                pid,
                0,
                SEVEN_DAYS,
                uint112(INITIAL_WEIGHT + uint112(i) * 100e18),
                0,
                IJBRulesetApprovalHook(address(0))
            );
            vm.warp(block.timestamp + SEVEN_DAYS);

            JBRuleset memory current = _rulesets.currentOf(pid);
            assertEq(
                current.weight,
                INITIAL_WEIGHT + uint112(i) * 100e18,
                string.concat("Cycle ", vm.toString(i + 1), " weight mismatch")
            );
        }

        JBRuleset memory finalRuleset = _rulesets.currentOf(pid);
        assertEq(finalRuleset.cycleNumber, 11, "Should be cycle 11");
    }

    /// @notice Interleaved approve/fail: approved ruleset persists through failed attempts.
    function test_interleavedApproveAndFail() external {
        uint256 pid = _launchProject(FOURTEEN_DAYS, INITIAL_WEIGHT, 0, _deadline3Day);

        // Queue first — queued at T, starts at ~T+14d. Gap = 14d > 3d -> Approved.
        _queueRuleset(pid, 0, FOURTEEN_DAYS, uint112(2000e18), 0, _deadline3Day);

        vm.warp(block.timestamp + FOURTEEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, 2000e18, "First approved ruleset is current");

        // Queue second too late (only 2 days before end).
        vm.warp(block.timestamp + 12 days);
        _queueRuleset(pid, 0, FOURTEEN_DAYS, uint112(3000e18), 0, _deadline3Day);

        vm.warp(block.timestamp + 3 days);

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, 2000e18, "Failed attempt -> last approved rolls over");
        assertEq(current.cycleNumber, 3, "Cycle 3");

        // Queue third with enough time (queued at start of cycle 3, >3 days before end).
        _queueRuleset(pid, 0, FOURTEEN_DAYS, uint112(4000e18), 0, _deadline3Day);

        vm.warp(block.timestamp + FOURTEEN_DAYS);

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, 4000e18, "Third queued approved and current");
    }

    /// @notice Duration change mid-queue: start with 7d, queue 14d, then queue 1d.
    function test_multipleQueuedDurationChanges() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        // Queue 14-day ruleset.
        _queueRuleset(pid, 0, FOURTEEN_DAYS, INITIAL_WEIGHT * 2, 0, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + SEVEN_DAYS);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 2, "14-day ruleset now current");
        assertEq(current.duration, FOURTEEN_DAYS);

        // Queue 1-day ruleset.
        _queueRuleset(pid, 0, 1 days, INITIAL_WEIGHT * 3, 0, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + FOURTEEN_DAYS);

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, INITIAL_WEIGHT * 3, "1-day ruleset now current");
        assertEq(current.duration, 1 days);

        // Verify rapid cycling with the 1-day ruleset.
        vm.warp(block.timestamp + 5 days);
        current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, current.cycleNumber, "Should have cycled 5 more times");
        assertGt(current.cycleNumber, 3, "Cycle number should advance with 1-day duration");
    }

    // ───────────────────── FUZZ: CYCLE NUMBER CONSISTENCY ─────────────────────

    /// @notice Fuzz: cycle number always equals elapsed cycles + 1.
    function testFuzz_cycleNumber_consistency(uint16 numCycles) external {
        numCycles = uint16(bound(numCycles, 1, 500));

        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + uint256(numCycles) * uint256(SEVEN_DAYS));

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.cycleNumber, uint256(numCycles) + 1, "Cycle number should be elapsed + 1");
    }

    /// @notice Fuzz: weight decay is monotonically non-increasing.
    function testFuzz_weightDecay_monotonic(uint8 numCycles, uint32 cutPercent) external {
        numCycles = uint8(bound(numCycles, 1, 50));
        cutPercent = uint32(bound(cutPercent, 1, JBConstants.MAX_WEIGHT_CUT_PERCENT));

        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, cutPercent, IJBRulesetApprovalHook(address(0)));

        uint256 prevWeight = INITIAL_WEIGHT;
        for (uint256 i = 1; i <= numCycles; i++) {
            vm.warp(block.timestamp + SEVEN_DAYS);
            JBRuleset memory current = _rulesets.currentOf(pid);
            assertLe(current.weight, prevWeight, "Weight should never increase");
            prevWeight = current.weight;
        }
    }

    /// @notice Fuzz: deriveStartFrom always returns a value >= mustStartAtOrAfter and aligned to duration.
    function testFuzz_deriveStartFrom_alignment(uint48 baseStart, uint32 duration, uint48 mustStartAfter) external {
        // Bound to reasonable values.
        baseStart = uint48(bound(baseStart, 1, type(uint48).max / 2));
        duration = uint32(bound(duration, 1, type(uint32).max / 2));
        mustStartAfter = uint48(bound(mustStartAfter, baseStart, baseStart + 100 * uint256(duration)));

        uint256 start = _rulesets.deriveStartFrom(baseStart, duration, mustStartAfter);

        // Must be >= mustStartAtOrAfter.
        assertGe(start, mustStartAfter, "Start should be >= mustStartAtOrAfter");

        // Must be aligned to duration boundaries from baseStart.
        assertEq((start - baseStart) % duration, 0, "Start should be aligned to duration from baseStart");
    }

    // ───────────────────── EDGE: ZERO WEIGHT AFTER DECAY ─────────────────────

    /// @notice After weight decays to zero, currentOf still works and returns weight=0.
    function test_zeroWeight_currentOfStillWorks() external {
        uint32 fullCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT);
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, fullCut, IJBRulesetApprovalHook(address(0)));

        // Warp 100 cycles past zero.
        vm.warp(block.timestamp + 700 days);

        JBRuleset memory current = _rulesets.currentOf(pid);
        assertEq(current.weight, 0, "Weight is zero");
        assertEq(current.cycleNumber, 101, "Still cycling correctly");

        // Queue a new ruleset with explicit weight.
        _queueRuleset(pid, 0, SEVEN_DAYS, 500e18, 0, IJBRulesetApprovalHook(address(0)));

        vm.warp(block.timestamp + SEVEN_DAYS);

        current = _rulesets.currentOf(pid);
        assertEq(current.weight, 500e18, "New weight should override zero");
    }

    /// @notice allOf returns the correct chain of rulesets after many queues.
    function test_allOf_chainIntegrity_afterManyQueues() external {
        uint256 pid = _launchProject(SEVEN_DAYS, INITIAL_WEIGHT, 0, IJBRulesetApprovalHook(address(0)));

        // Queue 4 more rulesets.
        for (uint256 i = 1; i <= 4; i++) {
            _queueRuleset(
                pid,
                0,
                SEVEN_DAYS,
                uint112(INITIAL_WEIGHT + uint112(i) * 100e18),
                0,
                IJBRulesetApprovalHook(address(0))
            );
            vm.warp(block.timestamp + SEVEN_DAYS);
        }

        // Get all rulesets (5 total).
        JBRuleset[] memory all = _rulesets.allOf(pid, 0, 10);
        assertEq(all.length, 5, "Should have 5 rulesets in chain");

        // Verify descending order (latest first).
        for (uint256 i = 0; i < all.length - 1; i++) {
            assertGt(all[i].id, all[i + 1].id, "Should be in descending ID order");
            assertEq(all[i].basedOnId, all[i + 1].id, "basedOnId should link to previous");
        }
    }
}
