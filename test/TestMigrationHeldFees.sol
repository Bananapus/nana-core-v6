// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

/// @notice Verifies M-16 fix: held fees are returned to project balance before terminal migration.
/// The migration now calls _returnHeldFees before recording the migration,
/// ensuring held fee tokens are included in the migrated balance.
contract TestMigrationHeldFees_Local is TestBaseWorkflow {
    IJBController private _controller;
    JBMultiTerminal private _terminal;
    JBMultiTerminal private _terminal2;
    JBTokens private _tokens;
    JBTerminalStore private _store;
    uint256 private _projectId;
    address private _projectOwner;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint112 private constant PAY_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _terminal2 = jbMultiTerminal2();
        _tokens = jbTokens();
        _store = jbTerminalStore();

        // Ruleset with holdFees=true and allowTerminalMigration=true.
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: true, // Fees are held, not processed immediately.
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);

        // Set up payout limit so fees are taken on payouts.
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({
            amount: uint224(PAY_AMOUNT),
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBFundAccessLimitGroup[] memory limitGroups = new JBFundAccessLimitGroup[](1);
        limitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = limitGroups;

        // Terminal configs — both terminals accept native token.
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](2);
        terminalConfigs[0] = JBTerminalConfig({terminal: IJBTerminal(address(_terminal)), accountingContextsToAccept: tokensToAccept});
        terminalConfigs[1] = JBTerminalConfig({terminal: IJBTerminal(address(_terminal2)), accountingContextsToAccept: tokensToAccept});

        // Fee project (#1).
        JBTerminalConfig[] memory feeTerminalConfigs = new JBTerminalConfig[](1);
        feeTerminalConfigs[0] = JBTerminalConfig({terminal: IJBTerminal(address(_terminal)), accountingContextsToAccept: tokensToAccept});

        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        feeRulesetConfig[0].duration = 0;
        feeRulesetConfig[0].weight = WEIGHT;
        feeRulesetConfig[0].metadata = metadata;
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        _controller.launchProjectFor({
            owner: address(420),
            projectUri: "fee",
            rulesetConfigurations: feeRulesetConfig,
            terminalConfigurations: feeTerminalConfigs,
            memo: ""
        });

        // Test project (#2).
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "test",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @notice M-16 FIX VERIFIED: held fees are returned to project balance during migration.
    function test_migration_heldFeesReturnedBeforeMigration() external {
        // Step 1: Pay the project.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _projectOwner,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Step 2: Distribute payouts (fees will be held since holdFees=true).
        vm.prank(_projectOwner);
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Verify held fees exist.
        JBFee[] memory heldFees = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
        assertGt(heldFees.length, 0, "Should have held fees after payout");

        // Record balance before migration.
        uint256 balanceBefore = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);

        // Step 3: Migrate balance to terminal2.
        // The fix returns held fees to the project balance before migrating.
        vm.prank(_projectOwner);
        uint256 migrated = _terminal.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(_terminal2)));

        // Step 4: Verify old terminal has no balance.
        uint256 balanceAfter = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceAfter, 0, "Old terminal should have 0 balance after migration");

        // Held fees should be cleared in old terminal (returned during migration).
        JBFee[] memory feesAfterMigration = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
        assertEq(feesAfterMigration.length, 0, "Held fees should be cleared after migration");

        // New terminal should have received the full balance (including returned fee amounts).
        uint256 newTerminalBalance = _store.balanceOf(address(_terminal2), _projectId, JBConstants.NATIVE_TOKEN);
        assertGt(newTerminalBalance, balanceBefore, "New terminal balance should include returned fees");
        assertEq(newTerminalBalance, migrated, "Migrated amount should match new terminal balance");
    }

    /// @notice Process held fees FIRST, then migrate — correct approach.
    function test_migration_feeProcessingBeforeMigration() external {
        // Pay.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _projectOwner,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Distribute payouts (holds fees).
        vm.prank(_projectOwner);
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Fast-forward past fee holding period (28 days).
        vm.warp(block.timestamp + 28 days + 1);

        // Process held fees before migration.
        uint256 feeProjectBalanceBefore = _store.balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);
        _terminal.processHeldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
        uint256 feeProjectBalanceAfter = _store.balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);

        // Fee project should have received fees.
        assertGt(feeProjectBalanceAfter, feeProjectBalanceBefore, "Fee project should receive fees");

        // Now held fees should be cleared.
        JBFee[] memory feesAfter = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
        assertEq(feesAfter.length, 0, "Held fees should be cleared after processing");

        // Now migrate safely.
        vm.prank(_projectOwner);
        _terminal.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(_terminal2)));
    }

    /// @notice After migration with fix, no held fees remain in old terminal.
    function test_migration_noHeldFeesRemainAfterMigration() external {
        // Pay and distribute.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _projectOwner,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        vm.prank(_projectOwner);
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Verify held fees exist before migration.
        JBFee[] memory heldFeesBefore = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
        assertGt(heldFeesBefore.length, 0, "Should have held fees before migration");

        // Migrate. Held fees are returned to project balance first.
        vm.prank(_projectOwner);
        _terminal.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(_terminal2)));

        // After migration, held fees should be cleared.
        JBFee[] memory heldFeesAfter = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
        assertEq(heldFeesAfter.length, 0, "Held fees should be cleared after migration");

        // processHeldFeesOf is a no-op since all fees were returned during migration.
        vm.warp(block.timestamp + 28 days + 1);
        _terminal.processHeldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);

        // Old terminal should have no balance and no held fees.
        uint256 oldBalance = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(oldBalance, 0, "Old terminal should have 0 balance");
    }

}
