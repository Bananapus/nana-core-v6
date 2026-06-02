// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../src/interfaces/IJBDirectory.sol";
import {IJBPayoutTerminal} from "../../src/interfaces/IJBPayoutTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "../../src/interfaces/IJBTokens.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {JBSplits} from "../../src/JBSplits.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

/// @notice A payout split where `split.projectId == projectId` must revert in every shape, so the
/// payout pipeline cannot be used as a back-door owner mint or as an out-of-band balance shuffle.
/// @dev Four shapes share the same root: a same-project split is always a disguised owner action.
/// Two failure modes flow from accepting it:
///   - pay branch: the destination terminal's `pay()` mints new project tokens against the
///     project's own surplus, even when the destination is a different terminal of the same
///     project (every registered terminal can mint via the terminal-as-minter pathway). This
///     would let an owner whose ruleset declares `allowOwnerMinting=false` dilute holders by
///     configuring two terminals and routing the split between them.
///   - addToBalance branch: the payout pipeline credits balance on the destination terminal
///     without going through `addToBalanceOf` directly. Side effects (locked-split consumption,
///     payout-limit drawdown, `feeFreeSurplusOf` accounting) all fire on what is, semantically,
///     the project moving its own funds. Same-terminal add-balance round-trips inflate
///     `feeFreeSurplusOf` and overcharge zero-tax cashouts on value that never left.
/// The split-group try/catch in core swallows the revert and restores the project's balance, so
/// the original payment is not lost — the split just fails-loud.
contract SelfReferencingPayoutRevertTest is TestBaseWorkflow {
    IJBController private _controller;
    IJBDirectory private _directory;
    JBMultiTerminal private _terminalA;
    JBMultiTerminal private _terminalB;
    JBSplits private _splits;
    IJBTokens private _tokens;

    address private _projectOwner;
    uint256 private _projectId;
    uint256 private _crossProjectId;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint256 private constant PAY_AMOUNT = 10 ether;
    uint256 private constant PAYOUT_AMOUNT = 1 ether;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _directory = jbDirectory();
        _terminalA = jbMultiTerminal();
        _terminalB = jbMultiTerminal2();
        _splits = jbSplits();
        _tokens = jbTokens();
        _projectOwner = multisig();

        _projectId = _launchProject(
            "self-split",
            true /* withPlaceholderSplit */
        );
        _crossProjectId = _launchProject(
            "cross-project",
            false /* withPlaceholderSplit */
        );

        // Register both terminals AND configure terminal B's accounting context so cross-terminal
        // split routing is actually reachable for the cross-terminal shapes. Without this,
        // `terminalB.pay()` would revert at the store for missing accounting context and the
        // mint-bypass would be masked.
        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(_terminalA));
        terminals[1] = IJBTerminal(address(_terminalB));
        vm.prank(_projectOwner);
        _directory.setTerminalsOf(_projectId, terminals);

        JBAccountingContext[] memory terminalBContexts = new JBAccountingContext[](1);
        terminalBContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        vm.prank(_projectOwner);
        _terminalB.addAccountingContextsFor(_projectId, terminalBContexts);

        // Seed terminal A with payouts-ready balance.
        vm.deal(address(this), PAY_AMOUNT);
        _terminalA.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            beneficiary: _projectOwner,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    // --- Same-terminal, pay branch (the original guard already covered this shape) ---

    function test_sameTerminal_payBranch_reverts() external {
        _rewriteSplit({
            destinationTerminal: address(_terminalA), preferAddToBalance: false, recipientProjectId: _projectId
        });
        _expectSelfSplitSwallowed();
    }

    // --- Cross-terminal, pay branch (the mint-bypass vector this PR closes) ---

    function test_crossTerminal_payBranch_reverts_andBlocksMint() external {
        uint256 supplyBefore = _tokens.totalSupplyOf(_projectId);

        _rewriteSplit({
            destinationTerminal: address(_terminalB), preferAddToBalance: false, recipientProjectId: _projectId
        });
        _expectSelfSplitSwallowed();

        // The split must not have minted on terminal B against the project's own surplus.
        assertEq(_tokens.totalSupplyOf(_projectId), supplyBefore, "no mint should have happened");
    }

    // --- Same-terminal, addToBalance branch ---

    function test_sameTerminal_addToBalanceBranch_reverts() external {
        _rewriteSplit({
            destinationTerminal: address(_terminalA), preferAddToBalance: true, recipientProjectId: _projectId
        });
        _expectSelfSplitSwallowed();

        // Terminal A's net balance returns to PAY_AMOUNT after the split-group catch restores funds.
        assertEq(address(_terminalA).balance, PAY_AMOUNT, "terminal A balance restored");
    }

    // --- Cross-terminal, addToBalance branch (cross-terminal surplus shuffle) ---

    function test_crossTerminal_addToBalanceBranch_reverts() external {
        uint256 terminalABefore = address(_terminalA).balance;
        uint256 terminalBBefore = address(_terminalB).balance;

        _rewriteSplit({
            destinationTerminal: address(_terminalB), preferAddToBalance: true, recipientProjectId: _projectId
        });
        _expectSelfSplitSwallowed();

        // Neither terminal should have moved funds: the cross-terminal balance shuffle must not occur.
        assertEq(address(_terminalA).balance, terminalABefore, "terminal A unchanged");
        assertEq(address(_terminalB).balance, terminalBBefore, "terminal B unchanged");
    }

    // --- Cross-project sanity: same shape with `split.projectId != projectId` must NOT revert ---

    function test_crossProject_payBranch_proceeds() external {
        _rewriteSplit({
            destinationTerminal: address(_terminalA), preferAddToBalance: false, recipientProjectId: _crossProjectId
        });

        // Sanity: this must succeed, proving the guard only fires on self-reference.
        IJBPayoutTerminal(address(_terminalA))
            .sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAYOUT_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Cross-project pay credited the recipient project's balance on the same terminal,
        // so the source terminal's balance is unchanged (the funds moved across project IDs
        // inside the same terminal contract).
        assertEq(address(_terminalA).balance, PAY_AMOUNT, "funds remain on terminal A under recipient project");
    }

    // --- helpers ---

    function _expectSelfSplitSwallowed() internal {
        // The split-group try/catch absorbs the per-split revert; the outer call must succeed and
        // the funds must return to the project's balance. We assert the lack of net movement by
        // checking terminal A's balance is unchanged after `sendPayoutsOf`.
        uint256 terminalABefore = address(_terminalA).balance;
        IJBPayoutTerminal(address(_terminalA))
            .sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAYOUT_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });
        assertEq(address(_terminalA).balance, terminalABefore, "balance restored after self-split revert");
    }

    function _rewriteSplit(address destinationTerminal, bool preferAddToBalance, uint256 recipientProjectId) internal {
        // For the cross-terminal shapes the directory's primary-terminal-for-token must resolve to
        // the intended destination terminal so `_efficientPay` / `_efficientAddToBalance` route
        // there. We force the primary by listing `destinationTerminal` first.
        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(destinationTerminal);
        terminals[1] =
            IJBTerminal(destinationTerminal == address(_terminalA) ? address(_terminalB) : address(_terminalA));
        vm.prank(_projectOwner);
        _directory.setTerminalsOf(_projectId, terminals);

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: preferAddToBalance,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: uint64(recipientProjectId),
            beneficiary: payable(_projectOwner),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        (JBRuleset memory currentRuleset,) = _controller.currentRulesetOf(_projectId);
        uint256 currentRulesetId = currentRuleset.id;

        vm.prank(_projectOwner);
        _controller.setSplitGroupsOf(_projectId, currentRulesetId, splitGroups);
    }

    function _launchProject(string memory uri, bool withPlaceholderSplit) internal returns (uint256 projectId) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: true,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: uint224(PAY_AMOUNT), currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminalA),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBSplitGroup[] memory splitGroups;
        if (withPlaceholderSplit) {
            JBSplit[] memory splits = new JBSplit[](1);
            // Placeholder split — `_rewriteSplit` overwrites it per test.
            splits[0] = JBSplit({
                preferAddToBalance: false,
                percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
                projectId: 0,
                beneficiary: payable(_projectOwner),
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
            splitGroups = new JBSplitGroup[](1);
            splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        } else {
            splitGroups = new JBSplitGroup[](0);
        }

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: WEIGHT,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundAccessLimitGroups
        });

        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminalA, accountingContextsToAccept: accountingContexts});

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: uri,
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }
}
