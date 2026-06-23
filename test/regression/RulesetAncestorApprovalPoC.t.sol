// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
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

contract MutableAncestorApprovalHook is IJBRulesetApprovalHook {
    uint256 public immutable override DURATION;
    JBApprovalStatus public status;

    constructor(uint256 duration, JBApprovalStatus initialStatus) {
        DURATION = duration;
        status = initialStatus;
    }

    function setStatus(JBApprovalStatus newStatus) external {
        status = newStatus;
    }

    function approvalStatusOf(uint256, JBRuleset memory) external view override returns (JBApprovalStatus) {
        return status;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetApprovalHook).interfaceId;
    }
}

    contract RulesetAncestorApprovalPoC is TestBaseWorkflow {
        function test_childRulesetCannotBecomeCurrentAfterExpectedParentLaterFails() public {
            vm.warp(1_000_001);

            IJBController controller = jbController();
            IJBTerminal terminal = jbMultiTerminal();
            uint112 weight = 1000 * 10 ** 18;

            JBRulesetMetadata memory metadata = JBRulesetMetadata({
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

            MutableAncestorApprovalHook parentApprovalHook =
                new MutableAncestorApprovalHook({duration: 0, initialStatus: JBApprovalStatus.ApprovalExpected});

            JBRulesetConfig[] memory initialConfig = new JBRulesetConfig[](1);
            initialConfig[0].mustStartAtOrAfter = 0;
            initialConfig[0].duration = 1 days;
            initialConfig[0].weight = weight;
            initialConfig[0].weightCutPercent = 0;
            initialConfig[0].approvalHook = parentApprovalHook;
            initialConfig[0].metadata = metadata;
            initialConfig[0].splitGroups = new JBSplitGroup[](0);
            initialConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

            JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
            tokensToAccept[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
            terminalConfigurations[0] = JBTerminalConfig({
                terminal: terminal, accountingContextsToAccept: tokensToAccept
            });

            uint256 projectId = controller.launchProjectFor({
                owner: address(multisig()),
                projectUri: "myIPFSHash",
                rulesetConfigurations: initialConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

            JBRulesetConfig[] memory expectedParentConfig = new JBRulesetConfig[](1);
            expectedParentConfig[0].mustStartAtOrAfter = uint48(block.timestamp + 3 days);
            expectedParentConfig[0].duration = 1 days;
            expectedParentConfig[0].weight = weight + 1;
            expectedParentConfig[0].weightCutPercent = 0;
            expectedParentConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
            expectedParentConfig[0].metadata = metadata;
            expectedParentConfig[0].splitGroups = new JBSplitGroup[](0);
            expectedParentConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

            vm.prank(multisig());
            controller.queueRulesetsOf(projectId, expectedParentConfig, "");

            (JBRuleset memory expectedParent,) = jbRulesets().latestQueuedOf(projectId);
            assertEq(
                uint256(parentApprovalHook.status()),
                uint256(JBApprovalStatus.ApprovalExpected),
                "parent must be expected while the child is queued"
            );

            JBRulesetConfig[] memory childConfig = new JBRulesetConfig[](1);
            childConfig[0].mustStartAtOrAfter = uint48(expectedParent.start + expectedParent.duration);
            childConfig[0].duration = 1 days;
            childConfig[0].weight = weight + 2;
            childConfig[0].weightCutPercent = 0;
            childConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
            childConfig[0].metadata = metadata;
            childConfig[0].splitGroups = new JBSplitGroup[](0);
            childConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

            vm.prank(multisig());
            controller.queueRulesetsOf(projectId, childConfig, "");

            (JBRuleset memory child,) = jbRulesets().latestQueuedOf(projectId);
            assertEq(child.basedOnId, expectedParent.id, "child was based on the ApprovalExpected parent");

            parentApprovalHook.setStatus(JBApprovalStatus.Failed);
            vm.warp(child.start);

            JBRuleset memory currentRuleset = jbRulesets().currentOf(projectId);

            assertNotEq(currentRuleset.id, child.id, "child must not activate after its parent later fails");
            assertEq(currentRuleset.weight, weight, "current ruleset falls back to the last approved economics");
        }
    }
