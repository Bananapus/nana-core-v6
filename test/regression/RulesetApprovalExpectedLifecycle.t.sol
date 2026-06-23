// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {JBDeadline} from "../../src/JBDeadline.sol";
import {JBApprovalStatus} from "../../src/enums/JBApprovalStatus.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract RulesetApprovalExpectedLifecycle is TestBaseWorkflow {
    uint256 internal constant _DEADLINE_DURATION = 1 days;
    uint112 internal constant _WEIGHT = 1000 * 10 ** 18;

    function test_approvalExpectedRulesetCanBeReplacedBeforeFinalApproval() public {
        vm.warp(1_000_001);

        IJBController controller = jbController();
        uint256 projectId = _launchProjectWithDeadline({controller: controller, terminal: jbMultiTerminal()});

        vm.prank(multisig());
        controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: uint48(block.timestamp + 3 days),
                weight: _WEIGHT + 1,
                approvalHook: IJBRulesetApprovalHook(address(0))
            }),
            memo: ""
        });

        (JBRuleset memory expectedRuleset, JBApprovalStatus status) = jbRulesets().latestQueuedOf(projectId);
        assertEq(uint256(status), uint256(JBApprovalStatus.ApprovalExpected));

        vm.prank(multisig());
        controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: expectedRuleset.start,
                weight: _WEIGHT + 2,
                approvalHook: IJBRulesetApprovalHook(address(0))
            }),
            memo: ""
        });

        (JBRuleset memory replacement,) = jbRulesets().latestQueuedOf(projectId);

        assertEq(replacement.start, expectedRuleset.start, "replacement keeps the expected cycle");
        assertEq(replacement.basedOnId, expectedRuleset.basedOnId, "replacement is based on the approved base");
        assertNotEq(replacement.basedOnId, expectedRuleset.id, "replacement does not inherit from the expected rule");

        vm.warp(replacement.start);

        JBRuleset memory currentRuleset = jbRulesets().currentOf(projectId);
        assertEq(currentRuleset.id, replacement.id, "replacement becomes current");
        assertEq(currentRuleset.weight, _WEIGHT + 2, "replacement economics apply");
    }

    function test_approvedRulesetCannotBeReplacedWithinItsCycle() public {
        vm.warp(1_000_001);

        IJBController controller = jbController();
        uint256 projectId = _launchProjectWithDeadline({controller: controller, terminal: jbMultiTerminal()});

        vm.prank(multisig());
        controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: uint48(block.timestamp + 3 days),
                weight: _WEIGHT + 1,
                approvalHook: IJBRulesetApprovalHook(address(0))
            }),
            memo: ""
        });

        (JBRuleset memory approvedRuleset,) = jbRulesets().latestQueuedOf(projectId);

        vm.warp(approvedRuleset.start - _DEADLINE_DURATION);
        (, JBApprovalStatus status) = jbRulesets().latestQueuedOf(projectId);
        assertEq(uint256(status), uint256(JBApprovalStatus.Approved));

        vm.prank(multisig());
        controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: approvedRuleset.start,
                weight: _WEIGHT + 2,
                approvalHook: IJBRulesetApprovalHook(address(0))
            }),
            memo: ""
        });

        (JBRuleset memory child,) = jbRulesets().latestQueuedOf(projectId);

        assertEq(child.basedOnId, approvedRuleset.id, "approved ruleset is the immutable parent");
        assertEq(child.start, approvedRuleset.start + approvedRuleset.duration, "child starts after the approved cycle");
    }

    function test_childQueuedAfterExpectedParentActivatesAfterParentApproval() public {
        vm.warp(1_000_001);

        IJBController controller = jbController();
        uint256 projectId = _launchProjectWithDeadline({controller: controller, terminal: jbMultiTerminal()});

        vm.prank(multisig());
        controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: uint48(block.timestamp + 3 days),
                weight: _WEIGHT + 1,
                approvalHook: IJBRulesetApprovalHook(address(0))
            }),
            memo: ""
        });

        (JBRuleset memory expectedParent, JBApprovalStatus status) = jbRulesets().latestQueuedOf(projectId);
        assertEq(uint256(status), uint256(JBApprovalStatus.ApprovalExpected));

        vm.prank(multisig());
        controller.queueRulesetsOf({
            projectId: projectId,
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: expectedParent.start + expectedParent.duration,
                weight: _WEIGHT + 2,
                approvalHook: IJBRulesetApprovalHook(address(0))
            }),
            memo: ""
        });

        (JBRuleset memory child,) = jbRulesets().latestQueuedOf(projectId);
        assertEq(child.basedOnId, expectedParent.id, "child inherits from the expected parent");

        vm.warp(child.start);

        JBRuleset memory currentRuleset = jbRulesets().currentOf(projectId);
        assertEq(currentRuleset.id, child.id, "child becomes current after parent approval finalizes");
        assertEq(currentRuleset.weight, _WEIGHT + 2, "child economics apply");
    }

    function _launchProjectWithDeadline(
        IJBController controller,
        IJBTerminal terminal
    )
        internal
        returns (uint256 projectId)
    {
        JBDeadline deadline = new JBDeadline(_DEADLINE_DURATION);

        projectId = controller.launchProjectFor({
            owner: address(multisig()),
            projectUri: "myIPFSHash",
            rulesetConfigurations: _rulesetConfig({
                mustStartAtOrAfter: 0, weight: _WEIGHT, approvalHook: IJBRulesetApprovalHook(address(deadline))
            }),
            terminalConfigurations: _terminalConfigurations(terminal),
            memo: ""
        });
    }

    function _rulesetConfig(
        uint48 mustStartAtOrAfter,
        uint112 weight,
        IJBRulesetApprovalHook approvalHook
    )
        internal
        pure
        returns (JBRulesetConfig[] memory rulesetConfigurations)
    {
        rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = mustStartAtOrAfter;
        rulesetConfigurations[0].duration = 1 days;
        rulesetConfigurations[0].weight = weight;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = approvalHook;
        rulesetConfigurations[0].metadata = _metadata();
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
    }

    function _terminalConfigurations(IJBTerminal terminal)
        internal
        pure
        returns (JBTerminalConfig[] memory terminalConfigurations)
    {
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] = JBTerminalConfig({terminal: terminal, accountingContextsToAccept: tokensToAccept});
    }

    function _metadata() internal pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
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
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }
}
