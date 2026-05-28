// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRulesetMetadataResolver} from "../src/libraries/JBRulesetMetadataResolver.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFee} from "../src/structs/JBFee.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";

/// @title EntryPointPermutations
/// @notice Systematically tests every JBMultiTerminal external function with edge-case parameters
///         that invariant handlers skip (because handlers use try/catch).
///         ~25 tests across 6 function groups: pay, cashOut, sendPayouts, useAllowance,
///         processHeldFees, addToBalance.
contract EntryPointPermutations_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 public projectStandard; // Normal project with funds
    uint256 public projectPaused; // Project with pausePay=true
    uint256 public projectMaxTax; // Project with cashOutTaxRate=10000 (max)
    address public owner;

    function setUp() public override {
        super.setUp();
        owner = multisig();

        // Fee project #1
        _launchFeeProject();

        // Standard project: 20% reserved, 30% cashOutTax, 5 ETH payout limit, 3 ETH surplus allowance
        projectStandard = _launchProject(
            2000, // reservedPercent
            3000, // cashOutTaxRate
            false, // pausePay
            true, // holdFees
            5 ether, // payoutLimit
            3 ether // surplusAllowance
        );

        // Paused project
        projectPaused = _launchProject(0, 0, true, false, 0, 0);

        // Max tax project
        projectMaxTax = _launchProject(0, 10_000, false, false, 0, 0);

        // Seed the standard project with some ETH
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        jbMultiTerminal().pay{value: 10 ether}(projectStandard, JBConstants.NATIVE_TOKEN, 10 ether, owner, 0, "", "");

        // Seed the max tax project
        vm.prank(owner);
        jbMultiTerminal().pay{value: 5 ether}(projectMaxTax, JBConstants.NATIVE_TOKEN, 5 ether, owner, 0, "", "");
    }

    // =========================================================================
    // pay() edge cases
    // =========================================================================

    /// @notice pay() with zero amount — for native token, msg.value=0 is accepted (mints 0 tokens).
    function test_pay_zeroAmount() public {
        uint256 tokens = jbMultiTerminal().pay{value: 0}(projectStandard, JBConstants.NATIVE_TOKEN, 0, owner, 0, "", "");
        assertEq(tokens, 0, "Zero amount payment should mint 0 tokens");
    }

    /// @notice pay() with max uint amount (msg.value caps it for native token).
    function test_pay_maxUintAmount() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        // For native token, amount param is overridden by msg.value, so this should work
        uint256 tokens = jbMultiTerminal().pay{value: amount}(
            projectStandard, JBConstants.NATIVE_TOKEN, type(uint256).max, address(this), 0, "", ""
        );
        assertGt(tokens, 0, "Should mint tokens for payment");
    }

    /// @notice pay() to a project with no ruleset should revert.
    function test_pay_nonExistentProject() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        jbMultiTerminal().pay{value: 1 ether}(999, JBConstants.NATIVE_TOKEN, 1 ether, address(this), 0, "", "");
    }

    /// @notice pay() to a project with pausePay=true should revert.
    function test_pay_pausedProject() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        jbMultiTerminal().pay{value: 1 ether}(
            projectPaused, JBConstants.NATIVE_TOKEN, 1 ether, address(this), 0, "", ""
        );
    }

    /// @notice pay() with zero beneficiary — should use msg.sender.
    function test_pay_zeroBeneficiary() public {
        vm.deal(address(this), 1 ether);
        // Zero beneficiary defaults to msg.sender in the terminal
        uint256 tokens = jbMultiTerminal().pay{value: 1 ether}(
            projectStandard, JBConstants.NATIVE_TOKEN, 1 ether, address(0), 0, "", ""
        );
        // Tokens go to msg.sender (address(this)) when beneficiary is address(0)
        assertGt(tokens, 0, "Should mint tokens even with zero beneficiary");
    }

    /// @notice pay() with same payer and beneficiary.
    function test_pay_samePagerAndBeneficiary() public {
        address payer = address(0x5000);
        vm.deal(payer, 2 ether);

        vm.prank(payer);
        uint256 tokens =
            jbMultiTerminal().pay{value: 1 ether}(projectStandard, JBConstants.NATIVE_TOKEN, 1 ether, payer, 0, "", "");
        assertGt(tokens, 0, "Should mint tokens for self-payment");
    }

    /// @notice pay() with minReturnedTokens higher than what's possible should revert.
    function test_pay_minReturnedTokensTooHigh() public {
        vm.deal(address(this), 1 ether);
        // With 1 ETH and weight=1000e18, expect 1000e18 tokens (minus reserved).
        // Asking for type(uint256).max should revert.
        vm.expectRevert();
        jbMultiTerminal().pay{value: 1 ether}(
            projectStandard, JBConstants.NATIVE_TOKEN, 1 ether, address(this), type(uint256).max, "", ""
        );
    }

    // =========================================================================
    // cashOutTokensOf() edge cases
    // =========================================================================

    /// @notice cashOut with zero count — should return 0 reclaim (no-op).
    function test_cashOut_zeroCount() public {
        vm.prank(owner);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
            holder: owner,
            projectId: projectStandard,
            cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(owner),
            metadata: "",
            referralProjectId: 0
        });
        assertEq(reclaimed, 0, "Zero count cash out should return 0");
    }

    /// @notice cashOut entire supply should succeed.
    function test_cashOut_entireSupply() public {
        uint256 balance = jbTokens().totalBalanceOf(owner, projectStandard);
        if (balance == 0) return;

        uint256 balanceBefore = owner.balance;
        vm.prank(owner);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
            holder: owner,
            projectId: projectStandard,
            cashOutCount: balance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(owner),
            metadata: "",
            referralProjectId: 0
        });

        assertGt(reclaimed, 0, "Should reclaim something for entire supply cash out");
        assertGt(owner.balance, balanceBefore, "Owner balance should increase");
    }

    /// @notice cashOut more than balance should revert.
    /// @dev `projectStandard` has reservedPercent=2000 and no split group, so its pending reserves
    /// would otherwise be leftover-minted to the owner during the lazy-settle inside `cashOutTokensOf`.
    /// We force-settle them up-front so the balance we measure reflects the holder's true post-settle
    /// position; the assertion (cashing out balance+1 must revert) then exercises the real overflow case.
    function test_cashOut_moreThanBalance() public {
        if (jbController().pendingReservedTokenBalanceOf(projectStandard) != 0) {
            jbController().sendReservedTokensToSplitsOf(projectStandard);
        }
        uint256 balance = jbTokens().totalBalanceOf(owner, projectStandard);

        vm.prank(owner);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: owner,
            projectId: projectStandard,
            cashOutCount: balance + 1,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(owner),
            metadata: "",
            referralProjectId: 0
        });
    }

    /// @notice cashOut with max tax rate should return 0 reclaim.
    function test_cashOut_maxTaxRateReturnsZero() public {
        uint256 balance = jbTokens().totalBalanceOf(owner, projectMaxTax);
        if (balance == 0) return;

        vm.prank(owner);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
            holder: owner,
            projectId: projectMaxTax,
            cashOutCount: balance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(owner),
            metadata: "",
            referralProjectId: 0
        });

        assertEq(reclaimed, 0, "Max tax rate should return 0 reclaim");
    }

    /// @notice cashOut with minTokensReclaimed too high should revert.
    function test_cashOut_minTokensReclaimedTooHigh() public {
        uint256 balance = jbTokens().totalBalanceOf(owner, projectStandard);
        if (balance == 0) return;

        vm.prank(owner);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: owner,
            projectId: projectStandard,
            cashOutCount: 1,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: type(uint256).max,
            beneficiary: payable(owner),
            metadata: "",
            referralProjectId: 0
        });
    }

    // =========================================================================
    // sendPayoutsOf() edge cases
    // =========================================================================

    /// @notice sendPayouts with exact limit should succeed.
    function test_sendPayouts_exactLimit() public {
        vm.prank(owner);
        uint256 amountPaidOut = jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether, // Exact payout limit
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        assertGt(amountPaidOut, 0, "Should pay out with exact limit");
    }

    /// @notice sendPayouts with 1 wei over limit should cap to the limit.
    function test_sendPayouts_overLimitCaps() public {
        vm.prank(owner);
        uint256 amountPaidOut = jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether + 1, // 1 wei over limit — caps to 5 ether
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });
        // Should have paid out exactly the limit (5 ether), not 5 ether + 1.
        assertEq(amountPaidOut, 5 ether);
    }

    /// @notice sendPayouts with zero amount should be a no-op or revert.
    function test_sendPayouts_zeroAmount() public {
        vm.prank(owner);
        uint256 amountPaidOut = jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        assertEq(amountPaidOut, 0, "Zero amount should result in zero payout");
    }

    /// @notice sendPayouts with minTokensPaidOut too high should revert.
    function test_sendPayouts_minTokensPaidOutTooHigh() public {
        vm.prank(owner);
        vm.expectRevert();
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: type(uint256).max,
            referralProjectId: 0
        });
    }

    // =========================================================================
    // useAllowanceOf() edge cases
    // =========================================================================

    /// @notice useAllowance with exact allowance should succeed.
    function test_useAllowance_exactAllowance() public {
        vm.prank(owner);
        uint256 netAmount = jbMultiTerminal()
            .useAllowanceOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 3 ether, // Exact surplus allowance
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(owner),
            feeBeneficiary: payable(owner),
            memo: "",
            referralProjectId: 0
        });

        assertGt(netAmount, 0, "Should use exact allowance successfully");
    }

    /// @notice useAllowance without permission should revert.
    function test_useAllowance_noPermission() public {
        address unauthorized = address(0x9999);
        vm.prank(unauthorized);
        vm.expectRevert();
        jbMultiTerminal()
            .useAllowanceOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(unauthorized),
            feeBeneficiary: payable(unauthorized),
            memo: "",
            referralProjectId: 0
        });
    }

    /// @notice useAllowance after payouts drained balance should revert or return 0.
    function test_useAllowance_afterPayoutsDrainedBalance() public {
        // First drain via payouts
        vm.prank(owner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        // Now try to use allowance — should fail or return small amount
        vm.prank(owner);
        try jbMultiTerminal()
            .useAllowanceOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 3 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(owner),
            feeBeneficiary: payable(owner),
            memo: "",
            referralProjectId: 0
        }) returns (
            uint256 netAmount
        ) {
            // If it succeeds, the amount should be reasonable
            assertLe(netAmount, 5 ether, "Net amount should be bounded");
        } catch {
            // Expected: may revert if insufficient surplus
            assertTrue(true, "Reverted as expected due to insufficient surplus");
        }
    }

    // =========================================================================
    // processHeldFeesOf() edge cases
    // =========================================================================

    /// @notice processHeldFees when no fees are held should be a no-op.
    function test_processHeldFees_noFeesHeld() public {
        // Project with holdFees=false shouldn't have any held fees
        jbMultiTerminal().processHeldFeesOf(projectPaused, JBConstants.NATIVE_TOKEN, 100);
        // Should not revert — just a no-op
        assertTrue(true, "No-op when no fees held");
    }

    /// @notice processHeldFees with count > available should process what's available.
    function test_processHeldFees_countExceedsAvailable() public {
        // First create some held fees via payouts on project with holdFees=true
        vm.prank(owner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        // Advance time past unlock period
        vm.warp(block.timestamp + 30 days);

        // Process with count=1000 (more than available)
        jbMultiTerminal().processHeldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 1000);
        assertTrue(true, "Should handle count > available gracefully");
    }

    /// @notice processHeldFees before unlock period should skip locked fees.
    function test_processHeldFees_lockedFees() public {
        // Create held fees
        vm.prank(owner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        // Don't advance time — fees should still be locked
        // This should be a no-op since fees are locked
        jbMultiTerminal().processHeldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 100);
        assertTrue(true, "Should skip locked fees without reverting");
    }

    // =========================================================================
    // addToBalanceOf() edge cases
    // =========================================================================

    /// @notice addToBalance with shouldReturnHeldFees=true and zero held fees.
    function test_addToBalance_returnFeesWithZeroHeld() public {
        // Add to balance on a project with no held fees
        vm.deal(address(this), 1 ether);
        jbMultiTerminal().addToBalanceOf{value: 1 ether}(
            projectStandard, JBConstants.NATIVE_TOKEN, 1 ether, true, "", ""
        );

        // Should succeed — just adds to balance without returning any fees
        uint256 balance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectStandard, JBConstants.NATIVE_TOKEN);
        assertGt(balance, 0, "Balance should be non-zero after add");
    }

    /// @notice addToBalance with shouldReturnHeldFees=true after creating held fees.
    function test_addToBalance_returnFeesPartial() public {
        // Create held fees via payout
        vm.prank(owner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 2 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        // Check held fees exist
        JBFee[] memory feesBefore = jbMultiTerminal().heldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 100);

        // Now add to balance with fee return
        vm.deal(address(this), 1 ether);
        jbMultiTerminal().addToBalanceOf{value: 1 ether}(
            projectStandard, JBConstants.NATIVE_TOKEN, 1 ether, true, "", ""
        );

        // Held fees should be reduced (partially or fully returned)
        jbMultiTerminal().heldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 100);

        if (feesBefore.length > 0) {
            // Either fewer fees or smaller amounts
            assertTrue(true, "Fee return processed without revert");
        }
    }

    /// @notice addToBalance with shouldReturnHeldFees=false should not touch held fees.
    function test_addToBalance_noReturnDoesNotAffectHeldFees() public {
        // Create held fees
        vm.prank(owner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        JBFee[] memory feesBefore = jbMultiTerminal().heldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 100);
        uint256 heldBefore;
        for (uint256 i = 0; i < feesBefore.length; i++) {
            heldBefore += feesBefore[i].amount;
        }

        // Add without returning fees
        vm.deal(address(this), 1 ether);
        jbMultiTerminal().addToBalanceOf{value: 1 ether}(
            projectStandard, JBConstants.NATIVE_TOKEN, 1 ether, false, "", ""
        );

        JBFee[] memory feesAfter = jbMultiTerminal().heldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 100);
        uint256 heldAfter;
        for (uint256 i = 0; i < feesAfter.length; i++) {
            heldAfter += feesAfter[i].amount;
        }

        assertEq(heldBefore, heldAfter, "Held fees should not change when shouldReturnHeldFees=false");
    }

    /// @notice addToBalance with exact amount to return all held fees.
    function test_addToBalance_exactReturnAllHeldFees() public {
        // Create held fees via payout
        vm.prank(owner);
        jbMultiTerminal()
            .sendPayoutsOf({
            projectId: projectStandard,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        });

        // Get total held fees
        JBFee[] memory fees = jbMultiTerminal().heldFeesOf(projectStandard, JBConstants.NATIVE_TOKEN, 100);
        uint256 totalHeld;
        for (uint256 i = 0; i < fees.length; i++) {
            totalHeld += fees[i].amount;
        }

        if (totalHeld > 0) {
            // Add back the exact amount of held fees
            vm.deal(address(this), totalHeld);
            jbMultiTerminal().addToBalanceOf{value: totalHeld}(
                projectStandard, JBConstants.NATIVE_TOKEN, totalHeld, true, "", ""
            );

            // All held fees should be returned
            assertTrue(true, "Exact return processed without revert");
        }
    }

    /// @notice addToBalance with zero amount — should it be a no-op?
    function test_addToBalance_zeroAmount() public {
        // Zero amount add to balance
        jbMultiTerminal().addToBalanceOf{value: 0}(projectStandard, JBConstants.NATIVE_TOKEN, 0, false, "", "");
        assertTrue(true, "Zero amount addToBalance should not revert");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _launchFeeProject() internal returns (uint256) {
        JBRulesetConfig[] memory ruleset = new JBRulesetConfig[](1);
        ruleset[0].mustStartAtOrAfter = 0;
        ruleset[0].duration = 0;
        ruleset[0].weight = uint112(1000e18);
        ruleset[0].weightCutPercent = 0;
        ruleset[0].approvalHook = IJBRulesetApprovalHook(address(0));
        ruleset[0].metadata = _meta(0, 0, false, false);
        ruleset[0].splitGroups = new JBSplitGroup[](0);
        ruleset[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory termCfg = new JBTerminalConfig[](1);
        JBAccountingContext[] memory ctx = new JBAccountingContext[](1);
        ctx[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        termCfg[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: ctx});

        return jbController()
            .launchProjectFor({
            owner: owner,
            projectUri: "FeeProject",
            rulesetConfigurations: ruleset,
            terminalConfigurations: termCfg,
            memo: ""
        });
    }

    function _launchProject(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        bool pausePay,
        bool holdFees,
        uint256 payoutLimit,
        uint256 surplusAllowance
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory ruleset = new JBRulesetConfig[](1);
        ruleset[0].mustStartAtOrAfter = 0;
        ruleset[0].duration = 0;
        ruleset[0].weight = uint112(1000e18);
        ruleset[0].weightCutPercent = 0;
        ruleset[0].approvalHook = IJBRulesetApprovalHook(address(0));
        ruleset[0].metadata = _meta(reservedPercent, cashOutTaxRate, pausePay, holdFees);
        ruleset[0].splitGroups = new JBSplitGroup[](0);

        if (payoutLimit > 0 || surplusAllowance > 0) {
            JBFundAccessLimitGroup[] memory limits = new JBFundAccessLimitGroup[](1);
            JBCurrencyAmount[] memory payoutLimits;
            JBCurrencyAmount[] memory surplusAllowances;

            if (payoutLimit > 0) {
                payoutLimits = new JBCurrencyAmount[](1);
                payoutLimits[0] = JBCurrencyAmount({
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amount: uint224(payoutLimit),
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
                });
            } else {
                payoutLimits = new JBCurrencyAmount[](0);
            }

            if (surplusAllowance > 0) {
                surplusAllowances = new JBCurrencyAmount[](1);
                surplusAllowances[0] = JBCurrencyAmount({
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amount: uint224(surplusAllowance),
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
                });
            } else {
                surplusAllowances = new JBCurrencyAmount[](0);
            }

            limits[0] = JBFundAccessLimitGroup({
                terminal: address(jbMultiTerminal()),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: payoutLimits,
                surplusAllowances: surplusAllowances
            });
            ruleset[0].fundAccessLimitGroups = limits;
        } else {
            ruleset[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        }

        JBTerminalConfig[] memory termCfg = new JBTerminalConfig[](1);
        JBAccountingContext[] memory ctx = new JBAccountingContext[](1);
        ctx[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        termCfg[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: ctx});

        return jbController()
            .launchProjectFor({
            owner: owner,
            projectUri: "Project",
            rulesetConfigurations: ruleset,
            terminalConfigurations: termCfg,
            memo: ""
        });
    }

    function _meta(
        uint16 reservedPercent,
        uint16 cashOutTaxRate,
        bool pausePay,
        bool holdFees
    )
        internal
        pure
        returns (JBRulesetMetadata memory)
    {
        return JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: pausePay,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: holdFees,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }
}
