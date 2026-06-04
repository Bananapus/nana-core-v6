// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The lifecycle states a queued ruleset can be in relative to its approval hook.
/// @dev `Empty` — no ruleset exists.
/// `Upcoming` — queued but not yet eligible for approval check.
/// `Active` — currently governing the project.
/// `ApprovalExpected` — the deadline hasn't passed yet, expected to be approved.
/// `Approved` — passed the approval hook and will take effect.
/// `Failed` — rejected by the approval hook; the previous ruleset continues.
enum JBApprovalStatus {
    Empty,
    Upcoming,
    Active,
    ApprovalExpected,
    Approved,
    Failed
}
