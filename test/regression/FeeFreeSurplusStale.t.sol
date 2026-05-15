// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
import {JBTokens} from "../../src/JBTokens.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract FeeFreeSurplusStaleTest is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    JBTokens private _tokens;

    uint256 private _projectIdA;
    uint256 private _projectIdB;
    address private _projectOwner;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint256 private constant PAY_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();
        _projectOwner = multisig();

        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: accountingContexts});

        JBRulesetConfig[] memory feeProjectRuleset = new JBRulesetConfig[](1);
        feeProjectRuleset[0] = _rulesetConfig({
            metadata: _metadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _controller.launchProjectFor({
            owner: makeAddr("fee-project-owner"),
            projectUri: "fee-project",
            rulesetConfigurations: feeProjectRuleset,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        surplusAllowances[0] = JBCurrencyAmount({
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint224(PAY_AMOUNT),
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: new JBCurrencyAmount[](0),
            surplusAllowances: surplusAllowances
        });

        JBRulesetConfig[] memory projectBRuleset = new JBRulesetConfig[](1);
        projectBRuleset[0] = _rulesetConfig({
            metadata: _metadata(), splitGroups: new JBSplitGroup[](0), fundAccessLimitGroups: fundAccessLimitGroups
        });

        _projectIdB = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-b",
            rulesetConfigurations: projectBRuleset,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: true,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(_projectIdB),
            beneficiary: payable(address(0)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint224(PAY_AMOUNT),
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBFundAccessLimitGroup[] memory projectALimits = new JBFundAccessLimitGroup[](1);
        projectALimits[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory projectARuleset = new JBRulesetConfig[](1);
        projectARuleset[0] =
            _rulesetConfig({metadata: _metadata(), splitGroups: splitGroups, fundAccessLimitGroups: projectALimits});

        _projectIdA = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-a",
            rulesetConfigurations: projectARuleset,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    function test_staleFeeFreeSurplusDoubleChargesFutureZeroTaxCashOut() external {
        address payerA = makeAddr("payerA");
        address payerB = makeAddr("payerB");

        vm.deal(payerA, PAY_AMOUNT);
        vm.deal(payerB, PAY_AMOUNT);

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        vm.prank(payerA);
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectIdA,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payerA,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        _terminal.sendPayoutsOf({
            projectId: _projectIdA,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        vm.prank(_projectOwner);
        _terminal.useAllowanceOf({
            projectId: _projectIdB,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(_projectOwner),
            feeBeneficiary: payable(_projectOwner),
            memo: "drain fee-free payout"
        });

        vm.prank(payerB);
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectIdB,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payerB,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 tokenBalance = _tokens.totalBalanceOf(payerB, _projectIdB);
        assertGt(tokenBalance, 0, "payerB should receive project B tokens");

        vm.prank(payerB);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: payerB,
            projectId: _projectIdB,
            cashOutCount: tokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(payerB),
            metadata: new bytes(0)
        });

        // After the fix: useAllowanceOf proportionally reduces the fee-free surplus.
        // Since the full balance was drained, the fee-free surplus is now 0.
        // payerB's direct pay-in → cashout with cashOutTaxRate=0 and no fee-free surplus → fee-free.
        assertEq(reclaimAmount, PAY_AMOUNT, "direct pay-in cashout is fee-free after surplus cleared by allowance");
    }

    function _metadata() private pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: true,
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
            allowCrossProjectFeeFreeInflows: false
        });
    }

    function _rulesetConfig(
        JBRulesetMetadata memory metadata,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        private
        pure
        returns (JBRulesetConfig memory config)
    {
        config.mustStartAtOrAfter = 0;
        config.duration = 0;
        config.weight = WEIGHT;
        config.weightCutPercent = 0;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
        config.metadata = metadata;
        config.splitGroups = splitGroups;
        config.fundAccessLimitGroups = fundAccessLimitGroups;
    }
}
