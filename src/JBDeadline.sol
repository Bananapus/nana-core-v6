// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBApprovalStatus} from "./enums/JBApprovalStatus.sol";
import {IJBRulesetApprovalHook} from "./interfaces/IJBRulesetApprovalHook.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";

/// @notice A ruleset approval hook that enforces a queuing deadline. A ruleset that starts less than `DURATION` seconds
/// after it was queued is `Failed`, and the existing rules continue. This gives token holders a guaranteed notice
/// period before any project configuration changes take effect.
/// @dev `JBRulesets` moves a ruleset based on one that uses this hook to start no earlier than `DURATION` seconds after
/// it was queued, rounded up to the next cycle boundary of the ruleset it is based on. So a ruleset queued late in a
/// cycle, or under a `DURATION` longer than the cycle, is delayed to a later cycle rather than rejected, and the
/// current ruleset keeps cycling until then. A ruleset that currently returns `ApprovalExpected` will become `Approved`
/// once the deadline is reached unless it is replaced first.
contract JBDeadline is IJBRulesetApprovalHook {
    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The minimum number of seconds between the time a ruleset is queued and the time it starts. If the
    /// difference is greater than this number, the ruleset is `Approved`.
    uint256 public immutable override DURATION;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param duration The minimum number of seconds between the time a ruleset is queued and the time it starts for it
    /// to be `Approved`.
    constructor(uint256 duration) {
        DURATION = duration;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The approval status of a given ruleset.
    /// @param ruleset ruleset to check the status of.
    /// @return The ruleset's approval status.
    function approvalStatusOf(
        uint256, /* projectId */
        JBRuleset memory ruleset
    )
        public
        view
        override
        returns (JBApprovalStatus)
    {
        // The ruleset ID is the timestamp at which the ruleset was queued.
        // If the provided `rulesetId` timestamp is after the start timestamp, the ruleset has `Failed`.
        if (ruleset.id > ruleset.start) return JBApprovalStatus.Failed;

        unchecked {
            // If there aren't enough seconds between the time the ruleset was queued and the time it starts, it has
            // `Failed`.
            // Otherwise, if there is still time before the deadline, the ruleset's status is `ApprovalExpected`.
            // If we've already passed the deadline, the ruleset is `Approved`.
            return (ruleset.start - ruleset.id < DURATION)
                ? JBApprovalStatus.Failed
                // forge-lint: disable-next-line(block-timestamp)
                : (block.timestamp + DURATION < ruleset.start)
                    ? JBApprovalStatus.ApprovalExpected
                    : JBApprovalStatus.Approved;
        }
    }

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if this contract adheres to the specified interface.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBRulesetApprovalHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
