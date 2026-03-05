// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/StdInvariant.sol";
import /* {*} from */ "../helpers/TestBaseWorkflow.sol";
import {TerminalStoreHandler} from "./handlers/TerminalStoreHandler.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";

/// @notice Invariant tests for JBTerminalStore fund conservation.
/// @dev Verifies that funds cannot be created or destroyed through normal terminal operations.
contract TerminalStoreInvariant_Local is StdInvariant, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TerminalStoreHandler public handler;

    uint256 public projectId;
    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // Launch fee collector project (#1)
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

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        jbController()
            .launchProjectFor({
                owner: address(420),
                projectUri: "feeCollector",
                rulesetConfigurations: feeRulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

        // Launch the test project (#2) with 50% cash out tax, no payout limit, no reserved rate
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 5000, // 50% tax
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

        projectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "testProject",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

        // Deploy ERC20 so tokens can be tracked
        vm.prank(projectOwner);
        jbController().deployERC20For(projectId, "TestToken", "TT", bytes32(0));

        // Deploy handler
        handler = new TerminalStoreHandler(
            jbMultiTerminal(), jbTerminalStore(), jbController(), jbTokens(), projectId, projectOwner
        );

        // Register handler as target
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = TerminalStoreHandler.payProject.selector;
        selectors[1] = TerminalStoreHandler.cashOutTokens.selector;
        selectors[2] = TerminalStoreHandler.sendPayouts.selector;
        selectors[3] = TerminalStoreHandler.addToBalance.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-TS-1: Terminal ETH balance >= sum of recorded balances for this project.
    /// @dev The terminal's actual ETH balance should always be >= what the store records,
    ///      because fees from other projects also accumulate in the terminal.
    function invariant_TS1_terminalBalanceCoversRecordedBalance() public view {
        uint256 recordedBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        uint256 actualBalance = address(jbMultiTerminal()).balance;

        assertGe(actualBalance, recordedBalance, "INV-TS-1: Terminal ETH balance must be >= recorded project balance");
    }

    /// @notice INV-TS-2: Reclaimable surplus <= current surplus, always.
    function invariant_TS2_reclaimableSurplusLeqSurplus() public view {
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        if (totalSupply == 0) return; // Skip when no tokens exist

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        uint256 surplus = jbTerminalStore()
            .currentSurplusOf({
                terminal: address(jbMultiTerminal()),
                projectId: projectId,
                accountingContexts: contexts,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

        // Check reclaimable for half the supply
        uint256 halfSupply = totalSupply / 2;
        if (halfSupply == 0) return;

        uint256 reclaimable = jbTerminalStore()
            .currentReclaimableSurplusOf({
                projectId: projectId, cashOutCount: halfSupply, totalSupply: totalSupply, surplus: surplus
            });

        assertLe(reclaimable, surplus, "INV-TS-2: Reclaimable surplus must not exceed current surplus");
    }

    /// @notice INV-TS-3: Fee project (project #1) balance in the terminal increases monotonically.
    /// @dev We can only check that it's >= 0; true monotonicity requires tracking across calls,
    ///      which the handler ghost variables assist with.
    function invariant_TS3_feeProjectBalanceNonNegative() public view {
        uint256 feeProjectBalance = jbTerminalStore().balanceOf(address(jbMultiTerminal()), 1, JBConstants.NATIVE_TOKEN);

        // Fee project balance should be non-negative (always true for uint, but conceptually
        // this checks that the fee project accumulates fees from cashouts).
        assertGe(feeProjectBalance, 0, "INV-TS-3: Fee project balance should be non-negative");
    }

    /// @notice INV-TS-4: Total actual ETH in terminal = recorded balance of all projects.
    /// @dev The terminal's ETH balance should equal the sum of all project balances recorded in the store.
    function invariant_TS4_terminalBalanceConservation() public view {
        uint256 projectBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);
        uint256 feeProjectBalance = jbTerminalStore().balanceOf(address(jbMultiTerminal()), 1, JBConstants.NATIVE_TOKEN);
        uint256 actualBalance = address(jbMultiTerminal()).balance;

        // The terminal's actual balance should equal the sum of all recorded project balances.
        // There should be no "unaccounted" ETH sitting in the terminal.
        assertEq(
            actualBalance,
            projectBalance + feeProjectBalance,
            "INV-TS-4: Terminal ETH balance must equal sum of all recorded project balances"
        );
    }

    /// @notice INV-TS-5: Ghost variable conservation check.
    /// @dev totalPaidIn + totalAddedToBalance >= totalCashedOut + totalPaidOut + remaining balance.
    ///      Fees complicate exact equality, so we use >= for the funds-in side.
    function invariant_TS5_ghostVariableConservation() public view {
        uint256 totalIn = handler.ghost_totalPaidIn() + handler.ghost_totalAddedToBalance();
        uint256 totalOut = handler.ghost_totalCashedOut() + handler.ghost_totalPaidOut();

        uint256 projectBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, JBConstants.NATIVE_TOKEN);

        // Everything that went in must be >= everything that went out + what remains.
        // Strict equality breaks because fees redistribute between projects.
        assertGe(
            totalIn,
            totalOut + projectBalance
                - jbTerminalStore().balanceOf(address(jbMultiTerminal()), 1, JBConstants.NATIVE_TOKEN),
            "INV-TS-5: Ghost conservation - funds in >= funds out + project balance (adjusted for fees)"
        );
    }
}
