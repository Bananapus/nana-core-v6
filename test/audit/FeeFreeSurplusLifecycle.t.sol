// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
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

/// @notice Regression tests for the `_feeFreeSurplusOf` lifecycle: cap on repeated payout-to-self and clear on
/// migration.
contract FeeFreeSurplusLifecycleTest is TestBaseWorkflow {
    // --- State ---

    // The controller orchestrating project lifecycle.
    IJBController private _controller;
    // The terminal handling payments, payouts, and cash outs.
    JBMultiTerminal private _terminal;
    // A second terminal used as the migration target.
    JBMultiTerminal private _terminal2;
    // The token accounting manager.
    JBTokens private _tokens;

    // The project that pays out to the recipient (has splits pointing to _recipientProjectId).
    uint256 private _payerProjectId;
    // The project that receives the intra-terminal payout (accumulates fee-free surplus).
    uint256 private _recipientProjectId;
    // The address that owns both projects.
    address private _projectOwner;

    // Token issuance weight: 1000 tokens per ETH.
    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    // Amount of ETH used for payments and payouts.
    uint256 private constant PAY_AMOUNT = 10 ether;
    // Duration of each ruleset cycle (enables payout limit reset per cycle).
    uint32 private constant CYCLE_DURATION = 1 days;

    // Storage slot index for _feeFreeSurplusOf in JBMultiTerminal (verified via `forge inspect`).
    uint256 private constant FEE_FREE_SURPLUS_SLOT = 0;

    function setUp() public override {
        // Deploy the full protocol stack via the base workflow helper.
        super.setUp();

        // Cache references to core contracts.
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _terminal2 = jbMultiTerminal2();
        _tokens = jbTokens();
        _projectOwner = multisig();

        // Define a single accounting context accepting native ETH.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Terminal configurations — both terminals accept ETH for both projects.
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](2);
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: accountingContexts});
        terminalConfigs[1] = JBTerminalConfig({terminal: _terminal2, accountingContextsToAccept: accountingContexts});

        // --- Fee project (project #1) ---
        // The fee beneficiary project must exist before any fee-charging operations.
        JBRulesetConfig[] memory feeProjectRuleset = new JBRulesetConfig[](1);
        feeProjectRuleset[0] = _rulesetConfig({
            duration: 0,
            metadata: _metadata({allowTerminalMigration: false}),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Launch the fee project (will be project #1).
        _controller.launchProjectFor({
            owner: makeAddr("fee-project-owner"),
            projectUri: "fee-project",
            rulesetConfigurations: feeProjectRuleset,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // --- Recipient project (receives payout-to-self) ---
        // No payout limits or surplus allowances — it just receives funds.
        JBRulesetConfig[] memory recipientRuleset = new JBRulesetConfig[](1);
        recipientRuleset[0] = _rulesetConfig({
            duration: 0,
            metadata: _metadata({allowTerminalMigration: true}),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Launch the recipient project.
        _recipientProjectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "recipient-project",
            rulesetConfigurations: recipientRuleset,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // --- Payer project (sends payouts to recipient on same terminal) ---
        // Splits: 100% of payouts go to the recipient project on the same terminal via addToBalance.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: true,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(_recipientProjectId),
            beneficiary: payable(address(0)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // One split group keyed by the native token.
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        // Payout limit: allow paying out the full PAY_AMOUNT each cycle.
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint224(PAY_AMOUNT),
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Fund access limits with the payout limit defined above.
        JBFundAccessLimitGroup[] memory payerLimits = new JBFundAccessLimitGroup[](1);
        payerLimits[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        // Payer project uses a cycling duration so payout limits reset each cycle.
        JBRulesetConfig[] memory payerRuleset = new JBRulesetConfig[](1);
        payerRuleset[0] = _rulesetConfig({
            duration: CYCLE_DURATION,
            metadata: _metadata({allowTerminalMigration: false}),
            splitGroups: splitGroups,
            fundAccessLimitGroups: payerLimits
        });

        // Launch the payer project.
        _payerProjectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "payer-project",
            rulesetConfigurations: payerRuleset,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice After repeated payout-to-self cycles, _feeFreeSurplusOf must never exceed the recipient's recorded
    /// balance.
    /// @dev This proves the cap added in `_executePayout`: `min(newFeeFreeSurplus, balanceAfterPayout)`.
    function test_feeFreeSurplusCappedOnRepeatedPayoutToSelf() external {
        // Fund the payer project with enough ETH for 3 full payout cycles.
        address payer = makeAddr("payer");
        vm.deal(payer, PAY_AMOUNT * 3);

        // Pay 3x PAY_AMOUNT into the payer project so it has a large enough balance for 3 cycles.
        vm.prank(payer);
        _terminal.pay{value: PAY_AMOUNT * 3}({
            projectId: _payerProjectId,
            amount: PAY_AMOUNT * 3,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // --- Cycle 1: Execute payout. Funds flow from payer project -> recipient project (same terminal). ---
        _terminal.sendPayoutsOf({
            projectId: _payerProjectId,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // Read the recipient's recorded balance after cycle 1.
        uint256 balanceAfterCycle1 =
            jbTerminalStore().balanceOf(address(_terminal), _recipientProjectId, JBConstants.NATIVE_TOKEN);

        // Read the fee-free surplus from storage after cycle 1.
        uint256 feeFreeSurplusAfterCycle1 = _readFeeFreeSurplus(_recipientProjectId, JBConstants.NATIVE_TOKEN);

        // After cycle 1: fee-free surplus should equal the balance (first payout, no prior surplus).
        assertEq(
            feeFreeSurplusAfterCycle1,
            balanceAfterCycle1,
            "Cycle 1: fee-free surplus should equal the balance after first payout"
        );

        // --- Cycle 2: Warp forward one cycle duration, then execute another payout. ---
        vm.warp(block.timestamp + CYCLE_DURATION);

        _terminal.sendPayoutsOf({
            projectId: _payerProjectId,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // Read the recipient's recorded balance after cycle 2.
        uint256 balanceAfterCycle2 =
            jbTerminalStore().balanceOf(address(_terminal), _recipientProjectId, JBConstants.NATIVE_TOKEN);

        // Read the fee-free surplus from storage after cycle 2.
        uint256 feeFreeSurplusAfterCycle2 = _readFeeFreeSurplus(_recipientProjectId, JBConstants.NATIVE_TOKEN);

        // KEY ASSERTION: fee-free surplus must not exceed the recorded balance.
        assertLe(
            feeFreeSurplusAfterCycle2,
            balanceAfterCycle2,
            "Cycle 2: fee-free surplus must be <= recorded balance (cap enforced)"
        );

        // --- Cycle 3: Warp forward another cycle duration, then execute a third payout. ---
        vm.warp(block.timestamp + CYCLE_DURATION);

        _terminal.sendPayoutsOf({
            projectId: _payerProjectId,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // Read the recipient's recorded balance after cycle 3.
        uint256 balanceAfterCycle3 =
            jbTerminalStore().balanceOf(address(_terminal), _recipientProjectId, JBConstants.NATIVE_TOKEN);

        // Read the fee-free surplus from storage after cycle 3.
        uint256 feeFreeSurplusAfterCycle3 = _readFeeFreeSurplus(_recipientProjectId, JBConstants.NATIVE_TOKEN);

        // KEY ASSERTION: fee-free surplus must not exceed the recorded balance, even after 3 cycles.
        assertLe(
            feeFreeSurplusAfterCycle3,
            balanceAfterCycle3,
            "Cycle 3: fee-free surplus must be <= recorded balance (cap enforced)"
        );

        // Verify the balance grew (confirming the payouts actually landed).
        assertEq(balanceAfterCycle3, PAY_AMOUNT * 3, "Recipient balance should be 3x PAY_AMOUNT after 3 cycles");

        // Verify the fee-free surplus is exactly the balance (capped, not 3x accumulated).
        assertEq(
            feeFreeSurplusAfterCycle3,
            balanceAfterCycle3,
            "Fee-free surplus should be capped at the balance, not at 3x the payout amount"
        );
    }

    /// @notice After accumulating fee-free surplus via payout-to-self, migrating the terminal clears it to zero.
    /// @dev This proves the `delete _feeFreeSurplusOf[projectId][token]` in `migrateBalanceOf`.
    function test_feeFreeSurplusClearedOnMigration() external {
        // Fund the payer project so it can execute a payout.
        address payer = makeAddr("payer");
        vm.deal(payer, PAY_AMOUNT);

        // Pay into the payer project.
        vm.prank(payer);
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _payerProjectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Execute payout: funds flow to recipient on the same terminal (fee-free, intra-terminal).
        _terminal.sendPayoutsOf({
            projectId: _payerProjectId,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // Verify the recipient has accumulated fee-free surplus.
        uint256 feeFreeSurplusBefore = _readFeeFreeSurplus(_recipientProjectId, JBConstants.NATIVE_TOKEN);
        assertGt(feeFreeSurplusBefore, 0, "Fee-free surplus should be non-zero before migration");

        // Verify the recipient has a balance to migrate.
        uint256 balanceBefore =
            jbTerminalStore().balanceOf(address(_terminal), _recipientProjectId, JBConstants.NATIVE_TOKEN);
        assertGt(balanceBefore, 0, "Recipient balance should be non-zero before migration");

        // Migrate the recipient project's balance from terminal 1 to terminal 2.
        vm.prank(_projectOwner);
        uint256 migratedAmount = _terminal.migrateBalanceOf(_recipientProjectId, JBConstants.NATIVE_TOKEN, _terminal2);

        // Verify the full balance was migrated.
        assertEq(migratedAmount, balanceBefore, "Full balance should be migrated");

        // KEY ASSERTION: fee-free surplus must be zero after migration.
        uint256 feeFreeSurplusAfter = _readFeeFreeSurplus(_recipientProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(feeFreeSurplusAfter, 0, "Fee-free surplus must be zero after migration");

        // Verify the old terminal's balance is now zero.
        uint256 balanceAfterOnOldTerminal =
            jbTerminalStore().balanceOf(address(_terminal), _recipientProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceAfterOnOldTerminal, 0, "Old terminal balance should be zero after migration");

        // Verify the new terminal received the balance.
        uint256 balanceOnNewTerminal =
            jbTerminalStore().balanceOf(address(_terminal2), _recipientProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceOnNewTerminal, balanceBefore, "New terminal should have the migrated balance");
    }

    // --- Helpers ---

    /// @notice Read `_feeFreeSurplusOf[projectId][token]` directly from JBMultiTerminal storage.
    /// @dev Uses `vm.load` to read the internal mapping at slot 0. Slot computation:
    ///      `keccak256(abi.encode(token, keccak256(abi.encode(projectId, FEE_FREE_SURPLUS_SLOT))))`.
    /// @param projectId The project ID to look up.
    /// @param token The token address to look up.
    /// @return The current fee-free surplus value.
    function _readFeeFreeSurplus(uint256 projectId, address token) private view returns (uint256) {
        // Compute the inner slot: keccak256(abi.encode(projectId, baseSlot)).
        bytes32 innerSlot = keccak256(abi.encode(projectId, FEE_FREE_SURPLUS_SLOT));
        // Compute the final slot: keccak256(abi.encode(token, innerSlot)).
        bytes32 finalSlot = keccak256(abi.encode(token, innerSlot));
        // Load the value from the terminal's storage.
        return uint256(vm.load(address(_terminal), finalSlot));
    }

    /// @notice Build ruleset metadata with configurable terminal migration flag.
    /// @param allowTerminalMigration Whether the ruleset allows terminal migration.
    /// @return metadata The constructed metadata struct.
    function _metadata(bool allowTerminalMigration) private pure returns (JBRulesetMetadata memory metadata) {
        metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: allowTerminalMigration,
            allowSetTerminals: true,
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

    /// @notice Build a ruleset config with the given parameters.
    /// @param duration The cycle duration in seconds (0 = never expires).
    /// @param metadata The ruleset metadata.
    /// @param splitGroups The split groups for payout distribution.
    /// @param fundAccessLimitGroups The fund access limit groups.
    /// @return config The constructed ruleset config.
    function _rulesetConfig(
        uint32 duration,
        JBRulesetMetadata memory metadata,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        private
        pure
        returns (JBRulesetConfig memory config)
    {
        config.mustStartAtOrAfter = 0;
        config.duration = duration;
        config.weight = WEIGHT;
        config.weightCutPercent = 0;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
        config.metadata = metadata;
        config.splitGroups = splitGroups;
        config.fundAccessLimitGroups = fundAccessLimitGroups;
    }
}
