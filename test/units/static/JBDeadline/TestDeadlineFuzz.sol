// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBDeadline} from "../../../../src/JBDeadline.sol";
import {JBApprovalStatus} from "../../../../src/enums/JBApprovalStatus.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";

/// @notice Fuzz tests for JBDeadline approval hook.
contract TestDeadlineFuzz_Local is JBTest {
    JBDeadline deadline;

    uint256 constant DURATION = 3 days;

    function setUp() external {
        deadline = new JBDeadline(DURATION);
    }

    /// @notice DURATION is set correctly.
    function test_durationIsSet() external view {
        assertEq(deadline.DURATION(), DURATION, "DURATION should match");
    }

    /// @notice ERC165 support for IJBRulesetApprovalHook.
    function test_supportsInterface() external view {
        assertTrue(
            deadline.supportsInterface(type(IJBRulesetApprovalHook).interfaceId),
            "should support IJBRulesetApprovalHook"
        );
        assertTrue(deadline.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
    }

    //*********************************************************************//
    // --- Deterministic Status Tests ----------------------------------- //
    //*********************************************************************//

    /// @notice Ruleset queued after start time returns Failed.
    function test_queuedAfterStart_isFailed() external view {
        JBRuleset memory ruleset = _makeRuleset({queuedAt: 200, start: 100});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.Failed), "queued after start should be Failed");
    }

    /// @notice Ruleset queued too close to start returns Failed.
    function test_insufficientGap_isFailed() external {
        uint48 start = uint48(block.timestamp + 1 days);
        uint48 queued = start - uint48(DURATION) + 1; // 1 second short of required gap

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queued, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.Failed), "insufficient gap should be Failed");
    }

    /// @notice Ruleset with exactly enough gap and deadline not yet passed returns ApprovalExpected.
    function test_exactGap_deadlineNotPassed_isApprovalExpected() external {
        // queue far enough in advance, and start is still far in the future
        uint48 start = uint48(block.timestamp + 2 * DURATION + 100);
        uint48 queued = start - uint48(DURATION);

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queued, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.ApprovalExpected), "should be ApprovalExpected");
    }

    /// @notice Ruleset with enough gap and deadline passed returns Approved.
    function test_gapSufficient_deadlinePassed_isApproved() external {
        vm.warp(DURATION + 100); // ensure timestamp is large enough to avoid underflow
        uint48 start = uint48(block.timestamp + 1); // start is very soon
        uint48 queued = start - uint48(DURATION) - 1; // plenty of gap

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queued, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.Approved), "should be Approved");
    }

    //*********************************************************************//
    // --- Fuzz Tests --------------------------------------------------- //
    //*********************************************************************//

    /// @notice Status is always one of: Failed, ApprovalExpected, or Approved.
    function testFuzz_statusIsValid(uint48 queuedAt, uint48 start) external view {
        JBRuleset memory ruleset = _makeRuleset({queuedAt: queuedAt, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);

        assertTrue(
            status == JBApprovalStatus.Failed || status == JBApprovalStatus.ApprovalExpected
                || status == JBApprovalStatus.Approved,
            "status must be Failed, ApprovalExpected, or Approved"
        );
    }

    /// @notice If queued after start, always Failed.
    function testFuzz_queuedAfterStart_alwaysFailed(uint48 start) external view {
        // Ensure start is small enough that start+1 doesn't overflow uint48
        start = uint48(bound(uint256(start), 1, type(uint48).max - 1));
        uint48 queuedAt = start + 1; // queued AFTER start

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queuedAt, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.Failed), "queued after start always Failed");
    }

    /// @notice If gap is less than DURATION, always Failed.
    function testFuzz_gapTooSmall_alwaysFailed(uint48 start, uint48 gap) external view {
        gap = uint48(bound(uint256(gap), 0, DURATION - 1));
        // Ensure start >= gap to avoid underflow
        start = uint48(bound(uint256(start), gap, type(uint48).max));
        uint48 queuedAt = start - gap;

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queuedAt, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.Failed), "gap < DURATION always Failed");
    }

    /// @notice If gap >= DURATION and deadline passed, always Approved.
    function testFuzz_sufficientGap_deadlinePassed_approved(uint256 gapExtra) external {
        // gap = DURATION + gapExtra (always >= DURATION)
        gapExtra = bound(gapExtra, 0, 365 days);
        uint256 gap = DURATION + gapExtra;

        // Warp to a timestamp large enough so that start >= gap always holds.
        vm.warp(gap + 1);
        uint48 start = uint48(block.timestamp);
        uint48 queuedAt = start - uint48(gap);

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queuedAt, start: start});
        JBApprovalStatus status = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status), uint256(JBApprovalStatus.Approved), "sufficient gap + deadline passed -> Approved");
    }

    /// @notice Status monotonically transitions: ApprovalExpected -> Approved as time advances.
    function testFuzz_statusMonotonic(uint48 gap) external {
        gap = uint48(bound(uint256(gap), DURATION, type(uint32).max));
        // Ensure arithmetic doesn't overflow uint48
        uint48 start = uint48(bound(uint256(block.timestamp) + 2 * DURATION + 100, gap, type(uint48).max));
        uint48 queuedAt = start - gap;

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queuedAt, start: start});

        // At this point, start is far in the future -> ApprovalExpected
        JBApprovalStatus status1 = deadline.approvalStatusOf(1, ruleset);
        assertTrue(
            status1 == JBApprovalStatus.ApprovalExpected || status1 == JBApprovalStatus.Approved,
            "initial status should be ApprovalExpected or Approved"
        );

        // Warp to just past the deadline
        vm.warp(start - DURATION);
        JBApprovalStatus status2 = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status2), uint256(JBApprovalStatus.Approved), "after deadline should be Approved");

        // Once Approved, stays Approved
        vm.warp(start + 1000);
        JBApprovalStatus status3 = deadline.approvalStatusOf(1, ruleset);
        assertEq(uint256(status3), uint256(JBApprovalStatus.Approved), "should remain Approved");
    }

    /// @notice Different durations produce consistent results.
    function testFuzz_differentDurations(uint256 duration) external {
        duration = bound(duration, 1, 365 days);
        JBDeadline d = new JBDeadline(duration);

        // Ensure block.timestamp >= duration to avoid underflow.
        vm.warp(duration + 1);

        uint48 start = uint48(block.timestamp + 1);
        uint48 queuedAt = uint48(block.timestamp - duration);

        JBRuleset memory ruleset = _makeRuleset({queuedAt: queuedAt, start: start});
        JBApprovalStatus status = d.approvalStatusOf(1, ruleset);

        // With gap = duration + block.timestamp + 1 - (block.timestamp - duration) = 2*duration + 1
        // This is always >= duration, so status depends on whether deadline passed
        assertTrue(
            status == JBApprovalStatus.Approved || status == JBApprovalStatus.ApprovalExpected,
            "sufficient gap should be Approved or ApprovalExpected"
        );
    }

    //*********************************************************************//
    // --- Helpers ------------------------------------------------------ //
    //*********************************************************************//

    function _makeRuleset(uint48 queuedAt, uint48 start) internal pure returns (JBRuleset memory) {
        return JBRuleset({
            cycleNumber: 1,
            id: queuedAt,
            basedOnId: 0,
            start: start,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
    }
}
