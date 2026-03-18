// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../src/interfaces/IJBSplitHook.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBSplitGroupIds} from "../src/libraries/JBSplitGroupIds.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Tests that the fee-free cashout bypass via same-terminal round-trip is closed.
contract TestFeeFreeCashOutBypass is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    JBTokens private _tokens;

    address private _projectOwner;
    address private _attacker;

    // Project A: sends payouts to project B via same terminal.
    uint256 private _projectIdA;
    // Project B: pass-through project with cashOutTaxRate = 0.
    uint256 private _projectIdB;

    uint112 private _weight = 1000 * 10 ** 18;
    uint224 private _payoutLimit = 10 ether;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _attacker = makeAddr("attacker");
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();

        // Shared terminal config.
        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _tokensToAccept});

        // --- Fee-receiving project (project #1) ---
        JBRulesetConfig[] memory _feeRulesetConfig = new JBRulesetConfig[](1);
        _feeRulesetConfig[0].mustStartAtOrAfter = 0;
        _feeRulesetConfig[0].duration = 0;
        _feeRulesetConfig[0].weight = _weight;
        _feeRulesetConfig[0].metadata = _zeroTaxMetadata();
        _feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        _controller.launchProjectFor({
            owner: address(420),
            projectUri: "fee-project",
            rulesetConfigurations: _feeRulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        // --- Project B: pass-through, cashOutTaxRate = 0 ---
        JBRulesetConfig[] memory _bRulesetConfig = new JBRulesetConfig[](1);
        _bRulesetConfig[0].mustStartAtOrAfter = 0;
        _bRulesetConfig[0].duration = 0;
        _bRulesetConfig[0].weight = _weight;
        _bRulesetConfig[0].metadata = _zeroTaxMetadata();
        _bRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _bRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        _projectIdB = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-b",
            rulesetConfigurations: _bRulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        // --- Project A: routes 100% payouts to project B (same terminal) ---
        JBSplit[] memory _splits = new JBSplit[](1);
        _splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: uint64(_projectIdB),
            beneficiary: payable(_attacker),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory _splitGroups = new JBSplitGroup[](1);
        _splitGroups[0] =
            JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: _splits});

        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
        _payoutLimits[0] =
            JBCurrencyAmount({amount: _payoutLimit, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: _payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory _aRulesetConfig = new JBRulesetConfig[](1);
        _aRulesetConfig[0].mustStartAtOrAfter = 0;
        _aRulesetConfig[0].duration = 0;
        _aRulesetConfig[0].weight = _weight;
        _aRulesetConfig[0].metadata = _zeroTaxMetadata();
        _aRulesetConfig[0].splitGroups = _splitGroups;
        _aRulesetConfig[0].fundAccessLimitGroups = _fundAccessLimitGroup;

        _projectIdA = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-a",
            rulesetConfigurations: _aRulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });
    }

    /// @notice After an intra-terminal payout from A → B, cashing out from B charges a fee
    /// even though B has cashOutTaxRate = 0.
    function testCashOutChargesFeeAfterFeeFreePayout() external {
        uint256 payAmount = 10 ether;
        vm.deal(_attacker, payAmount);

        // Deploy ERC-20 for project B so the attacker can cash out.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Step 1: Pay project A.
        vm.prank(_attacker);
        _terminal.pay{value: payAmount}({
            projectId: _projectIdA,
            amount: payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Step 2: Project A sends payouts → funds route to project B (same terminal, fee-free).
        _terminal.sendPayoutsOf({
            projectId: _projectIdA,
            amount: _payoutLimit,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // The attacker now has tokens in project B (from the pay-in routed by the split).
        uint256 attackerTokenBalance = _tokens.totalBalanceOf(_attacker, _projectIdB);
        assertGt(attackerTokenBalance, 0, "attacker should have project B tokens");

        // Step 3: Cash out from project B.
        vm.prank(_attacker);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: attackerTokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });

        // With cashOutTaxRate = 0 the gross reclaim equals the full terminal balance (the payout amount).
        // A 2.5% fee must have been charged, so net = gross * (1 - 2.5%).
        uint256 expectedFee = mulDiv(_payoutLimit, 25, 1000); // 2.5% of 10 ETH
        uint256 expectedNet = _payoutLimit - expectedFee;
        assertApproxEqAbs(reclaimAmount, expectedNet, 2, "fee should be charged on cashout");
        assertLt(reclaimAmount, _payoutLimit, "attacker should not get full amount (fee must apply)");
    }

    /// @notice Direct pay-in → cashout with cashOutTaxRate = 0 remains fee-free (no payout flag set).
    function testCashOutRemainsFeeFreForDirectPayIn() external {
        uint256 payAmount = 10 ether;
        address user = makeAddr("user");
        vm.deal(user, payAmount);

        // Deploy ERC-20 for project B.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Pay directly into project B (no payout from another project).
        vm.prank(user);
        _terminal.pay{value: payAmount}({
            projectId: _projectIdB,
            amount: payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 userTokenBalance = _tokens.totalBalanceOf(user, _projectIdB);
        assertGt(userTokenBalance, 0, "user should have project B tokens");

        // Cash out — should be fee-free since no intra-terminal payout was received.
        vm.prank(user);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: user,
            projectId: _projectIdB,
            cashOutCount: userTokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(user),
            metadata: new bytes(0)
        });

        // With cashOutTaxRate = 0, full cashout returns the entire surplus 1:1.
        // No fee should be charged.
        assertEq(reclaimAmount, payAmount, "direct pay-in cashout should be fee-free");
    }

    /// @notice Once the flag is set, it stays set permanently.
    function testFlagIsPermanent() external {
        uint256 payAmount = 10 ether;
        vm.deal(_attacker, payAmount * 2);

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Pay project A and trigger payout → sets flag on project B.
        vm.prank(_attacker);
        _terminal.pay{value: payAmount}({
            projectId: _projectIdA,
            amount: payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
        _terminal.sendPayoutsOf({
            projectId: _projectIdA,
            amount: _payoutLimit,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // Cash out all tokens from project B (flag is now set).
        uint256 tokensFromPayout = _tokens.totalBalanceOf(_attacker, _projectIdB);
        vm.prank(_attacker);
        _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: tokensFromPayout,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });

        // Now pay project B directly with fresh funds.
        vm.prank(_attacker);
        _terminal.pay{value: payAmount}({
            projectId: _projectIdB,
            amount: payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 newTokens = _tokens.totalBalanceOf(_attacker, _projectIdB);
        assertGt(newTokens, 0, "attacker should have new tokens");

        // Cash out again — fee should STILL be charged because flag is permanent.
        vm.prank(_attacker);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: newTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });

        // Fee should be charged even on direct pay-in cashout, because the flag is permanent.
        assertLt(reclaimAmount, payAmount, "fee should still apply after flag is permanently set");
    }

    function _zeroTaxMetadata() internal pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }
}
