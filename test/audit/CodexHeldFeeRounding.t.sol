// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract CodexHeldFeeRoundingTest is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;

    uint256 private _projectId;
    address private _projectOwner;
    address private _beneficiary;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _terminal = jbMultiTerminal();
        _controller = jbController();

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: true,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: true,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 100, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        surplusAllowances[0] = JBCurrencyAmount({amount: 0, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundAccessLimits = new JBFundAccessLimitGroup[](1);
        fundAccessLimits[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: surplusAllowances
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: fundAccessLimits
        });

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: contexts});

        // Project 1 is the fee project.
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "fee-project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    function test_dustPartialRepaymentProducesZeroFee() external {
        // Seed the project with enough balance to send a payout that holds fees.
        _terminal.pay{value: 100}({
            projectId: _projectId,
            amount: 100,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 40,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // 40 gross produces a 1 wei fee (40/40=1) and 39 wei net payout.
        assertEq(address(_projectOwner).balance, 39);

        // Repay 1 wei — too small for a proportional fee, so returned fee rounds to 0.
        vm.prank(_projectOwner);
        _terminal.addToBalanceOf{value: 1}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1,
            shouldReturnHeldFees: true,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 feeProjectBalanceBefore = jbTerminalStore().balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);
        assertEq(feeProjectBalanceBefore, 0);

        vm.warp(block.timestamp + 2_419_200);
        _terminal.processHeldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 10);

        uint256 feeProjectBalanceAfter = jbTerminalStore().balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);
        uint256 projectBalanceAfter =
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);

        // The held fee was partially reduced (40 → 39). At 2.5%, 39/40 = 0 fee.
        // Dust fees round to zero — this is accepted (see RISKS.md § 2).
        assertEq(feeProjectBalanceAfter, 0);
        // Project retains its balance: 60 (remaining after payout) + 1 (top-up) = 61.
        assertEq(projectBalanceAfter, 61);
        // Terminal holds 62 wei (101 received - 39 paid out). 61 is accounted (project balance).
        // The 1 wei difference is dust from the partially-returned held fee whose fee rounded to 0.
        // This dust stays in the terminal as unaccounted surplus — accepted tradeoff vs the alternative
        // where rounding fees up to 1 caused split-payout accounting bugs.
        assertEq(address(_terminal).balance, 62);
        assertEq(address(_terminal).balance, projectBalanceAfter + 1);
    }
}
