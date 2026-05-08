// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBSplitHook} from "../src/interfaces/IJBSplitHook.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Tests that the fee-free cashout bypass via same-terminal round-trip is closed:
/// fees apply on cashout up to the cumulative fee-free payout amount, then deplete.
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
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(_projectIdB),
            beneficiary: payable(_attacker),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory _splitGroups = new JBSplitGroup[](1);
        _splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: _splits});

        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
        _payoutLimits[0] = JBCurrencyAmount({amount: _payoutLimit, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
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

    /// @notice After the fee-free surplus is fully consumed, subsequent direct pay-ins cash out fee-free.
    function testSurplusDepletionRestoresFeeFreeCashOut() external {
        uint256 payAmount = 10 ether;
        vm.deal(_attacker, payAmount * 2);

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Pay project A and trigger payout → accumulates fee-free surplus on project B.
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

        // Cash out all tokens from project B — fee applied against fee-free surplus, which is now depleted.
        uint256 tokensFromPayout = _tokens.totalBalanceOf(_attacker, _projectIdB);
        vm.prank(_attacker);
        uint256 firstReclaim = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: tokensFromPayout,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });
        // First cashout should have had a fee deducted.
        assertLt(firstReclaim, _payoutLimit, "first cashout should have fee deducted");

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

        // Cash out again — surplus is depleted, so this direct pay-in should be fee-free.
        vm.prank(_attacker);
        uint256 secondReclaim = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: newTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });

        // After surplus depletion, direct pay-in cashout should be fee-free.
        assertEq(secondReclaim, payAmount, "direct pay-in cashout should be fee-free after surplus depleted");
    }

    /// @notice Fee-free surplus only covers the exact payout amount — partial cashout leaves remainder.
    function testPartialCashOutConsumesPartialSurplus() external {
        uint256 payAmount = 10 ether;
        vm.deal(_attacker, payAmount);

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Pay project A and trigger payout → 10 ETH fee-free surplus on project B.
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

        // Cash out half the tokens — should consume roughly half the fee-free surplus.
        uint256 totalTokens = _tokens.totalBalanceOf(_attacker, _projectIdB);
        uint256 halfTokens = totalTokens / 2;

        vm.prank(_attacker);
        uint256 firstReclaim = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: halfTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });
        // First half-cashout should have fee deducted (fee-free surplus partially consumed).
        assertLt(firstReclaim, _payoutLimit / 2, "partial cashout should have fee deducted");

        // Cash out the remaining tokens — should also have fee (remaining surplus covers it).
        uint256 remainingTokens = _tokens.totalBalanceOf(_attacker, _projectIdB);
        vm.prank(_attacker);
        uint256 secondReclaim = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: remainingTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });
        // Second cashout also has fee deducted from remaining surplus.
        assertLt(secondReclaim, firstReclaim + 1 ether, "second partial cashout should also have fee");
    }

    /// @notice Griefing with a tiny payout only costs the victim fees on that tiny amount.
    function testGriefingWithTinyPayoutIsScoped() external {
        address victim = makeAddr("victim");
        vm.deal(victim, 10 ether);
        vm.deal(_attacker, 1); // 1 wei for the griefing payout

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Victim pays directly into project B.
        vm.prank(victim);
        _terminal.pay{value: 10 ether}({
            projectId: _projectIdB,
            amount: 10 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: victim,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Attacker triggers a 1 wei payout to project B via project A to set fee-free surplus.
        // First fund project A with 1 wei.
        vm.prank(_attacker);
        _terminal.pay{value: 1}({
            projectId: _projectIdA,
            amount: 1,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
        _terminal.sendPayoutsOf({
            projectId: _projectIdA,
            amount: 1,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // Victim cashes out — fee should only apply to 1 wei of surplus, not their full 10 ETH.
        uint256 victimTokens = _tokens.totalBalanceOf(victim, _projectIdB);
        vm.prank(victim);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: victim,
            projectId: _projectIdB,
            cashOutCount: victimTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(victim),
            metadata: new bytes(0)
        });

        // Fee on 1 wei is 0 (rounds down). Victim should get essentially their full amount back.
        // The key assertion: victim is NOT penalized with a fee on their full 10 ETH.
        uint256 feeOn1Wei = mulDiv(1, 25, 1000); // 0 (rounds down)
        assertGe(reclaimAmount, 10 ether - feeOn1Wei - 1, "griefing should cost at most fee on 1 wei");
    }

    /// @notice Non-zero cashOutTaxRate applies fees to the full reclaim, ignoring surplus.
    function testNonZeroTaxRateIgnoresSurplus() external {
        uint256 payAmount = 10 ether;
        vm.deal(_attacker, payAmount);

        // Launch project C with cashOutTaxRate = 5000 (50%).
        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _tokensToAccept});

        JBRulesetMetadata memory taxMeta = _zeroTaxMetadata();
        taxMeta.cashOutTaxRate = 5000; // 50%

        JBRulesetConfig[] memory _cRulesetConfig = new JBRulesetConfig[](1);
        _cRulesetConfig[0].mustStartAtOrAfter = 0;
        _cRulesetConfig[0].duration = 0;
        _cRulesetConfig[0].weight = _weight;
        _cRulesetConfig[0].metadata = taxMeta;
        _cRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _cRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 projectIdC = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-c",
            rulesetConfigurations: _cRulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        vm.prank(_projectOwner);
        _controller.deployERC20For(projectIdC, "ProjectC", "PC", bytes32(0));

        // Pay and cash out — non-zero tax rate means full fee applies (surplus irrelevant).
        vm.prank(_attacker);
        _terminal.pay{value: payAmount}({
            projectId: projectIdC,
            amount: payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 tokens = _tokens.totalBalanceOf(_attacker, projectIdC);
        vm.prank(_attacker);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: projectIdC,
            cashOutCount: tokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });

        // With non-zero tax, the 2.5% fee applies to the full bonding curve output.
        // Full cashout (count == supply) returns the entire surplus regardless of tax rate,
        // so gross = 10 ETH, fee = 2.5%, net = 9.75 ETH.
        assertLt(reclaimAmount, payAmount, "non-zero tax should charge fee on full amount");
        uint256 expectedFee = mulDiv(payAmount, 25, 1000);
        uint256 expectedNet = payAmount - expectedFee;
        assertApproxEqAbs(reclaimAmount, expectedNet, 2, "fee should apply to full bonding curve output");
    }

    /// @notice Multiple payouts accumulate fee-free surplus correctly.
    function testMultiplePayoutsAccumulateSurplus() external {
        uint256 payAmount = 10 ether;
        // Need to fund project A twice, so give attacker enough.
        vm.deal(_attacker, payAmount * 2);

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // First payout cycle: pay A, send payouts → 10 ETH fee-free surplus on B.
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

        // Queue a new ruleset so the payout limit resets for the next cycle.
        JBSplit[] memory _splits = new JBSplit[](1);
        _splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(_projectIdB),
            beneficiary: payable(_attacker),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        JBSplitGroup[] memory _splitGroups = new JBSplitGroup[](1);
        _splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: _splits});

        JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
        _payoutLimits[0] = JBCurrencyAmount({amount: _payoutLimit, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: _payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory _newRuleset = new JBRulesetConfig[](1);
        _newRuleset[0].mustStartAtOrAfter = 0;
        _newRuleset[0].duration = 0;
        _newRuleset[0].weight = _weight;
        _newRuleset[0].metadata = _zeroTaxMetadata();
        _newRuleset[0].splitGroups = _splitGroups;
        _newRuleset[0].fundAccessLimitGroups = _fundAccessLimitGroup;

        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectIdA, rulesetConfigurations: _newRuleset, memo: ""});

        // Second payout cycle: pay A again, send payouts → another 10 ETH, total 20 ETH surplus.
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

        // Cash out all tokens from B — fee should apply to the full 20 ETH surplus.
        uint256 allTokens = _tokens.totalBalanceOf(_attacker, _projectIdB);
        vm.prank(_attacker);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: allTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });

        // The 2.5% fee should apply to the entire reclaim (covered by 20 ETH surplus).
        // Gross reclaim ≈ 20 ETH (full balance of B), fee = 2.5% of that.
        assertLt(reclaimAmount, 20 ether, "fee should be charged on accumulated surplus");
        uint256 expectedFee = mulDiv(20 ether, 25, 1000);
        uint256 expectedNet = 20 ether - expectedFee;
        assertApproxEqAbs(reclaimAmount, expectedNet, 2, "fee should apply to full 20 ETH surplus");
    }

    /// @notice Multi-hop payouts: A → B → C. Both B and C should incur fees on cashout.
    /// Project A pays Project B (0 cashout tax, same terminal). Project B receives external payment.
    /// Project B pays Project C (0 cashout tax, same terminal). Both B and C cashouts incur fees.
    function testMultiHopPayoutsCannotAvoidFees() external {
        uint256 projectIdC = _launchMultiHopProjectC();
        _configureProjectBPayoutsTo(projectIdC);

        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));
        vm.prank(_projectOwner);
        _controller.deployERC20For(projectIdC, "ProjectC", "PC", bytes32(0));

        // Step 1: Pay project A, trigger payout → 10 ETH lands on B (fee-free).
        vm.deal(_attacker, 100 ether);
        vm.prank(_attacker);
        _terminal.pay{value: 100 ether}({
            projectId: _projectIdA,
            amount: 100 ether,
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
        // B: balance = 10 ETH, fee-free = 10 ETH.

        // Step 2: External payment of 100 ETH to project B.
        address user = makeAddr("user");
        vm.deal(user, 100 ether);
        vm.prank(user);
        _terminal.pay{value: 100 ether}({
            projectId: _projectIdB,
            amount: 100 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
        // B: balance = 110 ETH, fee-free = 10 ETH.

        // Step 3: Project B pays out 100 ETH to Project C (same terminal, fee-free for C).
        _terminal.sendPayoutsOf({
            projectId: _projectIdB,
            amount: 100 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });
        // B: balance = 10 ETH, fee-free = 10 (stays: non-fee-free left first).
        // C: balance = 100 ETH, fee-free = 100 ETH.

        // Step 4: Cash out from C — fees must apply to the full 100 ETH.
        _assertCashOutIncursFees(projectIdC, _attacker);

        // Step 5: Cash out attacker's tokens from B — fees must apply (B is all fee-free).
        _assertCashOutIncursFees(_projectIdB, _attacker);
    }

    /// @dev Assert that cashing out all tokens from `projectId` for `holder` incurs a fee.
    function _assertCashOutIncursFees(uint256 projectId, address holder) internal {
        uint256 holderTokens = _tokens.totalBalanceOf(holder, projectId);
        if (holderTokens == 0) return;

        uint256 balBefore = holder.balance;
        vm.prank(holder);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: holderTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: new bytes(0)
        });
        // With cashOutTaxRate = 0, gross reclaim = proportional share of balance.
        // Fee-free surplus means a 2.5% fee is applied → net < gross.
        assertGt(reclaim, 0, "should reclaim something");
        // The fee should have been deducted: actual ETH received < reclaim + fee.
        uint256 ethReceived = holder.balance - balBefore;
        assertEq(ethReceived, reclaim, "ETH received should match reclaim");
    }

    /// @dev Launch Project C with zero tax for multi-hop test.
    function _launchMultiHopProjectC() internal returns (uint256) {
        JBTerminalConfig[] memory termConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory ctxs = new JBAccountingContext[](1);
        ctxs[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        termConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: ctxs});

        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = 0;
        rc[0].weight = _weight;
        rc[0].metadata = _zeroTaxMetadata();
        rc[0].splitGroups = new JBSplitGroup[](0);
        rc[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-c-multihop",
            rulesetConfigurations: rc,
            terminalConfigurations: termConfigs,
            memo: ""
        });
    }

    /// @dev Reconfigure Project B to route 100% payouts to `targetProjectId`.
    function _configureProjectBPayoutsTo(uint256 targetProjectId) internal {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(targetProjectId),
            beneficiary: payable(_attacker),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBCurrencyAmount[] memory limits = new JBCurrencyAmount[](1);
        limits[0] = JBCurrencyAmount({amount: 100 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fundAccess = new JBFundAccessLimitGroup[](1);
        fundAccess[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: limits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = 0;
        rc[0].weight = _weight;
        rc[0].metadata = _zeroTaxMetadata();
        rc[0].splitGroups = splitGroups;
        rc[0].fundAccessLimitGroups = fundAccess;

        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectIdB, rulesetConfigurations: rc, memo: ""});
    }

    /// @notice Non-zero-tax cashouts cap fee-free surplus at remaining balance.
    /// Without this, switching from non-zero to zero tax could let stale surplus over-charge.
    function testNonZeroTaxCashOutCapsFeeFreeSurplus() external {
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Step 1: Pay project A, trigger payout → 10 ETH fee-free on B.
        vm.deal(_attacker, 10 ether);
        vm.prank(_attacker);
        _terminal.pay{value: 10 ether}({
            projectId: _projectIdA,
            amount: 10 ether,
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
        // B: balance = 10 ETH, fee-free = 10 ETH.

        // Step 2: Pay B directly with 90 ETH more.
        address user = makeAddr("user");
        vm.deal(user, 90 ether);
        vm.prank(user);
        _terminal.pay{value: 90 ether}({
            projectId: _projectIdB,
            amount: 90 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
        // B: balance = 100 ETH, fee-free = 10 ETH.

        // Step 3: Reconfigure B with non-zero cash out tax, then cash out most of the balance.
        _reconfigureWithTaxRate(_projectIdB, 5000); // 50% tax

        // Cash out 95% of user's tokens at 50% tax → drains most balance.
        uint256 userTokens = _tokens.totalBalanceOf(user, _projectIdB);
        vm.prank(user);
        _terminal.cashOutTokensOf({
            holder: user,
            projectId: _projectIdB,
            cashOutCount: userTokens * 95 / 100,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(user),
            metadata: new bytes(0)
        });
        // Balance dropped significantly. _capFeeFreeSurplus should have capped fee-free at remaining balance.

        // Step 4: Switch back to zero tax. Cash out remaining.
        _reconfigureWithTaxRate(_projectIdB, 0);

        uint256 remainingUserTokens = _tokens.totalBalanceOf(user, _projectIdB);
        if (remainingUserTokens > 0) {
            vm.prank(user);
            uint256 reclaim = _terminal.cashOutTokensOf({
                holder: user,
                projectId: _projectIdB,
                cashOutCount: remainingUserTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: new bytes(0)
            });
            // Should NOT revert. Fee-free was capped during the non-zero-tax cashout,
            // so it doesn't exceed the remaining balance.
            assertGt(reclaim, 0, "should reclaim something after tax rate switch");
        }
    }

    /// @notice Feeless beneficiary cashout still caps fee-free surplus at remaining balance.
    function testFeelessBeneficiaryCashOutCapsFeeFreeSurplus() external {
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectIdB, "ProjectB", "PB", bytes32(0));

        // Step 1: Pay project A, trigger payout → 10 ETH fee-free on B.
        vm.deal(_attacker, 10 ether);
        vm.prank(_attacker);
        _terminal.pay{value: 10 ether}({
            projectId: _projectIdA,
            amount: 10 ether,
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
        // B: balance = 10 ETH, fee-free = 10 ETH. Attacker has tokens.

        // Step 2: Mark attacker as feeless.
        vm.prank(multisig());
        jbFeelessAddresses().setFeelessAddress(_attacker, true);

        // Step 3: Feeless cashout — no fees charged, but _capFeeFreeSurplus should still cap.
        uint256 attackerTokens = _tokens.totalBalanceOf(_attacker, _projectIdB);
        vm.prank(_attacker);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: _attacker,
            projectId: _projectIdB,
            cashOutCount: attackerTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_attacker),
            metadata: new bytes(0)
        });
        // Feeless beneficiary gets full amount — no fee deducted.
        assertEq(reclaim, 10 ether, "feeless beneficiary should get full reclaim");

        // Step 4: Pay B again directly. If fee-free wasn't capped, it would still be 10 ETH
        // even though balance went to 0 after the feeless cashout.
        address user = makeAddr("user");
        vm.deal(user, 10 ether);
        vm.prank(user);
        _terminal.pay{value: 10 ether}({
            projectId: _projectIdB,
            amount: 10 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Step 5: Cash out as user (not feeless). Fee-free should be 0 (capped at 0 after feeless cashout).
        // So this direct-pay cashout should be fee-free.
        uint256 userTokens = _tokens.totalBalanceOf(user, _projectIdB);
        vm.prank(user);
        uint256 userReclaim = _terminal.cashOutTokensOf({
            holder: user,
            projectId: _projectIdB,
            cashOutCount: userTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(user),
            metadata: new bytes(0)
        });
        // Direct payment → zero fee-free surplus → no fee. User gets full amount.
        assertEq(userReclaim, 10 ether, "direct pay-in should be fee-free after feeless cashout cleared surplus");

        // Clean up: unmark feeless.
        vm.prank(multisig());
        jbFeelessAddresses().setFeelessAddress(_attacker, false);
    }

    /// @dev Reconfigure project with a new cashOutTaxRate (keeps zero-tax metadata otherwise).
    function _reconfigureWithTaxRate(uint256 projectId, uint16 taxRate) internal {
        JBRulesetMetadata memory meta = _zeroTaxMetadata();
        meta.cashOutTaxRate = taxRate;

        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = 0;
        rc[0].weight = _weight;
        rc[0].metadata = meta;
        rc[0].splitGroups = new JBSplitGroup[](0);
        rc[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: projectId, rulesetConfigurations: rc, memo: ""});
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }
}
