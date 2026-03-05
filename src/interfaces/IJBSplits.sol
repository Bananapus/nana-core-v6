// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSplit} from "./../structs/JBSplit.sol";
import {JBSplitGroup} from "./../structs/JBSplitGroup.sol";

/// @notice Stores and manages splits for each project.
interface IJBSplits {
    event SetSplit(
        uint256 indexed projectId, uint256 indexed rulesetId, uint256 indexed groupId, JBSplit split, address caller
    );

    /// @notice The ruleset ID used as a fallback when no splits are set for a specific ruleset.
    function FALLBACK_RULESET_ID() external view returns (uint256);

    /// @notice Returns the splits for a project, ruleset, and group.
    /// @param projectId The ID of the project to get the splits of.
    /// @param rulesetId The ID of the ruleset the splits should be active in.
    /// @param groupId The ID of the group to get the splits of.
    /// @return The splits.
    function splitsOf(uint256 projectId, uint256 rulesetId, uint256 groupId) external view returns (JBSplit[] memory);

    /// @notice Sets a project's split groups.
    /// @param projectId The ID of the project to set the split groups of.
    /// @param rulesetId The ID of the ruleset the split groups should be active in.
    /// @param splitGroups An array of split groups to set.
    function setSplitGroupsOf(uint256 projectId, uint256 rulesetId, JBSplitGroup[] calldata splitGroups) external;
}
