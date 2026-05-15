// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {IJBCashOutTerminal} from "../src/interfaces/IJBCashOutTerminal.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../src/structs/JBCashOutHookSpecification.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

contract TestTerminalPreviewParity_Local is TestBaseWorkflow {
    IJBController internal _controller;
    IJBMultiTerminal internal _terminal;
    address internal _projectOwner;
    address internal _beneficiary;

    function setUp() public virtual override {
        super.setUp();

        _controller = jbController();
        _terminal = jbMultiTerminal();
        _projectOwner = multisig();
        _beneficiary = beneficiary();
    }

    function _launchProject(uint16 reservedPercent, uint16 cashOutTaxRate) internal returns (uint256 projectId) {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = 1000 * 10 ** 18;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: cashOutTaxRate,
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
            metadata: 0,
            pauseCrossProjectFeeFreeInflows: false
        });
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: contexts});

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://preview-parity",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    function _launchFeeProject() internal {
        _launchProject(0, JBConstants.MAX_CASH_OUT_TAX_RATE);
    }

    function testFuzzPreviewPayForMatchesPay(uint96 amount, uint16 reservedPercent) external {
        amount = uint96(bound(amount, 1, 100 ether));
        reservedPercent = uint16(bound(reservedPercent, 0, JBConstants.MAX_RESERVED_PERCENT));

        _launchFeeProject();
        uint256 projectId = _launchProject(reservedPercent, JBConstants.MAX_CASH_OUT_TAX_RATE);

        (
            JBRuleset memory ruleset,
            uint256 previewBeneficiaryTokenCount,
            uint256 previewReservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        ) = _terminal.previewPayFor(projectId, JBConstants.NATIVE_TOKEN, amount, _beneficiary, "");

        assertEq(hookSpecifications.length, 0);

        uint256 balanceBefore = jbTokens().totalBalanceOf(_beneficiary, projectId);
        uint256 reservedBefore = _controller.pendingReservedTokenBalanceOf(projectId);

        address payer = makeAddr("payer");
        vm.deal(payer, amount);

        vm.expectEmit();
        emit IJBTerminal.Pay(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            payer,
            _beneficiary,
            amount,
            previewBeneficiaryTokenCount,
            "",
            "",
            payer
        );

        vm.prank(payer);
        uint256 beneficiaryTokenCount = _terminal.pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(beneficiaryTokenCount, previewBeneficiaryTokenCount);
        assertEq(jbTokens().totalBalanceOf(_beneficiary, projectId) - balanceBefore, previewBeneficiaryTokenCount);
        assertEq(_controller.pendingReservedTokenBalanceOf(projectId) - reservedBefore, previewReservedTokenCount);
    }

    function testFuzzPreviewCashOutMatchesCashOut(
        uint96 payAmount,
        uint16 cashOutTaxRate,
        uint256 cashOutCountSeed
    )
        external
    {
        payAmount = uint96(bound(payAmount, 1, 100 ether));
        cashOutTaxRate = uint16(bound(cashOutTaxRate, 0, JBConstants.MAX_CASH_OUT_TAX_RATE));

        _launchFeeProject();
        uint256 projectId = _launchProject(0, cashOutTaxRate);

        vm.prank(_projectOwner);
        jbFeelessAddresses().setFeelessAddress(_beneficiary, true);

        vm.deal(_beneficiary, payAmount);
        vm.prank(_beneficiary);
        uint256 minted = _terminal.pay{value: payAmount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 cashOutCount = bound(cashOutCountSeed, 1, minted);

        (
            JBRuleset memory ruleset,
            uint256 previewReclaimAmount,
            uint256 previewCashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) = _terminal.previewCashOutFrom(
            _beneficiary, projectId, cashOutCount, JBConstants.NATIVE_TOKEN, payable(_beneficiary), ""
        );

        assertEq(hookSpecifications.length, 0);

        vm.expectEmit();
        emit IJBCashOutTerminal.CashOutTokens(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            _beneficiary,
            _beneficiary,
            cashOutCount,
            previewCashOutTaxRate,
            previewReclaimAmount,
            "",
            _beneficiary
        );

        vm.prank(_beneficiary);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: _beneficiary,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: ""
        });

        assertEq(reclaimAmount, previewReclaimAmount);
    }
}
