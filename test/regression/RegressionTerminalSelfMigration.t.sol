// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {MockERC20} from "../mock/MockERC20.sol";

import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract RegressionTerminalSelfMigration is TestBaseWorkflow {
    uint32 private constant _USDC_CURRENCY = 1;

    IJBController private _controller;
    JBMultiTerminal private _terminal;
    MockERC20 private _token;

    address private _projectOwner;
    address private _payer;
    uint256 private _projectId;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _terminal = jbMultiTerminal();
        _token = usdcToken();
        _projectOwner = multisig();
        _payer = beneficiary();

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "self-migration",
            rulesetConfigurations: _rulesetConfig(),
            terminalConfigurations: _terminalConfig(),
            memo: ""
        });
    }

    function test_erc20MigrationToSelfRevertsAndPreservesAccounting() external {
        uint256 payAmount = 10_000e6;

        _token.mint(_payer, payAmount);

        vm.startPrank(_payer);
        _token.approve(address(_terminal), payAmount);
        _terminal.pay(_projectId, address(_token), payAmount, _payer, 0, "", "");
        vm.stopPrank();

        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, address(_token)),
            payAmount,
            "source balance recorded"
        );
        assertEq(_token.balanceOf(address(_terminal)), payAmount, "terminal holds ERC-20 backing");

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_TerminalMigrationToSelf.selector, _projectId, address(_token)
            )
        );
        vm.prank(_projectOwner);
        _terminal.migrateBalanceOf(_projectId, address(_token), _terminal);

        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, address(_token)),
            payAmount,
            "failed self-migration preserves accounting"
        );
        assertEq(_token.balanceOf(address(_terminal)), payAmount, "terminal token backing unchanged");
    }

    function _rulesetConfig() private pure returns (JBRulesetConfig[] memory rulesetConfig) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: _USDC_CURRENCY,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: true,
            allowSetTerminals: false,
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

        rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1000e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    function _terminalConfig() private view returns (JBTerminalConfig[] memory terminalConfig) {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({token: address(_token), decimals: 6, currency: _USDC_CURRENCY});

        terminalConfig = new JBTerminalConfig[](1);
        terminalConfig[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: accountingContexts});
    }
}
