// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBApprovalStatus} from "./../enums/JBApprovalStatus.sol";
import {JBRuleset} from "./../structs/JBRuleset.sol";
import {IJBRulesetApprovalHook} from "./IJBRulesetApprovalHook.sol";

/// @notice Manages rulesets and queuing for projects.
interface IJBRulesets {
    event RulesetInitialized(
        uint256 indexed rulesetId, uint256 indexed projectId, uint256 indexed basedOnId, address caller
    );
    event RulesetQueued(
        uint256 indexed rulesetId,
        uint256 indexed projectId,
        uint256 duration,
        uint256 weight,
        uint256 weightCutPercent,
        IJBRulesetApprovalHook approvalHook,
        uint256 metadata,
        uint256 mustStartAtOrAfter,
        address caller
    );

    event WeightCacheUpdated(uint256 projectId, uint112 weight, uint256 weightCutMultiple, address caller);

    /// @notice Returns the ID of the latest ruleset queued for a project.
    /// @param projectId The ID of the project to get the latest ruleset ID of.
    /// @return The latest ruleset ID.
    function latestRulesetIdOf(uint256 projectId) external view returns (uint256);

    /// @notice Returns the approval status of the latest queued ruleset relative to the current ruleset.
    /// @param projectId The ID of the project to check.
    /// @return The approval status of the latest queued ruleset.
    function currentApprovalStatusForLatestRulesetOf(uint256 projectId) external view returns (JBApprovalStatus);

    /// @notice Returns the current ruleset for a project, deriving its properties from the base ruleset.
    /// @param projectId The ID of the project to get the current ruleset of.
    /// @return ruleset The current ruleset.
    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset);

    /// @notice Derives the cycle number from the base ruleset's parameters and a given start time.
    /// @param baseRulesetCycleNumber The cycle number of the base ruleset.
    /// @param baseRulesetStart The start time of the base ruleset.
    /// @param baseRulesetDuration The duration of the base ruleset.
    /// @param start The start time to derive the cycle number for.
    /// @return The derived cycle number.
    function deriveCycleNumberFrom(
        uint256 baseRulesetCycleNumber,
        uint256 baseRulesetStart,
        uint256 baseRulesetDuration,
        uint256 start
    )
        external
        returns (uint256);

    /// @notice Derives the start time from the base ruleset's parameters.
    /// @param baseRulesetStart The start time of the base ruleset.
    /// @param baseRulesetDuration The duration of the base ruleset.
    /// @param mustStartAtOrAfter The earliest time the derived ruleset can start.
    /// @return start The derived start time.
    function deriveStartFrom(
        uint256 baseRulesetStart,
        uint256 baseRulesetDuration,
        uint256 mustStartAtOrAfter
    )
        external
        view
        returns (uint256 start);

    /// @notice Derives the weight from the base ruleset's parameters, accounting for weight cuts over elapsed cycles.
    /// @param projectId The ID of the project.
    /// @param baseRulesetStart The start time of the base ruleset.
    /// @param baseRulesetDuration The duration of the base ruleset.
    /// @param baseRulesetWeight The weight of the base ruleset.
    /// @param baseRulesetWeightCutPercent The weight cut percent of the base ruleset.
    /// @param baseRulesetCacheId The cache ID of the base ruleset.
    /// @param start The start time to derive the weight for.
    /// @return weight The derived weight.
    function deriveWeightFrom(
        uint256 projectId,
        uint256 baseRulesetStart,
        uint256 baseRulesetDuration,
        uint256 baseRulesetWeight,
        uint256 baseRulesetWeightCutPercent,
        uint256 baseRulesetCacheId,
        uint256 start
    )
        external
        view
        returns (uint256 weight);

    /// @notice Returns a specific ruleset for a project by its ID.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @param rulesetId The ID of the ruleset to retrieve.
    /// @return The ruleset.
    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory);

    /// @notice Returns the latest queued ruleset for a project and its approval status.
    /// @param projectId The ID of the project to get the latest queued ruleset of.
    /// @return ruleset The latest queued ruleset.
    /// @return approvalStatus The ruleset's approval status.
    function latestQueuedOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBApprovalStatus approvalStatus);

    /// @notice Returns an array of rulesets for a project, sorted from latest to earliest.
    /// @param projectId The ID of the project to get rulesets of.
    /// @param startingId The ID of the ruleset to begin with. If 0, the latest ruleset is used.
    /// @param size The maximum number of rulesets to return.
    /// @return rulesets The array of rulesets.
    function allOf(
        uint256 projectId,
        uint256 startingId,
        uint256 size
    )
        external
        view
        returns (JBRuleset[] memory rulesets);

    /// @notice Returns the upcoming ruleset for a project.
    /// @param projectId The ID of the project to get the upcoming ruleset of.
    /// @return ruleset The upcoming ruleset.
    function upcomingOf(uint256 projectId) external view returns (JBRuleset memory ruleset);

    /// @notice Queues a new ruleset for a project.
    /// @param projectId The ID of the project to queue the ruleset for.
    /// @param duration The duration of the ruleset in seconds.
    /// @param weight The weight of the ruleset.
    /// @param weightCutPercent The percent by which the weight decreases each cycle.
    /// @param approvalHook The approval hook for the ruleset.
    /// @param metadata The packed ruleset metadata.
    /// @param mustStartAtOrAfter The earliest time the ruleset can start.
    /// @return ruleset The queued ruleset.
    function queueFor(
        uint256 projectId,
        uint256 duration,
        uint256 weight,
        uint256 weightCutPercent,
        IJBRulesetApprovalHook approvalHook,
        uint256 metadata,
        uint256 mustStartAtOrAfter
    )
        external
        returns (JBRuleset memory ruleset);

    /// @notice Updates the weight cache for a project to allow efficient weight derivation over many cycles.
    /// @param projectId The ID of the project to update the weight cache for.
    function updateRulesetWeightCache(uint256 projectId) external;
}
