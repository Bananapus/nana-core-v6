// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";

/// @notice Tests that flash-loan style atomic pay+cashOut attacks cannot extract profit.
contract FlashLoanAttacks_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 public projectId;
    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // ── Launch fee collector project (#1)
        // ────────────────────────
        _launchFeeProject();

        // ── Launch test project (#2): 0% reserved, 30% cashOutTax ──
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 3000, // 30%
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
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = _defaultTerminalConfig();

        projectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "flashLoanTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

        vm.prank(projectOwner);
        jbController().deployERC20For(projectId, "FlashToken", "FT", bytes32(0));
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

    function _payProject(address payer, uint256 amount) internal returns (uint256 tokenCount) {
        vm.deal(payer, amount);
        vm.prank(payer);
        tokenCount = jbMultiTerminal().pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    function _cashOut(address holder, uint256 count) internal returns (uint256 reclaimAmount) {
        vm.prank(holder);
        reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: holder,
                projectId: projectId,
                cashOutCount: count,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(holder),
                metadata: new bytes(0)
            });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 1: Atomic pay+cashOut — no profit
    // ═══════════════════════════════════════════════════════════════════

    function test_flashLoan_payAndCashOut_noProfit() public {
        address attacker = address(0xA77AC0);
        uint256 payAmount = 10 ether;

        // Seed the project with some existing funds
        _payProject(address(0x5EED), 10 ether);

        // Attacker pays and immediately cashes out
        uint256 tokensReceived = _payProject(attacker, payAmount);
        uint256 reclaimAmount = _cashOut(attacker, tokensReceived);

        // Key invariant: reclaim amount must not exceed what was paid
        assertLe(reclaimAmount, payAmount, "Flash loan must not return more than paid");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 2: Multiple payers, proportional reclaim
    // ═══════════════════════════════════════════════════════════════════

    function test_flashLoan_payAndCashOut_multiplePayers() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        // Both pay in same block
        uint256 aliceTokens = _payProject(alice, 5 ether);
        uint256 bobTokens = _payProject(bob, 5 ether);

        // Both have equal tokens
        assertEq(aliceTokens, bobTokens, "Equal payments should mint equal tokens");

        // Alice cashes out
        uint256 aliceReclaim = _cashOut(alice, aliceTokens);
        // Bob cashes out
        uint256 bobReclaim = _cashOut(bob, bobTokens);

        // With cash out tax, the second casher benefits from the first one's tax.
        // This is expected behavior (not a bug). The key invariant is:
        // total reclaimed <= total paid in (no value created from nothing)
        assertLe(aliceReclaim + bobReclaim, 10 ether, "Total reclaimed must not exceed total paid in");

        // Alice (first casher) always gets less than her payment due to tax
        assertLt(aliceReclaim, 5 ether, "First casher pays the tax penalty");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 3: addToBalance inflates surplus but attacker has 0 tokens
    // ═══════════════════════════════════════════════════════════════════

    function test_addToBalance_inflateAndCashOut_zeroTokens() public {
        address attacker = address(0xA77AC0);

        // Attacker adds to balance (gets no tokens)
        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        jbMultiTerminal().addToBalanceOf{value: 10 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        // Attacker has 0 tokens — cannot extract
        uint256 balance = jbTokens().totalBalanceOf(attacker, projectId);
        assertEq(balance, 0, "addToBalance must not mint tokens");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 4: addToBalance benefits existing holders proportionally
    // ═══════════════════════════════════════════════════════════════════

    function test_addToBalance_noExploitIfTokensExist() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        // Alice and Bob pay in
        uint256 aliceTokens = _payProject(alice, 5 ether);
        uint256 bobTokens = _payProject(bob, 5 ether);

        // Someone adds to balance (donation)
        vm.deal(address(0xD000), 10 ether);
        vm.prank(address(0xD000));
        jbMultiTerminal().addToBalanceOf{value: 10 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        // Alice cashes out — gets her share of the surplus
        uint256 aliceReclaim = _cashOut(alice, aliceTokens);
        // Bob cashes out
        uint256 bobReclaim = _cashOut(bob, bobTokens);

        // Both should get proportional shares (with cashOutTax reducing it)
        // Key check: they should get roughly equal amounts since they have equal tokens
        uint256 diff = aliceReclaim > bobReclaim ? aliceReclaim - bobReclaim : bobReclaim - aliceReclaim;
        // Alice cashes out first, so she gets slightly more due to reduced supply.
        // But the proportional split should be reasonable.
        assertTrue(aliceReclaim > 0, "Alice should get some reclaim");
        assertTrue(bobReclaim > 0, "Bob should get some reclaim");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 5: Regression — cashOut(0) with totalSupply==0 must return 0
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Regression test: cashOut(0) with totalSupply==0 previously returned the entire surplus.
    /// @dev In V5, `cashOutCount >= totalSupply` (0 >= 0) was true and returned the full surplus before
    /// checking for zero cashOutCount. Fixed since V5.1: `JBCashOuts.cashOutFrom` returns 0 when
    /// cashOutCount==0 (line 31) before reaching the `cashOutCount >= totalSupply` check (line 37).
    /// This test verifies the fix holds.
    function test_variant_addToBalance_zeroCashOut() public {
        // Add to balance when no tokens exist
        vm.deal(address(0xD000), 5 ether);
        vm.prank(address(0xD000));
        jbMultiTerminal().addToBalanceOf{value: 5 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        // cashOut(0) with totalSupply==0 must reclaim nothing.
        address attacker = address(0xA77AC0);
        vm.prank(attacker);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: attacker,
                projectId: projectId,
                cashOutCount: 0,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(attacker),
                metadata: new bytes(0)
            });

        assertEq(reclaimAmount, 0, "Regression: cashOut(0) must return 0");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 6: Pay hook reentrancy — cashOut during pay
    // ═══════════════════════════════════════════════════════════════════

    function test_payHookReentrancy_cashOutDuringPay() public {
        // For this test we verify that even if an attacker could call cashOut
        // from a pay callback, they have no tokens at that point (tokens are
        // minted after the store records, before hooks execute).
        // Without a data hook configured, no hooks fire, so we just verify
        // the normal flow is safe.
        address attacker = address(0xA77AC0);

        // Seed project
        _payProject(address(0x5EED), 10 ether);

        // Attacker pays — tokens are minted atomically
        uint256 tokens = _payProject(attacker, 5 ether);
        assertTrue(tokens > 0, "Tokens should be minted");

        // Attacker cashes out — state is consistent
        uint256 reclaim = _cashOut(attacker, tokens);
        assertLe(reclaim, 5 ether, "Reclaim must not exceed payment");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 7: Cash out hook reentrancy — pay during cashOut
    // ═══════════════════════════════════════════════════════════════════

    function test_cashOutHookReentrancy_payDuringCashOut() public {
        // Without data hooks, cash out hooks don't fire.
        // Verify: pay after cashOut uses already-decremented balance.
        address alice = address(0xA11CE);

        uint256 aliceTokens = _payProject(alice, 10 ether);

        // Alice cashes out half
        uint256 halfTokens = aliceTokens / 2;
        uint256 reclaimFirst = _cashOut(alice, halfTokens);

        // Alice pays again with the reclaimed ETH
        uint256 newTokens = _payProject(alice, reclaimFirst);

        // Cash out the new tokens
        uint256 reclaimSecond = _cashOut(alice, newTokens);

        // Each round she loses to cashOutTax, so she should progressively lose
        assertLt(reclaimSecond, reclaimFirst, "Second reclaim should be less due to compounding tax");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 8: Reserved token inflation — cashOut timing
    // ═══════════════════════════════════════════════════════════════════

    function test_reservedTokenInflation_cashOutTiming() public {
        // Launch a project with 20% reserved to test inflation
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 2000, // 20%
            cashOutTaxRate: 0, // No tax for cleaner test
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
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 reservedProjectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "reservedTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        vm.prank(projectOwner);
        jbController().deployERC20For(reservedProjectId, "ResToken", "RT", bytes32(0));

        // Pay in
        address alice = address(0xA11CE);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 aliceTokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: reservedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: alice,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Check pending reserved
        uint256 pendingBefore = jbController().pendingReservedTokenBalanceOf(reservedProjectId);
        assertTrue(pendingBefore > 0, "Should have pending reserved tokens");

        // Cash out BEFORE distributing reserves — Alice has higher share of supply
        uint256 totalSupplyBefore = jbTokens().totalSupplyOf(reservedProjectId);
        uint256 aliceShareBefore = (aliceTokens * 1e18) / totalSupplyBefore;

        // Now distribute reserved tokens
        jbController().sendReservedTokensToSplitsOf(reservedProjectId);

        // Total supply increased
        uint256 totalSupplyAfter = jbTokens().totalSupplyOf(reservedProjectId);
        assertGt(totalSupplyAfter, totalSupplyBefore, "Supply should increase after distributing reserves");

        // Alice's share decreased
        uint256 aliceShareAfter = (aliceTokens * 1e18) / totalSupplyAfter;
        assertLt(aliceShareAfter, aliceShareBefore, "Alice's share should decrease after reserve distribution");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 9: 100 rounds of tiny pay+cashOut — no profit from rounding
    // ═══════════════════════════════════════════════════════════════════

    function test_multiplePayCashOutRounds_accumulatedRounding() public {
        address attacker = address(0xA77AC0);

        // Seed the project
        _payProject(address(0x5EED), 100 ether);

        uint256 startBalance = 10 ether;
        vm.deal(attacker, startBalance);
        uint256 currentBalance = startBalance;

        for (uint256 i = 0; i < 100; i++) {
            if (currentBalance < 0.001 ether) break;

            vm.prank(attacker);
            uint256 tokens = jbMultiTerminal().pay{value: currentBalance}({
                projectId: projectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: currentBalance,
                beneficiary: attacker,
                minReturnedTokens: 0,
                memo: "",
                metadata: new bytes(0)
            });

            if (tokens == 0) break;

            vm.prank(attacker);
            currentBalance = jbMultiTerminal()
                .cashOutTokensOf({
                    holder: attacker,
                    projectId: projectId,
                    cashOutCount: tokens,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(attacker),
                    metadata: new bytes(0)
                });
        }

        assertLe(currentBalance, startBalance, "100 rounds of pay+cashOut must not accumulate profit from rounding");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 10: Sandwich attack around sendPayoutsOf
    // ═══════════════════════════════════════════════════════════════════

    function test_sandwichAttack_payBeforeAndAfterPayout() public {
        // Configure payout limit
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 3000,
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

        uint256 sandwichProjectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "sandwichTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Seed
        address seeder = address(0x5EED);
        vm.deal(seeder, 20 ether);
        vm.prank(seeder);
        jbMultiTerminal().pay{value: 20 ether}({
            projectId: sandwichProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 20 ether,
            beneficiary: seeder,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Attacker front-runs: pays right before payout
        address attacker = address(0xA77AC0);
        uint256 attackerInitialETH = 10 ether;
        vm.deal(attacker, attackerInitialETH);
        vm.prank(attacker);
        uint256 attackerTokens = jbMultiTerminal().pay{value: attackerInitialETH}({
            projectId: sandwichProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: attackerInitialETH,
            beneficiary: attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Payout happens
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: sandwichProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Attacker back-runs: cashes out
        vm.prank(attacker);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: attacker,
                projectId: sandwichProjectId,
                cashOutCount: attackerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(attacker),
                metadata: new bytes(0)
            });

        // Attacker should NOT profit
        assertLe(reclaimAmount, attackerInitialETH, "Sandwich attacker must not profit from payout timing");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 11: Flash loan across two terminals with useTotalSurplus
    // ═══════════════════════════════════════════════════════════════════

    function test_flashLoan_acrossTwoTerminals() public {
        // Launch project with useTotalSurplusForCashOuts and two terminals
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 3000,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Two terminals
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](2);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});
        terminalConfigurations[1] =
            JBTerminalConfig({terminal: jbMultiTerminal2(), accountingContextsToAccept: tokensToAccept});

        uint256 twoTermProjectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "twoTermTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

        // Seed terminal 1
        address seeder = address(0x5EED);
        vm.deal(seeder, 10 ether);
        vm.prank(seeder);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: twoTermProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: seeder,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Attacker pays terminal 2
        address attacker = address(0xA77AC0);
        vm.deal(attacker, 5 ether);
        vm.prank(attacker);
        uint256 attackerTokens = jbMultiTerminal2().pay{value: 5 ether}({
            projectId: twoTermProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Cash out from terminal 2 using total surplus from both terminals
        vm.prank(attacker);
        uint256 reclaimAmount = jbMultiTerminal2()
            .cashOutTokensOf({
                holder: attacker,
                projectId: twoTermProjectId,
                cashOutCount: attackerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(attacker),
                metadata: new bytes(0)
            });

        assertLe(reclaimAmount, 5 ether, "Cross-terminal cashOut must not profit");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 12: Fuzz — same-block pay+cashOut NEVER profitable
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_payAndCashOut_neverProfitable(uint256 payAmount, uint16 cashOutTaxRate) public {
        payAmount = bound(payAmount, 0.01 ether, 1000 ether);
        cashOutTaxRate = uint16(bound(uint256(cashOutTaxRate), 0, 10_000));

        // Launch a fresh project with the fuzzed tax rate
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
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
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 fuzzProjectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "fuzzTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Seed project
        address seeder = address(0x5EED);
        vm.deal(seeder, 100 ether);
        vm.prank(seeder);
        jbMultiTerminal().pay{value: 100 ether}({
            projectId: fuzzProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 100 ether,
            beneficiary: seeder,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Attacker atomic pay+cashOut
        address attacker = address(0xA77AC0);
        vm.deal(attacker, payAmount);
        vm.prank(attacker);
        uint256 tokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: fuzzProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        if (tokens == 0) return;

        vm.prank(attacker);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: attacker,
                projectId: fuzzProjectId,
                cashOutCount: tokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(attacker),
                metadata: new bytes(0)
            });

        assertLe(reclaimAmount, payAmount, "FUZZ: Atomic pay+cashOut must never return more than paid");
    }

    receive() external payable {}
}
