// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../src/interfaces/IJBSplitHook.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBSplitGroupIds} from "../src/libraries/JBSplitGroupIds.sol";
import {JBCashOuts} from "../src/libraries/JBCashOuts.sol";
import {JBFees} from "../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

/// @notice End-to-end coverage for the lazy reserved-token settlement on cashout (item B1).
/// @dev Before the fix, `JBMultiTerminal._cashOutTokensOf` ran `STORE.recordCashOutFor` with
/// `pendingReservedTokenBalanceOf` still inflating `totalTokenSupplyWithReservedTokensOf`,
/// shortchanging holders for tokens never minted to splits.
///
/// After the fix, the terminal opportunistically invokes `sendReservedTokensToSplitsOf`
/// when pending > 0, before the bonding-curve math runs. These tests prove:
///   1) Cashing out auto-distributes pending reserves to the reserved-split recipients,
///      and the reclaim matches the post-settlement (non-inflated) formula.
///   2) When pending == 0 the guard is respected — no revert.
contract TestCashOutLazyReserveSettlement_Local is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    JBTokens private _tokens;
    JBTerminalStore private _store;
    uint256 private _projectId;
    address private _projectOwner;
    address private _payer;
    address private _reserveRecipient;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint112 private constant PAY_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _payer = beneficiary();
        _reserveRecipient = address(0xBEEF);
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();
        _store = jbTerminalStore();

        // Reserved split: 100% to a single recipient so we can read the post-settlement balance directly.
        JBSplit[] memory reservedSplits = new JBSplit[](1);
        reservedSplits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(_reserveRecipient),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: JBSplitGroupIds.RESERVED_TOKENS, splits: reservedSplits});

        // Ruleset: 50% reserved, 50% cash-out tax, no duration (persists forever).
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 5000, // 50%
            cashOutTaxRate: 5000, // 50%
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
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

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = splitGroups;
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Fee project (#1) — no reserved splits required, kept clean.
        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        feeRulesetConfig[0].duration = 0;
        feeRulesetConfig[0].weight = WEIGHT;
        feeRulesetConfig[0].weightCutPercent = 0;
        feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        feeRulesetConfig[0].metadata = metadata;
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: tokensToAccept});

        // Fee project (#1).
        _controller.launchProjectFor({
            owner: address(420),
            projectUri: "fee",
            rulesetConfigurations: feeRulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Test project (#2) with reserved-split configured.
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "test",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Deploy ERC20 for the project so reserve recipients receive real ERC20 (or credits if not).
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "Test", "TST", bytes32(0));
    }

    /// @notice Cashing out with pending reserves > 0 auto-settles them, mints to the reserved split,
    /// and reclaims the post-settlement (non-inflated) amount.
    function test_cashOut_autoSettlesPendingReserves() external {
        // Pay the project — 50% goes to payer, 50% accumulates as pending reserves.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);
        assertGt(payerTokens, 0, "Payer should hold tokens after paying");

        uint256 pendingReserves = _controller.pendingReservedTokenBalanceOf(_projectId);
        assertGt(pendingReserves, 0, "Pending reserves should be non-zero before cashout");
        assertEq(_tokens.totalBalanceOf(_reserveRecipient, _projectId), 0, "Recipient has no tokens yet");

        // Snapshot the surplus and the supplies the cashout math would see before AND after settlement.
        uint256 surplus = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 totalWithReservesPre = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);
        uint256 circulatingPre = _tokens.totalSupplyOf(_projectId);
        assertEq(totalWithReservesPre, circulatingPre + pendingReserves, "Total = circulating + pending pre-cashout");

        // Cash out a small slice so the cashout doesn't drain the project — keeps the math clean.
        uint256 cashOutCount = payerTokens / 10;
        assertGt(cashOutCount, 0, "cashOutCount should be non-zero");

        // The post-settlement supply equals the pre-settlement total (pending becomes real on mint).
        uint256 grossReclaim = JBCashOuts.cashOutFrom({
            surplus: surplus,
            cashOutCount: cashOutCount,
            totalSupply: totalWithReservesPre,
            cashOutTaxRate: 5000
        });
        // The beneficiary here is a regular address (not feeless), and the cashOutTaxRate is non-zero
        // (5000), so the terminal applies the standard 2.5% protocol fee to the full reclaim.
        uint256 expectedReclaim = grossReclaim - JBFees.standardFeeAmountFrom(grossReclaim);

        vm.prank(_payer);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: _payer,
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_payer),
            metadata: new bytes(0),
            referralProjectId: 0
        });

        // Pending reserves have been settled.
        assertEq(_controller.pendingReservedTokenBalanceOf(_projectId), 0, "Pending settled to zero");

        // The reserved-split recipient got the full pending amount (100% split).
        assertEq(
            _tokens.totalBalanceOf(_reserveRecipient, _projectId),
            pendingReserves,
            "Reserved recipient received the entire pending reserve allocation"
        );

        // Circulating supply now includes both the original mints AND the reserved mint, minus the burn.
        // We don't assert the precise circulating delta here — the controller flow + burn ordering is
        // already covered by other tests. The reclaim equivalence is the load-bearing assertion.
        assertEq(reclaim, expectedReclaim, "Reclaim equals the post-settlement cashout formula minus fee");
    }

    /// @notice Cashing out when pending == 0 is a no-op for the guard (no revert from the controller).
    function test_cashOut_zeroPending_isNoOp() external {
        // Pay, then manually distribute reserves so pending == 0 going into the cashout.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        _controller.sendReservedTokensToSplitsOf(_projectId);
        assertEq(_controller.pendingReservedTokenBalanceOf(_projectId), 0, "Pre-cashout pending is zero");

        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);
        uint256 cashOutCount = payerTokens / 10;
        assertGt(cashOutCount, 0, "cashOutCount should be non-zero");

        // Should succeed without invoking the controller's reserved-settle path.
        vm.prank(_payer);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: _payer,
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_payer),
            metadata: new bytes(0),
            referralProjectId: 0
        });

        assertGt(reclaim, 0, "Reclaim should be non-zero on a healthy cashout");
        assertEq(_controller.pendingReservedTokenBalanceOf(_projectId), 0, "Pending remains zero");
    }
}
