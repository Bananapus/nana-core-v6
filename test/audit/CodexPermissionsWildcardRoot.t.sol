// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBPermissions} from "../../src/JBPermissions.sol";
import {JBPermissionsData} from "../../src/structs/JBPermissionsData.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

/// @notice Confirms that the wildcard ROOT vulnerability (granting god-mode across all projects)
/// is now blocked by `JBPermissions_CantSetRootPermissionForWildcardProject`.
contract CodexPermissionsWildcardRootPoC is TestBaseWorkflow {
    address internal owner;
    address internal operator;

    function setUp() public override {
        super.setUp();

        owner = multisig();
        operator = makeAddr("wildcard-root-operator");
    }

    function test_ownerCanGrantWildcardRootAndOperatorGetsAllProjectPermissions() external {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ROOT;

        // Attempting to grant ROOT + wildcard projectId=0 should now revert.
        vm.prank(owner);
        vm.expectRevert(JBPermissions.JBPermissions_CantSetRootPermissionForWildcardProject.selector);
        jbPermissions().setPermissionsFor(
            owner, JBPermissionsData({operator: operator, projectId: 0, permissionIds: permissionIds})
        );
    }

    function _launchSimpleProject(string memory projectUri) internal returns (uint256) {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = 1000e18;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
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
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});

        return jbController().launchProjectFor({
            owner: owner,
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }
}
