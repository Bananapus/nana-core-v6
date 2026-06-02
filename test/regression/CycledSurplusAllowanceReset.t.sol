// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract CycledSurplusAllowanceResetTest is TestBaseWorkflow {
    function test_surplusAllowanceDoesNotResetAcrossImplicitCycles() external {
        _launchFeeProject();

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = _makeRulesetConfig({
            duration: 1 days,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: _makeFundAccessLimitGroup(1 ether)
        });

        uint256 projectId = jbController()
            .launchProjectFor({
            owner: multisig(),
            projectUri: "cycle-allowance",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });

        address payer = makeAddr("payer");
        vm.deal(payer, 5 ether);
        vm.prank(payer);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: projectId,
            amount: 5 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        vm.prank(multisig());
        jbMultiTerminal()
            .useAllowanceOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(makeAddr("cycle1-beneficiary")),
            feeBeneficiary: payable(multisig()),
            memo: ""
        });

        JBRuleset memory cycleOneRuleset = jbRulesets().currentOf(projectId);
        assertEq(cycleOneRuleset.cycleNumber, 1, "expected first cycle before warp");

        vm.warp(block.timestamp + 1 days + 1);

        JBRuleset memory cycledRuleset = jbRulesets().currentOf(projectId);
        assertEq(cycledRuleset.cycleNumber, 2, "expected implicit second cycle");
        assertEq(cycledRuleset.id, cycleOneRuleset.id, "cycled ruleset reuses base ruleset id");

        vm.expectRevert();
        vm.prank(multisig());
        jbMultiTerminal()
            .useAllowanceOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(makeAddr("cycle2-beneficiary")),
            feeBeneficiary: payable(multisig()),
            memo: ""
        });
    }

    function _launchFeeProject() private returns (uint256) {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = _makeRulesetConfig({
            duration: 1 days,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        return jbController()
            .launchProjectFor({
            owner: multisig(),
            projectUri: "fee-project",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    function _defaultMetadata() private pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    function _makeTerminalConfig() private view returns (JBTerminalConfig[] memory terminalConfigurations) {
        terminalConfigurations = new JBTerminalConfig[](1);

        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        terminalConfigurations[0] = JBTerminalConfig({
            terminal: IJBTerminal(address(jbMultiTerminal())), accountingContextsToAccept: accountingContexts
        });
    }

    function _makeFundAccessLimitGroup(uint224 surplusAllowanceAmount)
        private
        view
        returns (JBFundAccessLimitGroup[] memory groups)
    {
        groups = new JBFundAccessLimitGroup[](1);

        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        surplusAllowances[0] =
            JBCurrencyAmount({amount: surplusAllowanceAmount, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        groups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: surplusAllowances
        });
    }

    function _makeRulesetConfig(
        uint32 duration,
        JBRulesetMetadata memory metadata,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        private
        pure
        returns (JBRulesetConfig memory)
    {
        return JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: duration,
            weight: 1000 * 10 ** 18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundAccessLimitGroups
        });
    }
}
