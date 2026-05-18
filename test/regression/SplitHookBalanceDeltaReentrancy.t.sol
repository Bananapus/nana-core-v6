// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
import {IJBTokens} from "../../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "../../src/structs/JBSplitHookContext.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract BalanceDeltaCashOutSplitHook is ERC165, IJBSplitHook {
    IJBMultiTerminal public terminal;
    uint256 public targetProjectId;
    uint256 public reentrantReclaim;

    constructor(IJBMultiTerminal _terminal) {
        terminal = _terminal;
    }

    function setTargetProject(uint256 projectId) external {
        targetProjectId = projectId;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {
        IJBTokens tokens = terminal.TOKENS();
        uint256 balance = tokens.totalBalanceOf(address(this), targetProjectId);

        if (balance != 0) {
            reentrantReclaim = terminal.cashOutTokensOf({
                holder: address(this),
                projectId: targetProjectId,
                cashOutCount: balance,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(address(this)),
                metadata: new bytes(0),
                referralProjectId: 0
            });
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}

contract BalanceDeltaPaySplitHook is ERC165, IJBSplitHook {
    IJBMultiTerminal public terminal;
    uint256 public targetProjectId;
    uint256 public reentrantTokenCount;

    constructor(IJBMultiTerminal _terminal) {
        terminal = _terminal;
    }

    function setTargetProject(uint256 projectId) external {
        targetProjectId = projectId;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {
        if (msg.value != 0) {
            reentrantTokenCount = terminal.pay{value: msg.value}({
                projectId: targetProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: msg.value,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "reentrant split pay",
                metadata: new bytes(0)
            });
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}

contract SplitHookBalanceDeltaReentrancy is TestBaseWorkflow {
    uint256 private constant FEE_PROJECT_ID = 1;
    uint256 private constant ORIGIN_PAYOUT = 5 ether;
    uint256 private constant TARGET_FUNDING = 10 ether;

    address private _projectOwner;
    BalanceDeltaCashOutSplitHook private _hook;

    function setUp() public override {
        super.setUp();
        _projectOwner = multisig();
        _launchFeeProject();
    }

    function test_splitHookReentrantCashoutDoesNotInflateFeeAccounting() external {
        _hook = new BalanceDeltaCashOutSplitHook(jbMultiTerminal());

        uint256 targetProjectId = _launchProjectWithSplitsAndPayoutLimit(new JBSplit[](0), 0);
        _hook.setTargetProject(targetProjectId);

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(_hook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(_hook))
        });

        uint256 originProjectId = _launchProjectWithSplitsAndPayoutLimit(splits, ORIGIN_PAYOUT);

        _payProject(targetProjectId, address(_hook), TARGET_FUNDING);
        _payProject(originProjectId, address(0xBA1E), ORIGIN_PAYOUT);

        uint256 feeProjectBalanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 ownerFeeTokensBefore = jbTokens().totalBalanceOf(_projectOwner, FEE_PROJECT_ID);

        vm.prank(_projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: originProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: ORIGIN_PAYOUT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        uint256 expectedFee =
            JBFees.feeAmountFrom({amountBeforeFee: ORIGIN_PAYOUT, feePercent: JBConstants.STANDARD_FEE});
        uint256 feeProjectBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 ownerFeeTokensAfter = jbTokens().totalBalanceOf(_projectOwner, FEE_PROJECT_ID);

        // The hook successfully drained its tokens via a reentrant cashOutTokensOf, so the terminal sent
        // out (target's recorded balance) ETH on top of the split. With the BN fix the split's consumed
        // amount is anchored to the offered netPayoutAmount, so the held-fee credit on the origin split
        // is exactly the protocol-defined fee on the gross payout — not inflated by the reentrant outflow.
        assertGt(_hook.reentrantReclaim(), 0, "hook still creates a reentrant terminal outflow");
        assertEq(feeProjectBalanceAfter - feeProjectBalanceBefore, expectedFee, "fee accounting matches gross payout");
        assertEq(
            ownerFeeTokensAfter - ownerFeeTokensBefore, expectedFee * 1000, "fee project token mint matches gross fee"
        );

        // Recorded balances across all involved projects must remain <= the terminal's actual ETH backing.
        uint256 recordedTotal = jbTerminalStore()
            .balanceOf(address(jbMultiTerminal()), originProjectId, JBConstants.NATIVE_TOKEN)
        + jbTerminalStore().balanceOf(address(jbMultiTerminal()), targetProjectId, JBConstants.NATIVE_TOKEN)
        + feeProjectBalanceAfter;
        assertLe(recordedTotal, address(jbMultiTerminal()).balance, "recorded balances never exceed terminal backing");
    }

    function test_splitHookReentrantPayDoesNotDoubleCreditOriginAndTarget() external {
        BalanceDeltaPaySplitHook payHook = new BalanceDeltaPaySplitHook(jbMultiTerminal());

        uint256 targetProjectId = _launchProjectWithSplitsAndPayoutLimit(new JBSplit[](0), 0);
        payHook.setTargetProject(targetProjectId);

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(payHook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(payHook))
        });

        uint256 originProjectId = _launchProjectWithSplitsAndPayoutLimit(splits, ORIGIN_PAYOUT);
        _payProject(originProjectId, address(0xBA1E), ORIGIN_PAYOUT);

        uint256 terminalBalanceBefore = address(jbMultiTerminal()).balance;
        uint256 expectedFee =
            JBFees.feeAmountFrom({amountBeforeFee: ORIGIN_PAYOUT, feePercent: JBConstants.STANDARD_FEE});
        uint256 expectedNetPayout = ORIGIN_PAYOUT - expectedFee;

        vm.prank(_projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: originProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: ORIGIN_PAYOUT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        uint256 originRecordedBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), originProjectId, JBConstants.NATIVE_TOKEN);
        uint256 targetRecordedBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), targetProjectId, JBConstants.NATIVE_TOKEN);
        uint256 feeProjectBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        // The hook still reenters pay() and forwards its net split allocation to the target project. The
        // terminal's ETH balance is unchanged because the hook re-deposited the value via pay(). The BN
        // fix anchors the split's consumed amount to the offered netPayoutAmount, so the origin's payout
        // is treated as fully consumed (no spurious refund). Target receives the net amount via pay; the
        // fee project receives the held fee on the gross payout.
        assertGt(payHook.reentrantTokenCount(), 0, "hook reenters pay");
        assertEq(address(jbMultiTerminal()).balance, terminalBalanceBefore, "terminal balance unchanged");
        assertEq(originRecordedBalance, 0, "origin payout is fully consumed - no spurious refund");
        assertEq(targetRecordedBalance, expectedNetPayout, "target project credited via reentrant pay");
        assertEq(feeProjectBalance, expectedFee, "fee project receives the held fee on origin's gross payout");
        assertEq(
            originRecordedBalance + targetRecordedBalance + feeProjectBalance,
            address(jbMultiTerminal()).balance,
            "recorded balances match the terminal's actual ETH backing"
        );
    }

    function _launchFeeProject() private {
        JBRulesetConfig[] memory rulesetConfig = _rulesetConfig(new JBSplit[](0), 0);
        rulesetConfig[0].metadata.allowOwnerMinting = false;
        rulesetConfig[0].metadata.allowSetCustomToken = false;

        uint256 feeProjectId = jbController()
            .launchProjectFor({
            owner: address(420),
            projectUri: "feeCollector",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });

        assertEq(feeProjectId, FEE_PROJECT_ID, "fee project must be project 1");
    }

    function _launchProjectWithSplitsAndPayoutLimit(
        JBSplit[] memory splits,
        uint256 payoutLimit
    )
        private
        returns (uint256)
    {
        return jbController()
            .launchProjectFor({
            owner: _projectOwner,
            projectUri: "splitHookBalanceDelta",
            rulesetConfigurations: _rulesetConfig(splits, payoutLimit),
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _rulesetConfig(
        JBSplit[] memory splits,
        uint256 payoutLimit
    )
        private
        view
        returns (JBRulesetConfig[] memory rulesetConfig)
    {
        rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
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

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        rulesetConfig[0].splitGroups = splitGroups;

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBCurrencyAmount({amount: uint224(payoutLimit), currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;
    }

    function _defaultTerminalConfig() private view returns (JBTerminalConfig[] memory terminalConfigurations) {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});
    }

    function _payProject(uint256 projectId, address beneficiary, uint256 amount) private {
        vm.deal(beneficiary, amount);
        vm.prank(beneficiary);
        jbMultiTerminal().pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }
}
