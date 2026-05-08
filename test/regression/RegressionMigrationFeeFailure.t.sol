// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {JBDirectory} from "../../src/JBDirectory.sol";
import {JBTerminalStore} from "../../src/JBTerminalStore.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract RegressionMigrationFeeFailure is TestBaseWorkflow {
    IJBController private _controller;
    JBDirectory private _directory;
    JBTerminalStore private _store;
    JBMultiTerminal private _terminalA;
    JBMultiTerminal private _terminalB;

    address private _feeProjectOwner = address(420);
    address private _projectOwner;
    address private _payer;
    uint256 private _projectId;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _directory = jbDirectory();
        _store = jbTerminalStore();
        _terminalA = jbMultiTerminal();
        _terminalB = jbMultiTerminal2();
        _projectOwner = multisig();
        _payer = beneficiary();

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000 * 10 ** 18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory feeTerminalConfigs = new JBTerminalConfig[](1);
        feeTerminalConfigs[0] = JBTerminalConfig({terminal: _terminalA, accountingContextsToAccept: contexts});

        JBTerminalConfig[] memory projectTerminalConfigs = new JBTerminalConfig[](2);
        projectTerminalConfigs[0] = JBTerminalConfig({terminal: _terminalA, accountingContextsToAccept: contexts});
        projectTerminalConfigs[1] = JBTerminalConfig({terminal: _terminalB, accountingContextsToAccept: contexts});

        _controller.launchProjectFor({
            owner: _feeProjectOwner,
            projectUri: "fee-project",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: feeTerminalConfigs,
            memo: ""
        });

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "migrating-project",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: projectTerminalConfigs,
            memo: ""
        });
    }

    function test_migrationFeeFailure_strandsForgivenFeeAndChargesItAgainOnCleanup() external {
        uint256 payAmount = 10 ether;
        uint256 expectedFee = JBFees.feeAmountFrom({amountBeforeFee: payAmount, feePercent: _terminalA.FEE()});

        vm.deal(_payer, payAmount);
        vm.prank(_payer);
        _terminalA.pay{value: payAmount}(_projectId, JBConstants.NATIVE_TOKEN, payAmount, _payer, 0, "", "");

        // Break fee routing by removing every terminal from fee project #1.
        vm.prank(_feeProjectOwner);
        _directory.setTerminalsOf(1, new IJBTerminal[](0));

        vm.prank(_projectOwner);
        _terminalA.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, _terminalB);

        // The failed fee is credited back on terminal A instead of migrating with the project.
        assertEq(
            _store.balanceOf(address(_terminalA), _projectId, JBConstants.NATIVE_TOKEN),
            expectedFee,
            "failed migration fee remains on the source terminal"
        );
        assertEq(
            _store.balanceOf(address(_terminalB), _projectId, JBConstants.NATIVE_TOKEN),
            payAmount - expectedFee,
            "only the post-fee amount reaches the destination terminal"
        );
        assertEq(
            _store.balanceOf(address(_terminalA), 1, JBConstants.NATIVE_TOKEN),
            0,
            "fee project did not receive the forgiven migration fee"
        );

        // Restore fee routing and sweep the residual balance.
        IJBTerminal[] memory feeTerminals = new IJBTerminal[](1);
        feeTerminals[0] = IJBTerminal(address(_terminalA));
        vm.prank(_feeProjectOwner);
        _directory.setTerminalsOf(1, feeTerminals);

        vm.prank(_projectOwner);
        _terminalA.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, _terminalB);

        uint256 secondFee = JBFees.feeAmountFrom({amountBeforeFee: expectedFee, feePercent: _terminalA.FEE()});
        assertEq(
            _store.balanceOf(address(_terminalA), _projectId, JBConstants.NATIVE_TOKEN),
            0,
            "cleanup migration clears the stranded source balance"
        );
        assertEq(
            _store.balanceOf(address(_terminalB), _projectId, JBConstants.NATIVE_TOKEN),
            payAmount - secondFee,
            "the previously forgiven fee is charged again during cleanup"
        );
        assertEq(
            _store.balanceOf(address(_terminalA), 1, JBConstants.NATIVE_TOKEN),
            secondFee,
            "fee project only receives the second migration fee"
        );
    }
}
