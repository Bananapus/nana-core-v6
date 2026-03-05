// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {IJBRulesets} from "../../../src/interfaces/IJBRulesets.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRuleset} from "../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../src/structs/JBRulesetMetadata.sol";
import {JBRulesetConfig} from "../../../src/structs/JBRulesetConfig.sol";
import {JBSplitGroup} from "../../../src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "../../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetMetadataResolver} from "../../../src/libraries/JBRulesetMetadataResolver.sol";

/// @notice Handler contract for JBRulesets invariant testing.
/// @dev Drives ruleset queueing, time advancement, and weight cache updates.
contract RulesetsHandler is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    IJBRulesets public rulesets;
    IJBController public controller;

    uint256 public projectId;
    address public projectOwner;

    // Ghost: track the last observed cycle number and weight for monotonicity checks
    uint48 public ghost_lastCycleNumber;
    uint112 public ghost_lastWeight;
    bool public ghost_hasLaunched;
    uint256 public ghost_queueCount;

    constructor(IJBRulesets _rulesets, IJBController _controller, uint256 _projectId, address _projectOwner) {
        rulesets = _rulesets;
        controller = _controller;
        projectId = _projectId;
        projectOwner = _projectOwner;
        ghost_hasLaunched = true;

        // Snapshot initial state
        JBRuleset memory current = rulesets.currentOf(projectId);
        ghost_lastCycleNumber = current.cycleNumber;
        ghost_lastWeight = current.weight;
    }

    /// @notice Queue a new ruleset with random weight and duration.
    function queueRuleset(uint256 weightSeed, uint256 durationSeed, uint256 weightCutSeed) public {
        uint112 weight = uint112(bound(weightSeed, 1, 1e24));
        uint32 duration = uint32(bound(durationSeed, 1 days, 365 days));
        uint32 weightCutPercent = uint32(bound(weightCutSeed, 0, JBConstants.MAX_WEIGHT_CUT_PERCENT));

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 5000,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
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

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: duration,
            weight: weight,
            weightCutPercent: weightCutPercent,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        vm.prank(projectOwner);
        try controller.queueRulesetsOf({projectId: projectId, rulesetConfigurations: configs, memo: ""}) {
            ghost_queueCount++;
        } catch {
            // May fail if not controller
        }
    }

    /// @notice Advance time to trigger ruleset cycling.
    function advanceTime(uint256 timeSeed) public {
        uint256 timeToAdvance = bound(timeSeed, 1 hours, 180 days);
        vm.warp(block.timestamp + timeToAdvance);

        // Update ghost state from current ruleset
        JBRuleset memory current = rulesets.currentOf(projectId);
        if (current.id != 0) {
            ghost_lastCycleNumber = current.cycleNumber;
            ghost_lastWeight = current.weight;
        }
    }

    /// @notice Update the weight cache for the project.
    function updateWeightCache() public {
        try rulesets.updateRulesetWeightCache(projectId) {} catch {}
    }
}
