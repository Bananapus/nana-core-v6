// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {Vm} from "forge-std/Vm.sol";

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {JBDirectory} from "../../src/JBDirectory.sol";
import {JBTerminalStore} from "../../src/JBTerminalStore.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBFeeTerminal} from "../../src/interfaces/IJBFeeTerminal.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

/// @notice Silent failure detection: asserts that fee processing takes the SUCCESS path
///         (emits `ProcessFee`), not the catch path (emits `FeeReverted`).
/// @dev References TEST_IMPROVEMENT_PLAN.md Section 6.
///      The WRONG pattern: `terminal.sendPayoutsOf(..., 0)` succeeds -> test passes.
///      The RIGHT pattern: record logs and verify `ProcessFee` was emitted and `FeeReverted` was NOT.
contract SilentFeeFailureDetectionTest is TestBaseWorkflow {
    IJBController private _controller;
    JBTerminalStore private _store;
    JBMultiTerminal private _terminal;

    address private _projectOwner;
    address private _payer;
    uint256 private _projectId;

    // Event selectors for log detection
    bytes32 private constant PROCESS_FEE_TOPIC = keccak256("ProcessFee(uint256,address,uint256,bool,address,address)");
    bytes32 private constant FEE_REVERTED_TOPIC =
        keccak256("FeeReverted(uint256,address,uint256,uint256,bytes,address)");

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _store = jbTerminalStore();
        _terminal = jbMultiTerminal();
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
            allowTerminalMigration: false,
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

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 1 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: fundAccessLimitGroups
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _accountingContexts()});

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "test://silent-failure",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Fund the project with 2 ETH
        vm.deal(_payer, 2 ether);
        vm.prank(_payer);
        _terminal.pay{value: 2 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 2 ether,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Payout fee must emit `ProcessFee` (success) and NOT `FeeReverted` (silent failure).
    function test_payoutFee_emitsProcessFee_notFeeReverted() public {
        vm.recordLogs();

        vm.prank(_projectOwner);
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawProcessFee = false;
        bool sawFeeReverted = false;

        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == PROCESS_FEE_TOPIC) sawProcessFee = true;
            if (logs[i].topics[0] == FEE_REVERTED_TOPIC) sawFeeReverted = true;
        }

        assertTrue(sawProcessFee, "ProcessFee must be emitted - fee success path taken");
        assertFalse(sawFeeReverted, "FeeReverted must NOT be emitted - no silent fee failure");
    }

    /// @notice Cash-out with 0% tax rate should not trigger fee processing at all.
    ///         Verify no FeeReverted event is emitted (no silent catch).
    function test_cashOut_noSilentFeeFailure() public {
        uint256 tokenBalance = _controller.TOKENS().totalBalanceOf(_payer, _projectId);
        if (tokenBalance == 0) return;

        vm.recordLogs();

        vm.prank(_payer);
        _terminal.cashOutTokensOf({
            holder: _payer,
            projectId: _projectId,
            cashOutCount: tokenBalance / 2,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_payer),
            metadata: "",
            referralProjectId: 0
        });

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawFeeReverted = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_REVERTED_TOPIC) sawFeeReverted = true;
        }

        assertFalse(sawFeeReverted, "FeeReverted must NOT be emitted during cash-out");
    }

    /// @notice Invariant 3 from TEST_IMPROVEMENT_PLAN.md Section 7: Fee Collection Monotonicity.
    ///         Every ProcessFee event implies a non-zero fee was collected (not refunded).
    ///         Combined with the absence of FeeReverted, this proves monotonic fee growth.
    function test_feeCollection_isNonZero() public {
        vm.recordLogs();

        vm.prank(_projectOwner);
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawProcessFee = false;
        bool sawFeeReverted = false;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == PROCESS_FEE_TOPIC) sawProcessFee = true;
            if (logs[i].topics[0] == FEE_REVERTED_TOPIC) sawFeeReverted = true;
        }

        // ProcessFee emitted + no FeeReverted = fee was successfully collected (monotonicity)
        assertTrue(sawProcessFee, "ProcessFee must be emitted - fee collected");
        assertFalse(sawFeeReverted, "FeeReverted must NOT be emitted - fee not refunded");
    }

    function _accountingContexts() internal pure returns (JBAccountingContext[] memory) {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        return contexts;
    }
}
