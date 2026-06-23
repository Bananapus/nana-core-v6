// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The lifecycle states a queued ruleset can be in relative to its approval hook.
/// @dev `Empty` — no ruleset exists.
/// `Upcoming` — queued but not yet eligible for approval check.
/// `Active` — currently governing the project.
/// `ApprovalExpected` — provisionally approved and still replaceable before final approval.
/// Hooks should return it only when the ruleset will become `Approved` if no later ruleset replaces it first.
/// `Approved` — passed the approval hook and is final for its scheduled cycle. Later rulesets must derive from it
/// instead of replacing it within that cycle.
/// `Failed` — rejected by the approval hook; the previous ruleset continues.
enum JBApprovalStatus {
    Empty,
    Upcoming,
    Active,
    ApprovalExpected,
    Approved,
    Failed
}
