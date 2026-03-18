// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../src/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {IJBPayoutTerminal} from "../src/interfaces/IJBPayoutTerminal.sol";
import {IJBSplits} from "../src/interfaces/IJBSplits.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

/// @notice Audit response: proves 3 design decisions are intentional and correct.
/// Finding 1: currentOf() first cycle NOT skipped — returns the stored ruleset directly.
/// Finding 2: Splits groupId namespace is intentional — contracts can self-authorize their own namespace.
/// Finding 3: Same-terminal fee exemption is intentional — fees apply to fund egress, not intra-terminal accounting.
contract TestAuditResponseDesignProofs is TestBaseWorkflow {
    IJBController private _controller;
    IJBRulesets private _rulesets;
    IJBTerminal private _terminal;
    IJBSplits private _splits;

    address private _projectOwner;

    function setUp() public override {
        super.setUp();
        _projectOwner = multisig();
        _terminal = jbMultiTerminal();
        _controller = jbController();
        _rulesets = jbRulesets();
        _splits = jbSplits();
    }

    // ───────────────────────────────────────────────────────────
    //  Finding 1: currentOf() first cycle NOT skipped
    // ───────────────────────────────────────────────────────────

    /// @notice During the first cycle, currentOf() returns the original stored weight and cycleNumber=1.
    function test_currentOf_firstCycle_returnsOriginalWeight() public {
        uint256 projectId = _launchProjectWithDuration(30 days, 1000e18, 100_000_000);

        JBRuleset memory ruleset = _rulesets.currentOf(projectId);

        assertEq(ruleset.cycleNumber, 1, "First cycle should be cycleNumber 1");
        assertEq(ruleset.weight, 1000e18, "First cycle should return original weight");
        assertEq(ruleset.duration, 30 days, "Duration should match");
    }

    /// @notice After the first cycle ends, currentOf() returns cycleNumber=2 with decayed weight.
    function test_currentOf_secondCycle_returnsDecayedWeight() public {
        uint256 projectId = _launchProjectWithDuration(30 days, 1000e18, 100_000_000);

        // Warp past the first 30-day cycle.
        vm.warp(block.timestamp + 30 days + 1);

        JBRuleset memory ruleset = _rulesets.currentOf(projectId);

        assertEq(ruleset.cycleNumber, 2, "Should be second cycle");
        // 10% weight cut: 1000e18 * (1_000_000_000 - 100_000_000) / 1_000_000_000 = 900e18
        assertEq(ruleset.weight, 900e18, "Second cycle weight should be decayed by 10%");
    }

    /// @notice Payout limits reset per cycle — using the full limit in cycle 1 doesn't affect cycle 2.
    function test_payoutLimitBuckets_resetPerCycle() public {
        // Launch a project with a 1 ETH payout limit per cycle.
        uint256 projectId = _launchProjectWithPayoutLimit(30 days, 1e18);

        // Pay 10 ETH into the project.
        vm.deal(address(this), 20e18);
        _terminal.pay{value: 10e18}(projectId, JBConstants.NATIVE_TOKEN, 10e18, address(this), 0, "", "");

        // Use the full payout limit in cycle 1.
        vm.prank(_projectOwner);
        IJBPayoutTerminal(address(_terminal))
            .sendPayoutsOf(projectId, JBConstants.NATIVE_TOKEN, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)), 0);

        // Warp to cycle 2.
        vm.warp(block.timestamp + 30 days + 1);

        // Should be able to send payouts again — the limit resets.
        vm.prank(_projectOwner);
        IJBPayoutTerminal(address(_terminal))
            .sendPayoutsOf(projectId, JBConstants.NATIVE_TOKEN, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)), 0);
        // If this doesn't revert, the payout limit reset per cycle is confirmed.
    }

    // ───────────────────────────────────────────────────────────
    //  Finding 2: Splits groupId namespace — bare addresses reserved for protocol
    // ───────────────────────────────────────────────────────────

    /// @notice A contract can set splits in its own namespace when upper 96 bits are non-zero.
    function test_splits_contractCanSetOwnNamespaceWithUpperBits() public {
        uint256 projectId = _launchSimpleProject();

        // Self-auth requires non-zero upper 96 bits + lower 160 bits == msg.sender.
        uint256 groupId = (1 << 160) | uint256(uint160(address(this)));

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(address(0xBEEF));
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        // This call should succeed because address(this) matches the first 160 bits and upper bits != 0.
        _splits.setSplitGroupsOf(projectId, 0, groups);

        // Verify the splits were set.
        JBSplit[] memory stored = _splits.splitsOf(projectId, 0, groupId);
        assertEq(stored.length, 1, "Should have 1 split");
        assertEq(stored[0].beneficiary, address(0xBEEF), "Beneficiary should match");
    }

    /// @notice A contract cannot self-auth for bare-address groupIds (upper 96 bits = 0).
    /// These are reserved for protocol use (terminal payout groups keyed by token address).
    function test_splits_bareAddressGroupIdBlocksSelfAuth() public {
        uint256 projectId = _launchSimpleProject();

        // Bare address groupId: upper 96 bits = 0. Even though lower 160 bits == msg.sender,
        // this is a protocol-reserved namespace and requires controller auth.
        uint256 groupId = uint256(uint160(address(this)));

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(address(0xBEEF));
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        // This call should revert because bare-address groupIds require controller auth,
        // preventing token contracts from hijacking terminal payout splits.
        vm.expectRevert();
        _splits.setSplitGroupsOf(projectId, 0, groups);
    }

    /// @notice A contract cannot set splits in a namespace that belongs to a different address.
    function test_splits_contractCannotSetOtherNamespace() public {
        uint256 projectId = _launchSimpleProject();

        // groupId with a DIFFERENT address (not the caller).
        uint256 groupId = uint256(uint160(address(0xDEAD)));

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(address(0xBEEF));
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        // This call should revert because address(this) != address(0xDEAD) and address(this) is not the controller.
        vm.expectRevert();
        _splits.setSplitGroupsOf(projectId, 0, groups);
    }

    // ───────────────────────────────────────────────────────────
    //  Finding 3: Same-terminal fee exemption is intentional
    // ───────────────────────────────────────────────────────────

    /// @notice When project A pays out to project B on the SAME terminal, no fee is taken.
    function test_sameTerminal_payoutNoFee() public {
        // Launch project B (the recipient) on the same terminal.
        uint256 projectB = _launchSimpleProject();

        // Launch project A with a split that sends 100% to project B.
        uint256 projectA = _launchProjectWithSplitToProject(projectB, 30 days, 1e18);

        // Pay 2 ETH into project A.
        vm.deal(address(this), 5e18);
        _terminal.pay{value: 2e18}(projectA, JBConstants.NATIVE_TOKEN, 2e18, address(this), 0, "", "");

        // Record project B's balance before payout.
        uint256 balanceBefore = jbTerminalStore().balanceOf(address(_terminal), projectB, JBConstants.NATIVE_TOKEN);

        // Send payouts from project A.
        vm.prank(_projectOwner);
        uint256 amountPaidOut = IJBPayoutTerminal(address(_terminal))
            .sendPayoutsOf(projectA, JBConstants.NATIVE_TOKEN, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)), 0);

        // Record project B's balance after payout.
        uint256 balanceAfter = jbTerminalStore().balanceOf(address(_terminal), projectB, JBConstants.NATIVE_TOKEN);

        // Project B should receive the FULL payout amount (no fee deducted) because it's on the same terminal.
        assertEq(balanceAfter - balanceBefore, amountPaidOut, "Same-terminal payout should have no fee");
    }

    /// @notice When project A pays out to an EOA beneficiary, a fee IS deducted.
    function test_differentBeneficiary_payoutWithFee() public {
        address payable recipient = payable(makeAddr("recipient"));

        // Launch project A with a split that sends 100% to an EOA beneficiary.
        uint256 projectA = _launchProjectWithSplitToBeneficiary(recipient, 30 days, 1e18);

        // Pay 2 ETH into project A.
        vm.deal(address(this), 5e18);
        _terminal.pay{value: 2e18}(projectA, JBConstants.NATIVE_TOKEN, 2e18, address(this), 0, "", "");

        uint256 recipientBalanceBefore = recipient.balance;

        // Send payouts from project A.
        vm.prank(_projectOwner);
        IJBPayoutTerminal(address(_terminal))
            .sendPayoutsOf(projectA, JBConstants.NATIVE_TOKEN, 1e18, uint32(uint160(JBConstants.NATIVE_TOKEN)), 0);

        uint256 recipientBalanceAfter = recipient.balance;
        uint256 received = recipientBalanceAfter - recipientBalanceBefore;

        // The recipient should receive LESS than 1 ETH because a 2.5% fee is deducted.
        assertTrue(received < 1e18, "EOA payout should have fee deducted");
        assertTrue(received > 0, "Recipient should receive something");
    }

    // ───────────────────────────────────────────────────────────
    //  Helpers
    // ───────────────────────────────────────────────────────────

    function _launchProjectWithDuration(
        uint32 duration,
        uint112 weight,
        uint32 weightCutPercent
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = duration;
        rc[0].weight = weight;
        rc[0].weightCutPercent = weightCutPercent;
        rc[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rc[0].metadata = _defaultMetadata();
        rc[0].splitGroups = new JBSplitGroup[](0);
        rc[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rc,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _launchProjectWithPayoutLimit(uint32 duration, uint224 payoutLimit) internal returns (uint256) {
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = duration;
        rc[0].weight = 1000e18;
        rc[0].weightCutPercent = 0;
        rc[0].approvalHook = IJBRulesetApprovalHook(address(0));
        JBRulesetMetadata memory meta = _defaultMetadata();
        meta.ownerMustSendPayouts = true;
        rc[0].metadata = meta;
        rc[0].splitGroups = new JBSplitGroup[](0);

        // Set up payout limits.
        JBCurrencyAmount[] memory limits = new JBCurrencyAmount[](1);
        limits[0] = JBCurrencyAmount({amount: payoutLimit, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fal = new JBFundAccessLimitGroup[](1);
        fal[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: limits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rc[0].fundAccessLimitGroups = fal;

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rc,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _launchProjectWithSplitToProject(
        uint256 targetProjectId,
        uint32 duration,
        uint224 payoutLimit
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = duration;
        rc[0].weight = 1000e18;
        rc[0].weightCutPercent = 0;
        rc[0].approvalHook = IJBRulesetApprovalHook(address(0));
        JBRulesetMetadata memory meta = _defaultMetadata();
        meta.ownerMustSendPayouts = true;
        rc[0].metadata = meta;

        // Split 100% to target project.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT);
        // forge-lint: disable-next-line(unsafe-typecast)
        splits[0].projectId = uint64(targetProjectId);
        splits[0].preferAddToBalance = true;

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        rc[0].splitGroups = groups;

        JBCurrencyAmount[] memory limits = new JBCurrencyAmount[](1);
        limits[0] = JBCurrencyAmount({amount: payoutLimit, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fal = new JBFundAccessLimitGroup[](1);
        fal[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: limits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rc[0].fundAccessLimitGroups = fal;

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rc,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _launchProjectWithSplitToBeneficiary(
        address payable beneficiaryAddr,
        uint32 duration,
        uint224 payoutLimit
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = duration;
        rc[0].weight = 1000e18;
        rc[0].weightCutPercent = 0;
        rc[0].approvalHook = IJBRulesetApprovalHook(address(0));
        JBRulesetMetadata memory meta = _defaultMetadata();
        meta.ownerMustSendPayouts = true;
        rc[0].metadata = meta;

        // Split 100% to an EOA beneficiary (no project, no hook).
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT);
        splits[0].beneficiary = beneficiaryAddr;

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        rc[0].splitGroups = groups;

        JBCurrencyAmount[] memory limits = new JBCurrencyAmount[](1);
        limits[0] = JBCurrencyAmount({amount: payoutLimit, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fal = new JBFundAccessLimitGroup[](1);
        fal[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: limits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rc[0].fundAccessLimitGroups = fal;

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rc,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _launchSimpleProject() internal returns (uint256) {
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0].mustStartAtOrAfter = 0;
        rc[0].duration = 0;
        rc[0].weight = 1000e18;
        rc[0].weightCutPercent = 0;
        rc[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rc[0].metadata = _defaultMetadata();
        rc[0].splitGroups = new JBSplitGroup[](0);
        rc[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rc,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _defaultMetadata() internal pure returns (JBRulesetMetadata memory) {
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    function _defaultTerminalConfig() internal view returns (JBTerminalConfig[] memory) {
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: acc});
        return tc;
    }
}
