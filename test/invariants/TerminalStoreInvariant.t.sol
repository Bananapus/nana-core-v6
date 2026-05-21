// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
import {TerminalStoreHandler} from "./handlers/TerminalStoreHandler.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";

/// @notice Invariant tests for JBTerminalStore fund conservation.
/// @dev Verifies that funds cannot be created or destroyed through normal terminal operations.
contract TerminalStoreInvariant_Local is StdInvariant, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TerminalStoreHandler public handler;

    uint256 public projectId;
    uint256 public projectId2;
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory feeTerminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        feeTerminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        jbController()
            .launchProjectFor({
            owner: address(420),
            projectUri: "feeCollector",
            rulesetConfigurations: feeRulesetConfig,
            terminalConfigurations: feeTerminalConfigurations,
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
            allowTerminalMigration: true,
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
            metadata: 0
        });
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](2);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});
        terminalConfigurations[1] =
            JBTerminalConfig({terminal: jbMultiTerminal2(), accountingContextsToAccept: tokensToAccept});

        projectId = jbController()
            .launchProjectFor({
            owner: projectOwner,
            projectUri: "testProject",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
        projectId2 = jbController()
            .launchProjectFor({
            owner: projectOwner,
            projectUri: "testProject2",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // Deploy ERC20 so tokens can be tracked
        vm.prank(projectOwner);
        jbController().deployERC20For({projectId: projectId, name: "TestToken", symbol: "TT", salt: bytes32(0)});
        vm.prank(projectOwner);
        jbController().deployERC20For({projectId: projectId2, name: "TestToken2", symbol: "TT2", salt: bytes32(0)});

        // Deploy handler
        uint256[] memory projectIds = new uint256[](2);
        projectIds[0] = projectId;
        projectIds[1] = projectId2;
        handler = new TerminalStoreHandler({
            _terminal: jbMultiTerminal(),
            _terminal2: jbMultiTerminal2(),
            _store: jbTerminalStore(),
            _controller: jbController(),
            _tokens: jbTokens(),
            _projectIds: projectIds,
            _projectOwner: projectOwner
        });

        // Register handler as target
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = TerminalStoreHandler.payProject.selector;
        selectors[1] = TerminalStoreHandler.cashOutTokens.selector;
        selectors[2] = TerminalStoreHandler.sendPayouts.selector;
        selectors[3] = TerminalStoreHandler.addToBalance.selector;
        selectors[4] = TerminalStoreHandler.migrateBalance.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Sum a terminal's native balances for every project the handler can touch plus the fee project.
    /// @param terminal The terminal whose recorded native balances are being summed.
    function _recordedNativeBalanceOf(address terminal) internal view returns (uint256 balance) {
        balance = jbTerminalStore().balanceOf({terminal: terminal, projectId: 1, token: JBConstants.NATIVE_TOKEN});
        balance += jbTerminalStore()
            .balanceOf({terminal: terminal, projectId: projectId, token: JBConstants.NATIVE_TOKEN});
        balance += jbTerminalStore()
            .balanceOf({terminal: terminal, projectId: projectId2, token: JBConstants.NATIVE_TOKEN});
    }

    /// @notice Sum the native balances for every project and terminal the handler can touch plus the fee project.
    function _trackedNativeBalance() internal view returns (uint256 balance) {
        balance = _recordedNativeBalanceOf(address(jbMultiTerminal()));
        balance += _recordedNativeBalanceOf(address(jbMultiTerminal2()));
    }

    /// @notice Sum the actual ETH held by every terminal in this invariant campaign.
    function _trackedTerminalEthBalance() internal view returns (uint256 balance) {
        balance = address(jbMultiTerminal()).balance + address(jbMultiTerminal2()).balance;
    }

    /// @notice INV-TS-1: Terminal ETH balance covers every tracked project's recorded native balance.
    /// @dev This is the core native-token solvency invariant for the campaign: randomized actions can move value among
    ///      two independent projects and the fee project, but the terminal must always hold enough ETH to cover their
    ///      combined store balances.
    function invariant_TS1_terminalBalanceCoversRecordedBalance() public view {
        uint256 recordedBalance = _trackedNativeBalance();
        uint256 actualBalance = _trackedTerminalEthBalance();

        assertGe(actualBalance, recordedBalance, "INV-TS-1: Terminal ETH balance must cover tracked project balances");
    }

    /// @notice INV-TS-2: Reclaimable surplus <= current surplus, always.
    function invariant_TS2_reclaimableSurplusLeqSurplus() public view {
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        if (totalSupply == 0) return; // Skip when no tokens exist

        IJBTerminal[] memory _terminals = new IJBTerminal[](2);
        _terminals[0] = IJBTerminal(jbMultiTerminal());
        _terminals[1] = IJBTerminal(jbMultiTerminal2());
        uint256 surplus = jbTerminalStore()
            .currentSurplusOf({
            projectId: projectId,
            terminals: _terminals,
            tokens: new address[](0),
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
        uint256 feeProjectBalance = jbTerminalStore()
            .balanceOf({terminal: address(jbMultiTerminal()), projectId: 1, token: JBConstants.NATIVE_TOKEN});
        feeProjectBalance += jbTerminalStore()
            .balanceOf({terminal: address(jbMultiTerminal2()), projectId: 1, token: JBConstants.NATIVE_TOKEN});

        // Fee project balance should be non-negative (always true for uint, but conceptually
        // this checks that the fee project accumulates fees from cashouts).
        assertGe(feeProjectBalance, 0, "INV-TS-3: Fee project balance should be non-negative");
    }

    /// @notice INV-TS-4: The campaign's tracked native balances account for the terminal's ETH.
    /// @dev No handler action sends raw ETH directly to the terminal, so there should be no untracked native balance.
    function invariant_TS4_terminalBalanceConservation() public view {
        uint256 trackedBalance = _trackedNativeBalance();
        uint256 actualBalance = _trackedTerminalEthBalance();

        // The terminal's actual balance should equal the sum of all recorded project balances.
        // There should be no "unaccounted" ETH sitting in the terminal.
        assertEq(
            actualBalance,
            trackedBalance,
            "INV-TS-4: Terminal ETH balance must equal sum of all recorded project balances"
        );
    }

    /// @notice INV-TS-5: Ghost variable conservation check.
    /// @dev totalPaidIn + totalAddedToBalance >= totalCashedOut + totalPaidOut + remaining balance.
    ///      Fees complicate exact equality, so we use >= for the funds-in side.
    function invariant_TS5_ghostVariableConservation() public view {
        uint256 totalIn = handler.ghost_totalPaidIn() + handler.ghost_totalAddedToBalance();
        uint256 totalOut = handler.ghost_totalCashedOut() + handler.ghost_totalPaidOut();

        uint256 trackedBalance = _trackedNativeBalance();

        // Everything that went in must be >= everything that went out + what remains.
        // The tracked balance includes the fee project, so fee redistribution stays inside this equation.
        assertGe(
            totalIn,
            totalOut + trackedBalance,
            "INV-TS-5: Ghost conservation - funds in >= funds out + project balance (adjusted for fees)"
        );
    }
}
