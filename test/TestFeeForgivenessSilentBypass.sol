// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBFees} from "../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

/// @notice Regression test: `_processFee` fail-open credits balance back via `_recordAddedBalanceFor`
/// and increments `feeFreeSurplusOf`. The forgiven fee amount becomes part of project balance, but cannot exit
/// fee-free on the next zero-tax cashout.
///
/// Mechanism:
///   1. Project P with cashOutTaxRate=0, no inflow goes through fee-free tracking initially
///      (only same-terminal split-pay or sucker bridging accumulate `feeFreeSurplusOf`).
///   2. User pays project; balance increments, no fee on inflow.
///   3. Owner calls `sendPayoutsOf` → `_takeFeeFrom` → `_processFee`.
///   4. We force the fee terminal to be address(0) via vm.mockCall on the directory.
///      This causes `executeProcessFee` to revert with JBMultiTerminal_FeeTerminalNotFound.
///   5. `_processFee` catches and calls `_recordAddedBalanceFor` to refund the fee to project balance.
///   6. `feeFreeSurplusOf[projectId][token]` is incremented by the credited-back amount.
///   7. The owner / holder cashes out the refunded amount at tax=0 — a fee is taken from the tracked fee-free
///      surplus, so round-trip prevention applies.
contract TestFeeForgivenessSilentBypass_Local is TestBaseWorkflow {
    IJBController private _controller;
    JBMultiTerminal private _terminal;
    JBTokens private _tokens;
    JBTerminalStore private _store;
    uint256 private _projectId;
    address private _projectOwner;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint112 private constant PAY_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();
        _store = jbTerminalStore();

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0, // CRITICAL: zero tax — only `feeFreeSurplusOf` triggers fees on cashout.
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
            holdFees: false, // Process fees immediately (don't hold).
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: uint224(PAY_AMOUNT), currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory limitGroups = new JBFundAccessLimitGroup[](1);
        limitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = limitGroups;

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] =
            JBTerminalConfig({terminal: IJBTerminal(address(_terminal)), accountingContextsToAccept: tokensToAccept});

        // Fee project (#1) set up normally.
        _controller.launchProjectFor({
            owner: address(420),
            projectUri: "fee",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Test project (#2).
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "test",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice After a forgiven fee, the credited-back amount is tracked in `feeFreeSurplusOf`, so it pays a fee on
    /// a later zero-tax cashout.
    function test_chargesFeeOnCreditedBackFeeRouteFailure() external {
        // 1. Pay the project — balance increments, no fee on inflow.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _projectOwner,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 projectBalanceBeforePayout = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(projectBalanceBeforePayout, PAY_AMOUNT, "project should hold PAY_AMOUNT pre-payout");

        // 2. Force the fee terminal to be unavailable by mocking the directory to return address(0)
        //    for project 1's primary terminal lookup. This triggers JBMultiTerminal_FeeTerminalNotFound
        //    inside `executeProcessFee`, which `_processFee` catches and forgives via `_recordAddedBalanceFor`.
        IJBDirectory directory = jbDirectory();
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, uint256(1), JBConstants.NATIVE_TOKEN),
            abi.encode(address(0))
        );

        // 3. Trigger sendPayoutsOf — fee path fails, `_recordAddedBalanceFor` credits the fee back.
        vm.prank(_projectOwner);
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // 4. The fee was forgiven and credited back to the project. The expected fee amount is 2.5% of PAY_AMOUNT.
        uint256 expectedFee = JBFees.feeAmountFrom({amountBeforeFee: PAY_AMOUNT, feePercent: JBConstants.STANDARD_FEE});

        uint256 projectBalanceAfterPayout = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            projectBalanceAfterPayout,
            expectedFee,
            "after fee forgiveness, project balance should equal the credited-back fee amount"
        );

        // 5. Try to cash out the credited-back amount at tax=0. The credited-back fee must be tracked as fee-free
        //    surplus, so the cashout charges the protocol fee on the round-trip-prevention amount.
        //    We mock the directory back to the real terminal for this cashout so the fee can be charged.
        vm.clearMockedCalls();

        // Snapshot the fee project's balance pre-cashout.
        uint256 feeProjectBalanceBefore = _store.balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);

        // The project owner needs project tokens to cash out. They got them on the initial pay.
        uint256 ownerTokenBalance = _tokens.totalBalanceOf(_projectOwner, _projectId);
        assertGt(ownerTokenBalance, 0, "owner should hold project tokens from initial pay");

        vm.prank(_projectOwner);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: _projectOwner,
            projectId: _projectId,
            cashOutCount: ownerTokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_projectOwner),
            metadata: new bytes(0)
        });

        uint256 feeProjectBalanceAfter = _store.balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);
        uint256 expectedRecoveryFee =
            JBFees.feeAmountFrom({amountBeforeFee: expectedFee, feePercent: JBConstants.STANDARD_FEE});

        emit log_named_uint("reclaim", reclaim);
        emit log_named_uint("expectedFee", expectedFee);
        emit log_named_uint("expectedRecoveryFee", expectedRecoveryFee);
        emit log_named_uint("feeProjectBalanceBefore", feeProjectBalanceBefore);
        emit log_named_uint("feeProjectBalanceAfter", feeProjectBalanceAfter);

        uint256 feeProjectGain = feeProjectBalanceAfter - feeProjectBalanceBefore;

        assertEq(reclaim, expectedFee - expectedRecoveryFee, "cashout should return the credited-back fee net of fee");
        assertEq(feeProjectGain, expectedRecoveryFee, "forgiven fee must pay protocol fee on zero-tax cashout");
    }
}
