// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBRuleset} from "./../structs/JBRuleset.sol";
import {JBApprovalStatus} from "./../enums/JBApprovalStatus.sol";

/// @notice Determines whether the next ruleset in a project's queue is approved or rejected.
/// @dev Project rulesets are stored in a queue. Rulesets take effect after the previous ruleset in the queue ends, and
/// only if they are approved by the previous ruleset's approval hook.
interface IJBRulesetApprovalHook is IERC165 {
    /// @notice The minimum number of seconds that must pass for a queued ruleset to be considered approved.
    function DURATION() external view returns (uint256);

    /// @notice Returns the approval status of a given ruleset.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @param ruleset The ruleset to check the approval status of.
    /// @return The ruleset's approval status.
    function approvalStatusOf(uint256 projectId, JBRuleset memory ruleset) external view returns (JBApprovalStatus);
}
