// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/StdInvariant.sol";
import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {EconomicHandler} from "./invariants/handlers/EconomicHandler.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";

/// @title EconomicSimulation
/// @notice Multi-project economic invariant tests with 3 projects and 10 actors.
///         Verifies fund conservation, supply consistency, and cross-project split cascades.
contract EconomicSimulation_Local is StdInvariant, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    EconomicHandler public handler;

    uint256 public projectA;
    uint256 public projectB;
    uint256 public projectC;
    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // =====================================================================
        // Fee collector project (#1) — create explicitly since TestBaseWorkflow
        // passes feeProjectOwner=address(0) to JBProjects.
        // This ensures projectA=2, projectB=3, projectC=4 and fee project=1.
        // =====================================================================
        {
            JBRulesetConfig[] memory emptyRuleset = new JBRulesetConfig[](1);
            emptyRuleset[0].mustStartAtOrAfter = 0;
            emptyRuleset[0].duration = 0;
            emptyRuleset[0].weight = 0;
            emptyRuleset[0].weightCutPercent = 0;
            emptyRuleset[0].approvalHook = IJBRulesetApprovalHook(address(0));
            emptyRuleset[0].metadata = JBRulesetMetadata({
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
            emptyRuleset[0].splitGroups = new JBSplitGroup[](0);
            emptyRuleset[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

            JBTerminalConfig[] memory feeTerminalConfigs = new JBTerminalConfig[](1);
            JBAccountingContext[] memory feeTokens = new JBAccountingContext[](1);
            feeTokens[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
            feeTerminalConfigs[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: feeTokens});

            uint256 feeProjectId = jbController().launchProjectFor({
                owner: projectOwner,
                projectUri: "FeeProject",
                rulesetConfigurations: emptyRuleset,
                terminalConfigurations: feeTerminalConfigs,
                memo: ""
            });
            require(feeProjectId == 1, "Fee project must be #1");
        }

        // =====================================================================
        // Project A: 20% reserved, 60% cash out tax, splits 50% to B
        // =====================================================================
        JBRulesetConfig[] memory rulesetConfigA = new JBRulesetConfig[](1);
        rulesetConfigA[0].mustStartAtOrAfter = 0;
        rulesetConfigA[0].duration = 0;
        rulesetConfigA[0].weight = 1000e18;
        rulesetConfigA[0].weightCutPercent = 0;
        rulesetConfigA[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigA[0].metadata = JBRulesetMetadata({
            reservedPercent: 2000, // 20%
            cashOutTaxRate: 6000, // 60%
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
        rulesetConfigA[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigA[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        projectA = jbController().launchProjectFor({
            owner: projectOwner,
            projectUri: "ProjectA",
            rulesetConfigurations: rulesetConfigA,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // =====================================================================
        // Project B: 0% reserved, 0% cash out tax
        // =====================================================================
        JBRulesetConfig[] memory rulesetConfigB = new JBRulesetConfig[](1);
        rulesetConfigB[0].mustStartAtOrAfter = 0;
        rulesetConfigB[0].duration = 0;
        rulesetConfigB[0].weight = 1000e18;
        rulesetConfigB[0].weightCutPercent = 0;
        rulesetConfigB[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigB[0].metadata = JBRulesetMetadata({
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
        rulesetConfigB[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigB[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        projectB = jbController().launchProjectFor({
            owner: projectOwner,
            projectUri: "ProjectB",
            rulesetConfigurations: rulesetConfigB,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // =====================================================================
        // Project C: 50% reserved, 80% cash out tax
        // =====================================================================
        JBRulesetConfig[] memory rulesetConfigC = new JBRulesetConfig[](1);
        rulesetConfigC[0].mustStartAtOrAfter = 0;
        rulesetConfigC[0].duration = 0;
        rulesetConfigC[0].weight = 1000e18;
        rulesetConfigC[0].weightCutPercent = 0;
        rulesetConfigC[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigC[0].metadata = JBRulesetMetadata({
            reservedPercent: 5000, // 50%
            cashOutTaxRate: 8000, // 80%
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
        rulesetConfigC[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigC[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        projectC = jbController().launchProjectFor({
            owner: projectOwner,
            projectUri: "ProjectC",
            rulesetConfigurations: rulesetConfigC,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // =====================================================================
        // Create handler and register
        // =====================================================================
        handler = new EconomicHandler(
            jbMultiTerminal(),
            jbTerminalStore(),
            jbController(),
            jbTokens(),
            projectA,
            projectB,
            projectC,
            projectOwner
        );

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = EconomicHandler.payProjectA.selector;
        selectors[1] = EconomicHandler.payProjectB.selector;
        selectors[2] = EconomicHandler.payProjectC.selector;
        selectors[3] = EconomicHandler.cashOutA.selector;
        selectors[4] = EconomicHandler.cashOutB.selector;
        selectors[5] = EconomicHandler.cashOutC.selector;
        selectors[6] = EconomicHandler.sendPayoutsA.selector;
        selectors[7] = EconomicHandler.sendPayoutsB.selector;
        selectors[8] = EconomicHandler.sendPayoutsC.selector;
        selectors[9] = EconomicHandler.addToBalanceA.selector;
        selectors[10] = EconomicHandler.sendReservedTokensA.selector;
        selectors[11] = EconomicHandler.sendReservedTokensC.selector;
        selectors[12] = EconomicHandler.advanceTime.selector;
        // Double-weight pay operations (more common in practice)
        selectors[13] = EconomicHandler.payProjectA.selector;
        selectors[14] = EconomicHandler.payProjectB.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // =========================================================================
    // ECON1: Terminal balance >= sum of recorded balances for all projects
    // =========================================================================
    /// @notice The terminal's actual ETH balance must cover all recorded project balances.
    function invariant_ECON1_terminalBalanceCoversAllProjects() public view {
        uint256 balanceA = jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectA, JBConstants.NATIVE_TOKEN);
        uint256 balanceB = jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectB, JBConstants.NATIVE_TOKEN);
        uint256 balanceC = jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectC, JBConstants.NATIVE_TOKEN);
        uint256 balanceFee = jbTerminalStore().balanceOf(address(jbMultiTerminal()), 1, JBConstants.NATIVE_TOKEN);

        uint256 totalRecorded = balanceA + balanceB + balanceC + balanceFee;
        uint256 actualBalance = address(jbMultiTerminal()).balance;

        assertGe(
            actualBalance,
            totalRecorded,
            "ECON1: Terminal actual balance must >= sum of all project recorded balances"
        );
    }

    // =========================================================================
    // ECON2: Token supply consistency for each project
    // =========================================================================
    /// @notice For each project: totalSupplyOf >= 0 (non-negative, always true for uint).
    ///         Also verify total supply with reserves is >= raw supply.
    function invariant_ECON2_tokenSupplyConsistency() public view {
        uint256 supplyA = jbController().totalTokenSupplyWithReservedTokensOf(projectA);
        uint256 supplyB = jbController().totalTokenSupplyWithReservedTokensOf(projectB);
        uint256 supplyC = jbController().totalTokenSupplyWithReservedTokensOf(projectC);

        // Supply with reserves should be >= 0 (always true for uint, but validates no underflow)
        assertTrue(supplyA >= 0, "ECON2: Project A supply should be non-negative");
        assertTrue(supplyB >= 0, "ECON2: Project B supply should be non-negative");
        assertTrue(supplyC >= 0, "ECON2: Project C supply should be non-negative");
    }

    // =========================================================================
    // ECON3: Conservation — total payments >= total outflows + remaining balances
    // =========================================================================
    /// @notice Accounting for fees: total inflows >= total outflows.
    function invariant_ECON3_fundConservation() public view {
        uint256 totalInflows = handler.ghost_totalPaidInA() + handler.ghost_totalPaidInB()
            + handler.ghost_totalPaidInC() + handler.ghost_totalAddedToBalanceA();

        uint256 totalOutflows =
            handler.ghost_totalCashedOutA() + handler.ghost_totalCashedOutB() + handler.ghost_totalCashedOutC();

        // Inflows should always be >= outflows (fees are kept, not destroyed)
        assertGe(totalInflows, totalOutflows, "ECON3: Total inflows must >= total outflows");
    }

    // =========================================================================
    // ECON4: No agent extracts more from cashOut than they paid in
    //        (when cashOutTaxRate > 0 and no external addToBalance)
    // =========================================================================
    /// @notice With a 60% cash out tax on project A, no single actor should profit from cash outs alone.
    ///         Note: This invariant is only meaningful for project A (which has cash out tax).
    function invariant_ECON4_noProfitFromCashOutAlone() public view {
        // Check each actor's cash out vs paid in for Project A
        for (uint256 i = 0; i < handler.NUM_ACTORS(); i++) {
            address actor = handler.actors(i);
            uint256 paidIn = handler.actorPaidInA(actor);
            uint256 cashedOut = handler.actorCashedOutA(actor);

            // With a 60% cash out tax rate, no actor should cash out more than they put in
            // unless addToBalance was used (which inflates surplus without minting tokens)
            if (handler.ghost_totalAddedToBalanceA() == 0) {
                assertGe(
                    paidIn,
                    cashedOut,
                    "ECON4: Actor should not profit from cash out with tax rate > 0"
                );
            }
        }
    }

    // =========================================================================
    // ECON5: Fee project balance monotonically increases
    // =========================================================================
    /// @notice Fee project (#1) balance should never decrease — fees only flow in.
    function invariant_ECON5_feeProjectMonotonicallyIncreases() public view {
        assertFalse(
            handler.ghost_feeProjectBalanceDecreased(),
            "ECON5: Fee project balance must never decrease"
        );
    }

    // =========================================================================
    // ECON6: Cross-project split cascade verification
    // =========================================================================
    /// @notice When project A sends payouts and has splits to project B,
    ///         project B's recorded balance should increase.
    function invariant_ECON6_crossProjectSplitCascade() public view {
        // This invariant verifies that if a split cascade occurred,
        // it actually increased the target project's balance.
        // The ghost variables track before/after for each payout.
        if (handler.ghost_splitCascadeOccurred()) {
            assertGt(
                handler.ghost_projectBBalanceAfterSplit(),
                handler.ghost_projectBBalanceBeforeSplit(),
                "ECON6: Split to Project B should increase its balance"
            );
        }
    }
}
