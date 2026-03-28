// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBFees} from "../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

/// @notice E2E test: Pay into terminal A -> migrate to terminal B -> verify balances, surplus, cash outs.
contract TestTerminalMigration_Local is TestBaseWorkflow {
    IJBController private _controller;
    JBMultiTerminal private _terminalA;
    JBMultiTerminal private _terminalB;
    uint256 private _projectId;
    address private _projectOwner;
    address private _beneficiary;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _controller = jbController();
        _terminalA = jbMultiTerminal();
        _terminalB = jbMultiTerminal2();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: true, // KEY: Enable migration
            allowSetTerminals: true,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = 1000 * 10 ** 18;
        _rulesetConfig[0].weightCutPercent = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Launch with terminal A
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory _terminalConfigs = new JBTerminalConfig[](2);
        _terminalConfigs[0] = JBTerminalConfig({terminal: _terminalA, accountingContextsToAccept: _tokensToAccept});
        _terminalConfigs[1] = JBTerminalConfig({terminal: _terminalB, accountingContextsToAccept: _tokensToAccept});

        _projectId = _controller.launchProjectFor({
            owner: address(_projectOwner),
            projectUri: "migration-test",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigs,
            memo: ""
        });
    }

    /// @notice Full migration E2E: pay A -> migrate to B -> verify balances -> cash out from B.
    function test_migrationE2E() public {
        uint256 payAmount = 10 ether;

        // Step 1: Pay into terminal A
        vm.deal(_beneficiary, payAmount);
        vm.prank(_beneficiary);
        uint256 tokensReceived =
            _terminalA.pay{value: payAmount}(_projectId, JBConstants.NATIVE_TOKEN, payAmount, _beneficiary, 0, "", "");
        assertGt(tokensReceived, 0, "should receive tokens");

        // Step 2: Verify terminal A has the balance
        uint256 balanceA = jbTerminalStore().balanceOf(address(_terminalA), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceA, payAmount, "terminal A should have full balance");

        uint256 balanceB = jbTerminalStore().balanceOf(address(_terminalB), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceB, 0, "terminal B should have zero balance");

        // Step 3: Migrate from A to B
        vm.prank(_projectOwner);
        uint256 migratedBalance = _terminalA.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, _terminalB);
        assertEq(migratedBalance, payAmount, "full balance should be migrated");

        // Step 4: Verify balances after migration (fee project is exempt from migration fee)
        uint256 balanceAAfter = jbTerminalStore().balanceOf(address(_terminalA), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceAAfter, 0, "terminal A should have zero after migration");

        uint256 balanceBAfter = jbTerminalStore().balanceOf(address(_terminalB), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceBAfter, payAmount, "terminal B should have full balance");

        // Step 5: Terminal B's ETH balance should match
        assertEq(address(_terminalB).balance, payAmount, "terminal B ETH balance should match");

        // Step 6: Cash out from terminal B (0% tax means full reclaim)
        uint256 beneficiaryBalanceBefore = _beneficiary.balance;
        vm.prank(_beneficiary);
        uint256 reclaimedAmount = _terminalB.cashOutTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            cashOutCount: tokensReceived,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: ""
        });

        assertGt(reclaimedAmount, 0, "should reclaim tokens");
        assertEq(
            _beneficiary.balance, beneficiaryBalanceBefore + reclaimedAmount, "beneficiary should receive reclaimed ETH"
        );
    }

    /// @notice Migration preserves surplus calculations.
    function test_migration_preservesSurplus() public {
        uint256 payAmount = 5 ether;

        // Pay into terminal A
        vm.deal(_beneficiary, payAmount);
        vm.prank(_beneficiary);
        _terminalA.pay{value: payAmount}(_projectId, JBConstants.NATIVE_TOKEN, payAmount, _beneficiary, 0, "", "");

        // Record surplus before migration
        uint256 surplusBefore =
            _terminalA.currentSurplusOf(_projectId, new address[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(surplusBefore, 0, "should have surplus before migration");

        // Migrate
        vm.prank(_projectOwner);
        _terminalA.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, _terminalB);

        // Check surplus from terminal B (fee project exempt from migration fee)
        uint256 surplusAfter =
            _terminalB.currentSurplusOf(_projectId, new address[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertEq(surplusAfter, surplusBefore, "surplus should be preserved after migration");
    }

    /// @notice Migration without permission reverts.
    function test_migration_unauthorizedReverts() public {
        vm.deal(_beneficiary, 1 ether);
        vm.prank(_beneficiary);
        _terminalA.pay{value: 1 ether}(_projectId, JBConstants.NATIVE_TOKEN, 1 ether, _beneficiary, 0, "", "");

        // Try to migrate as non-owner
        vm.prank(_beneficiary);
        vm.expectRevert();
        _terminalA.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, _terminalB);
    }

    /// @notice Non-fee project migration charges the 2.5% fee; fee project balance increases.
    function test_migration_nonFeeProject_chargesFee() public {
        // Launch a second project (project 2) — this is NOT the fee project.
        JBRulesetMetadata memory _metadata2 = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig2 = new JBRulesetConfig[](1);
        _rulesetConfig2[0].mustStartAtOrAfter = 0;
        _rulesetConfig2[0].duration = 0;
        _rulesetConfig2[0].weight = 1000 * 10 ** 18;
        _rulesetConfig2[0].weightCutPercent = 0;
        _rulesetConfig2[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig2[0].metadata = _metadata2;
        _rulesetConfig2[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig2[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory _terminalConfigs2 = new JBTerminalConfig[](2);
        _terminalConfigs2[0] =
            JBTerminalConfig({terminal: _terminalA, accountingContextsToAccept: _tokensToAccept});
        _terminalConfigs2[1] =
            JBTerminalConfig({terminal: _terminalB, accountingContextsToAccept: _tokensToAccept});

        uint256 project2 = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "non-fee-project",
            rulesetConfigurations: _rulesetConfig2,
            terminalConfigurations: _terminalConfigs2,
            memo: ""
        });

        // Confirm project 2 is NOT the fee project.
        assertGt(project2, 1, "project2 should not be the fee project");

        uint256 payAmount = 10 ether;

        // Pay into terminal A for project 2.
        vm.deal(_beneficiary, payAmount);
        vm.prank(_beneficiary);
        _terminalA.pay{value: payAmount}(project2, JBConstants.NATIVE_TOKEN, payAmount, _beneficiary, 0, "", "");

        // Snapshot fee project balance before migration.
        uint256 feeBalanceBefore =
            jbTerminalStore().balanceOf(address(_terminalA), 1, JBConstants.NATIVE_TOKEN);

        // Migrate project 2 from terminal A to terminal B.
        vm.prank(_projectOwner);
        _terminalA.migrateBalanceOf(project2, JBConstants.NATIVE_TOKEN, _terminalB);

        // Fee project balance should have increased (fee was charged).
        uint256 feeBalanceAfter =
            jbTerminalStore().balanceOf(address(_terminalA), 1, JBConstants.NATIVE_TOKEN);
        assertGt(feeBalanceAfter, feeBalanceBefore, "fee project should receive migration fee");

        // Terminal B should have received payAmount minus the 2.5% fee.
        uint256 expectedFee = JBFees.feeAmountFrom({amountBeforeFee: payAmount, feePercent: 25});
        uint256 balanceBAfter =
            jbTerminalStore().balanceOf(address(_terminalB), project2, JBConstants.NATIVE_TOKEN);
        assertEq(balanceBAfter, payAmount - expectedFee, "terminal B balance should reflect fee deduction");
    }

    /// @notice Fee project (project 1) migration is exempt from fees.
    function test_migration_feeProject_noFeeCharged() public {
        // _projectId is project 1, which IS the fee project.
        assertEq(_projectId, 1, "project under test should be the fee project");

        uint256 payAmount = 10 ether;

        // Pay into terminal A for the fee project.
        vm.deal(_beneficiary, payAmount);
        vm.prank(_beneficiary);
        _terminalA.pay{value: payAmount}(_projectId, JBConstants.NATIVE_TOKEN, payAmount, _beneficiary, 0, "", "");

        // Migrate fee project from terminal A to terminal B.
        vm.prank(_projectOwner);
        uint256 migratedBalance = _terminalA.migrateBalanceOf(_projectId, JBConstants.NATIVE_TOKEN, _terminalB);
        assertEq(migratedBalance, payAmount, "full balance should be migrated without fee");

        // Terminal B should have the full amount (no fee deducted).
        uint256 balanceBAfter =
            jbTerminalStore().balanceOf(address(_terminalB), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceBAfter, payAmount, "fee project should not be charged migration fee");
    }
}
