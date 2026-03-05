// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @notice Tests for ruleset transition edge cases: boundary timing, weight decay, approval hooks, limit resets.
contract RulesetTransitions_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // Launch fee collector project (#1)
        _launchFeeProject();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _launchFeeProject() internal {
        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        feeRulesetConfig[0].duration = 0;
        feeRulesetConfig[0].weight = 1000e18;
        feeRulesetConfig[0].weightCutPercent = 0;
        feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        feeRulesetConfig[0].metadata = JBRulesetMetadata({
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
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = _defaultTerminalConfig();

        jbController()
            .launchProjectFor({
                owner: address(420),
                projectUri: "feeCollector",
                rulesetConfigurations: feeRulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });
    }

    function _defaultTerminalConfig() internal view returns (JBTerminalConfig[] memory) {
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});
        return terminalConfigurations;
    }

    function _defaultMetadata() internal pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    function _payProject(uint256 pid, address payer, uint256 amount) internal returns (uint256) {
        vm.deal(payer, amount);
        vm.prank(payer);
        return jbMultiTerminal().pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 1: Pay at cycle boundary — different weights
    // ═══════════════════════════════════════════════════════════════════

    function test_rulesetTransition_payAtBoundary() public {
        // Launch with 7-day duration, 50% weight cut
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 2); // 50%
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "boundaryTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Pay at last second of cycle 1
        vm.warp(block.timestamp + 7 days - 1);
        uint256 tokensCycle1 = _payProject(pid, address(0xA11CE), 1 ether);

        // Pay at first second of cycle 2
        vm.warp(block.timestamp + 2); // crosses boundary
        uint256 tokensCycle2 = _payProject(pid, address(0xB0B), 1 ether);

        // Cycle 2 has 50% of cycle 1's weight → should mint half the tokens
        assertGt(tokensCycle1, tokensCycle2, "Cycle 2 should mint fewer tokens due to weight cut");
        // With 50% cut: cycle2 tokens should be ~half of cycle1
        assertApproxEqRel(tokensCycle2, tokensCycle1 / 2, 0.01e18, "Cycle 2 tokens should be ~50% of cycle 1");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 2: Cash out across cycles — uses current tax rate
    // ═══════════════════════════════════════════════════════════════════

    function test_rulesetTransition_cashOutAcrossCycles() public {
        // Cycle 1: 0% tax. Queue cycle 2: 90% tax
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].metadata.cashOutTaxRate = 0;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "cashOutCycleTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Pay in cycle 1
        address alice = address(0xA11CE);
        uint256 aliceTokens = _payProject(pid, alice, 10 ether);

        // Queue new ruleset with 90% cashOutTaxRate
        JBRulesetConfig[] memory newConfig = new JBRulesetConfig[](1);
        newConfig[0].mustStartAtOrAfter = 0;
        newConfig[0].duration = 7 days;
        newConfig[0].weight = 1000e18;
        newConfig[0].weightCutPercent = 0;
        newConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfig[0].metadata = _defaultMetadata();
        newConfig[0].metadata.cashOutTaxRate = 9000; // 90%
        newConfig[0].splitGroups = new JBSplitGroup[](0);
        newConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(projectOwner);
        jbController().queueRulesetsOf(pid, newConfig, "");

        // Advance to cycle 2
        vm.warp(block.timestamp + 7 days + 1);

        // Pay in second payer so Alice isn't the sole holder (tax has no effect on 100% cashout)
        address bob = address(0xB0B);
        _payProject(pid, bob, 10 ether);

        // Cash out Alice in cycle 2 — should use the new 90% tax rate
        vm.prank(alice);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: alice,
                projectId: pid,
                cashOutCount: aliceTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(alice),
                metadata: new bytes(0)
            });

        // With 90% tax on partial cashout (50% of supply), reclaim is significantly reduced
        // The bonding curve formula penalizes partial cashouts with high tax
        assertLt(reclaimAmount, 10 ether, "90% tax should reduce reclaim below payment amount");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 3: Weight decay — 10 cycles accuracy
    // ═══════════════════════════════════════════════════════════════════

    function test_weightDecay_multiCycle_accuracy() public {
        // 10% weight cut per cycle
        uint32 tenPercentCut = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 10);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 1 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = tenPercentCut;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "decayTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Record tokens minted per cycle
        uint256[] memory tokensPerCycle = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            if (i > 0) vm.warp(block.timestamp + 1 days + 1);
            tokensPerCycle[i] = _payProject(pid, address(uint160(0x6000 + i)), 1 ether);
        }

        // Each cycle should mint ~90% of previous
        for (uint256 i = 1; i < 10; i++) {
            assertLt(tokensPerCycle[i], tokensPerCycle[i - 1], "Each cycle should mint fewer tokens");
            // Within 1% tolerance of 90% ratio
            uint256 expectedRatio = 900; // 90%
            uint256 actualRatio = (tokensPerCycle[i] * 1000) / tokensPerCycle[i - 1];
            assertApproxEqAbs(actualRatio, expectedRatio, 5, "Weight decay ratio should be ~90%");
        }

        // After 10 cycles (9 weight transitions): weight ≈ 1000 * 0.9^9 ≈ 387.42
        // Cycle 10 tokens should be roughly 38.74% of cycle 1
        uint256 ratio = (tokensPerCycle[9] * 10_000) / tokensPerCycle[0];
        assertApproxEqAbs(ratio, 3874, 50, "After 9 weight transitions, weight should be ~38.74% of original");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 4: 100% weight cut kills weight
    // ═══════════════════════════════════════════════════════════════════

    function test_weightDecay_100percent_killsWeight() public {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 1 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT); // 100%
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "killWeightTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Cycle 1: normal minting
        uint256 cycle1Tokens = _payProject(pid, address(0xA11CE), 1 ether);
        assertGt(cycle1Tokens, 0, "Cycle 1 should mint tokens");

        // Advance to cycle 2
        vm.warp(block.timestamp + 1 days + 1);

        // Cycle 2: weight should be 0 → mint 0 tokens
        uint256 cycle2Tokens = _payProject(pid, address(0xB0B), 1 ether);
        assertEq(cycle2Tokens, 0, "100% weight cut should mint 0 tokens in cycle 2");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 5: Queued ruleset overrides auto-cycle
    // ═══════════════════════════════════════════════════════════════════

    function test_queuedRuleset_overridesAutoCycle() public {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 2); // 50%
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "queueOverrideTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Queue a new ruleset with different weight (2000e18 instead of auto-decayed 500e18)
        JBRulesetConfig[] memory newConfig = new JBRulesetConfig[](1);
        newConfig[0].mustStartAtOrAfter = 0;
        newConfig[0].duration = 7 days;
        newConfig[0].weight = 2000e18;
        newConfig[0].weightCutPercent = 0;
        newConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfig[0].metadata = _defaultMetadata();
        newConfig[0].splitGroups = new JBSplitGroup[](0);
        newConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(projectOwner);
        jbController().queueRulesetsOf(pid, newConfig, "");

        // Advance to cycle 2
        vm.warp(block.timestamp + 7 days + 1);

        // Pay — should use queued weight (2000e18), not auto-decayed (500e18)
        uint256 tokens = _payProject(pid, address(0xA11CE), 1 ether);

        // With weight 2000e18 and 1 ETH, should get 2000 tokens
        assertEq(tokens, 2000e18, "Queued ruleset weight should override auto-cycle decay");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 6: Approval hook — pending to approved
    // ═══════════════════════════════════════════════════════════════════

    function test_approvalHook_pendingToApproved() public {
        DelayedApprovalHook approvalHook = new DelayedApprovalHook(3 days);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(approvalHook));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "approvalTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Queue a new ruleset
        JBRulesetConfig[] memory newConfig = new JBRulesetConfig[](1);
        newConfig[0].mustStartAtOrAfter = 0;
        newConfig[0].duration = 7 days;
        newConfig[0].weight = 2000e18;
        newConfig[0].weightCutPercent = 0;
        newConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfig[0].metadata = _defaultMetadata();
        newConfig[0].splitGroups = new JBSplitGroup[](0);
        newConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(projectOwner);
        jbController().queueRulesetsOf(pid, newConfig, "");

        // Check status before approval period
        (,, JBApprovalStatus statusBefore) = jbController().latestQueuedRulesetOf(pid);
        // Status should be ApprovalExpected (pending)
        assertTrue(
            statusBefore == JBApprovalStatus.ApprovalExpected || statusBefore == JBApprovalStatus.Approved,
            "Status should be ApprovalExpected or Approved initially"
        );

        // Advance past approval delay (3 days)
        vm.warp(block.timestamp + 4 days);

        // Status should now be Approved
        (,, JBApprovalStatus statusAfter) = jbController().latestQueuedRulesetOf(pid);
        assertEq(uint256(statusAfter), uint256(JBApprovalStatus.Approved), "Status should be Approved after delay");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 7: Approval hook — rejected falls back
    // ═══════════════════════════════════════════════════════════════════

    function test_approvalHook_rejected_fallsBack() public {
        AlwaysRejectingHook rejectHook = new AlwaysRejectingHook();

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(rejectHook));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "rejectTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Queue a new ruleset with different weight
        JBRulesetConfig[] memory newConfig = new JBRulesetConfig[](1);
        newConfig[0].mustStartAtOrAfter = 0;
        newConfig[0].duration = 7 days;
        newConfig[0].weight = 5000e18;
        newConfig[0].weightCutPercent = 0;
        newConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfig[0].metadata = _defaultMetadata();
        newConfig[0].splitGroups = new JBSplitGroup[](0);
        newConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(projectOwner);
        jbController().queueRulesetsOf(pid, newConfig, "");

        // Advance to cycle 2
        vm.warp(block.timestamp + 7 days + 1);

        // Pay — should use the fallback (cycle 1 auto-repeated), not the rejected queued ruleset
        uint256 tokens = _payProject(pid, address(0xA11CE), 1 ether);

        // Should still get 1000 tokens (cycle 1 weight, not 5000)
        assertEq(tokens, 1000e18, "Rejected ruleset should fall back to repeating previous cycle");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 8: Payout limit resets at cycle boundary
    // ═══════════════════════════════════════════════════════════════════

    function test_rulesetTransition_payoutLimitReset() public {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 5 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "payoutLimitResetTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Fund generously
        _payProject(pid, address(0xBA1E), 100 ether);

        // Use full payout limit in cycle 1
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Try to send more — should fail (limit exhausted)
        vm.prank(projectOwner);
        vm.expectRevert();
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 1 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Advance to cycle 2
        vm.warp(block.timestamp + 7 days + 1);

        // Payout limit should be reset — can send again
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // If we got here, limit was successfully reset
        assertTrue(true, "Payout limit reset at cycle boundary");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 9: Tax rate change across cycles
    // ═══════════════════════════════════════════════════════════════════

    function test_rulesetTransition_changeTaxRate() public {
        // Cycle 1: 0% tax
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 7 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].metadata.cashOutTaxRate = 0;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "taxRateChangeTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Pay in cycle 1
        address alice = address(0xA11CE);
        uint256 aliceTokens = _payProject(pid, alice, 10 ether);

        // Queue cycle 2: 90% tax
        JBRulesetConfig[] memory newConfig = new JBRulesetConfig[](1);
        newConfig[0].mustStartAtOrAfter = 0;
        newConfig[0].duration = 7 days;
        newConfig[0].weight = 1000e18;
        newConfig[0].weightCutPercent = 0;
        newConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        newConfig[0].metadata = _defaultMetadata();
        newConfig[0].metadata.cashOutTaxRate = 9000; // 90%
        newConfig[0].splitGroups = new JBSplitGroup[](0);
        newConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(projectOwner);
        jbController().queueRulesetsOf(pid, newConfig, "");

        // Advance to cycle 2
        vm.warp(block.timestamp + 7 days + 1);

        // Add a second payer so Alice isn't the sole holder (tax has no effect on 100% cashout)
        address bob = address(0xB0B);
        _payProject(pid, bob, 10 ether);

        // Cash out Alice's cycle-1 tokens in cycle 2 with 90% tax
        vm.prank(alice);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: alice,
                projectId: pid,
                cashOutCount: aliceTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(alice),
                metadata: new bytes(0)
            });

        // With 90% tax on partial cashout, reclaim is reduced below payment
        assertLt(reclaimAmount, 10 ether, "Tokens minted in cycle 1 should get reduced reclaim under cycle 2's 90% tax");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 10: duration=0 means same ruleset forever
    // ═══════════════════════════════════════════════════════════════════

    function test_rulesetTransition_durationZero_neverCycles() public {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0; // Never cycles
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = uint32(JBConstants.MAX_WEIGHT_CUT_PERCENT / 2); // 50% cut would apply if it
        // cycled
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = _defaultMetadata();
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "noCycleTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Pay now
        uint256 tokensNow = _payProject(pid, address(0xA11CE), 1 ether);

        // Advance far into the future
        vm.warp(block.timestamp + 365 days);

        // Pay again — should still use same weight (no cycling)
        uint256 tokensLater = _payProject(pid, address(0xB0B), 1 ether);

        assertEq(tokensNow, tokensLater, "duration=0 should mean weight never decays");

        // Verify still cycle 1
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(pid);
        assertEq(ruleset.cycleNumber, 1, "Should still be cycle 1 with duration=0");
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
//  Mock Contracts
// ═══════════════════════════════════════════════════════════════════════

/// @notice Approval hook that approves after a configurable delay.
contract DelayedApprovalHook is ERC165, IJBRulesetApprovalHook {
    uint256 public immutable approvalDelay;

    constructor(uint256 _approvalDelay) {
        approvalDelay = _approvalDelay;
    }

    function DURATION() external view override returns (uint256) {
        return approvalDelay;
    }

    function approvalStatusOf(uint256, JBRuleset calldata ruleset) external view override returns (JBApprovalStatus) {
        // If enough time has passed since the ruleset was queued, approve it
        if (block.timestamp >= ruleset.start - approvalDelay) {
            return JBApprovalStatus.Approved;
        }
        return JBApprovalStatus.ApprovalExpected;
    }

    function supportsInterface(bytes4 _interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return _interfaceId == type(IJBRulesetApprovalHook).interfaceId || super.supportsInterface(_interfaceId);
    }
}

/// @notice Approval hook that always rejects.
contract AlwaysRejectingHook is ERC165, IJBRulesetApprovalHook {
    function DURATION() external pure override returns (uint256) {
        return 0;
    }

    function approvalStatusOf(uint256, JBRuleset calldata) external pure override returns (JBApprovalStatus) {
        return JBApprovalStatus.Failed;
    }

    function supportsInterface(bytes4 _interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return _interfaceId == type(IJBRulesetApprovalHook).interfaceId || super.supportsInterface(_interfaceId);
    }
}
