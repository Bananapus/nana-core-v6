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

/// @notice PoC for F-MTT-10 — `_processFee` fail-open credits balance back via `_recordAddedBalanceFor`
/// but does NOT increment `_feeFreeSurplusOf`. The forgiven fee amount becomes part of project balance
/// that can exit fee-free on the next zero-tax cashout — silently bypassing the protocol fee.
///
/// Mechanism:
///   1. Project P with cashOutTaxRate=0, no inflow goes through fee-free tracking initially
///      (only same-terminal split-pay or sucker bridging accumulate `_feeFreeSurplusOf`).
///   2. User pays project; balance increments, no fee on inflow.
///   3. Owner calls `sendPayoutsOf` → `_takeFeeFrom` → `_processFee`.
///   4. We force the fee terminal to be address(0) via vm.mockCall on the directory.
///      This causes `executeProcessFee` to revert with JBMultiTerminal_FeeTerminalNotFound.
///   5. `_processFee` catches and calls `_recordAddedBalanceFor` to refund the fee to project balance.
///   6. Crucially: `_feeFreeSurplusOf[projectId][token]` remains 0.
///   7. The owner / holder cashes out the refunded amount at tax=0 — no fee is taken because
///      `_feeFreeSurplusOf` reads 0, so the round-trip-prevention does NOT apply.
///   8. Net effect: the project owner has extracted what should have been a 2.5% protocol fee.
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
            cashOutTaxRate: 0, // CRITICAL: zero tax — only `_feeFreeSurplusOf` triggers fees on cashout.
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

    /// @notice PoC — demonstrates the silent fee bypass. After a forgiven fee, the credited-back
    /// amount is not tracked in `_feeFreeSurplusOf`, so it exits the project's balance fee-free.
    ///
    /// The current code only credits back via `_recordAddedBalanceFor` (line 1884 of JBMultiTerminal).
    /// The fix would also increment `_feeFreeSurplusOf[projectId][token] += amount` so the next
    /// zero-tax cashout properly takes the protocol fee on the credited-back portion.
    function test_PoC_F_MTT_10_silentFeeBypassOnFeeRouteFailure() external {
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
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        // 4. The fee was forgiven and credited back to the project. The expected fee amount is 2.5% of PAY_AMOUNT.
        uint256 expectedFee = JBFees.feeAmountFrom({amountBeforeFee: PAY_AMOUNT, feePercent: JBConstants.STANDARD_FEE});

        uint256 projectBalanceAfterPayout = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            projectBalanceAfterPayout,
            expectedFee,
            "after fee forgiveness, project balance should equal the credited-back fee amount"
        );

        // 5. Read `_feeFreeSurplusOf[projectId][NATIVE_TOKEN]` from storage. It should be 0
        //    pre-fix (proving the silent bypass), and equal to `expectedFee` post-fix.
        //    Mapping `_feeFreeSurplusOf` is at slot 18 in JBMultiTerminal (after preceding storage
        //    layout). Compute the slot deterministically.
        //
        //    NOTE: To avoid coupling to storage-layout literals, we instead observe the BEHAVIORAL
        //    consequence — does a cashout of the credited-back amount take a fee or not?
        //    See sub-test below.

        // 6. The behavioral evidence — try to cash out the credited-back amount at tax=0.
        //    Pre-fix: cashout exits fee-free because `_feeFreeSurplusOf == 0`.
        //    Post-fix: cashout takes the protocol fee on the round-trip-prevention amount.
        //
        //    We mock the directory back to the real terminal for this cashout so the fee CAN be charged.
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
            metadata: new bytes(0),
            referralProjectId: 0
        });

        // The PoC observation: the cashout reclaims the FULL credited-back amount (no fee).
        // The fee project receives 0 from this cashout — proving the silent bypass.
        uint256 feeProjectBalanceAfter = _store.balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);

        emit log_named_uint("reclaim", reclaim);
        emit log_named_uint("expectedFee", expectedFee);
        emit log_named_uint("feeProjectBalanceBefore", feeProjectBalanceBefore);
        emit log_named_uint("feeProjectBalanceAfter", feeProjectBalanceAfter);

        // The fee project's balance gain on this cashout is the proof.
        // CURRENT (pre-fix) behavior: fee project gets 0 on this cashout (silent bypass).
        // POST-fix behavior: fee project gets ~`expectedFee * something` (the refund is fee-eligible).
        uint256 feeProjectGain = feeProjectBalanceAfter - feeProjectBalanceBefore;
        if (feeProjectGain == 0) {
            // PoC confirmed: bypass is live.
            emit log("F-MTT-10 confirmed: forgiven fee was extracted by owner without protocol fee.");
        } else {
            // Post-fix behavior: protocol fee charged on the refund's exit.
            emit log("F-MTT-10 mitigated: protocol fee charged on the credited-back amount.");
        }

        // Assert that the bypass is observable in the current build (this assert will need to flip
        // when the fix lands — it serves as the regression marker).
        assertEq(
            feeProjectGain, 0, "F-MTT-10 PoC: pre-fix expectation is that the forgiven fee bypasses protocol revenue"
        );
    }
}
