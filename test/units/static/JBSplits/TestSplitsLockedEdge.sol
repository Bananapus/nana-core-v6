// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBSplitsSetup} from "./JBSplitsSetup.sol";

/// @notice Edge case tests for JBSplits lock enforcement.
/// Key finding: locks only enforce within the SAME rulesetId. A project owner
/// can bypass a locked split by setting splits under a different rulesetId.
contract TestSplitsLockedEdge_Local is JBSplitsSetup {
    uint256 constant PROJECT_ID = 1;
    uint256 constant RULESET_ID_A = 100;
    uint256 constant RULESET_ID_B = 200;
    uint256 constant GROUP_ID = 1;
    address constant BENEFICIARY = address(0xBEEF);

    IJBSplits public splits;

    function setUp() public {
        super.splitsSetup();
        splits = IJBSplits(address(_splits));

        // Mock controllerOf to return this contract.
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (PROJECT_ID)), abi.encode(address(this))
        );
    }

    // Helper to create a split with specified parameters.
    function _makeSplit(
        uint32 percent,
        address beneficiary_,
        uint48 lockedUntil
    )
        internal
        pure
        returns (JBSplit memory)
    {
        return JBSplit({
            percent: percent,
            projectId: 0,
            beneficiary: payable(beneficiary_),
            preferAddToBalance: false,
            lockedUntil: lockedUntil,
            hook: IJBSplitHook(address(0))
        });
    }

    // ───────────────────── Lock enforcement within same ruleset ─────────────────────

    /// @notice Removing a locked split within the same rulesetId should revert.
    function test_lockEnforcement_withinSameRuleset() external {
        // Set a locked split.
        JBSplit[] memory initialSplits = new JBSplit[](1);
        initialSplits[0] = _makeSplit(500_000_000, BENEFICIARY, uint48(block.timestamp + 365 days));

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: initialSplits});

        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        // Try to remove the locked split.
        JBSplit[] memory newSplits = new JBSplit[](1);
        newSplits[0] = _makeSplit(500_000_000, address(0xDEAD), 0); // Different beneficiary.

        JBSplitGroup[] memory newGroups = new JBSplitGroup[](1);
        newGroups[0] = JBSplitGroup({groupId: GROUP_ID, splits: newSplits});

        vm.expectRevert(JBSplits.JBSplits_PreviousLockedSplitsNotIncluded.selector);
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, newGroups);
    }

    // ───────────────────── Lock DOES NOT carry across rulesets ─────────────────────

    /// @notice DESIGN ISSUE: Locked splits in rulesetId A don't constrain rulesetId B.
    /// A project owner can bypass a lock by queuing a new ruleset without the split.
    function test_lockEnforcement_acrossRulesets() external {
        // Set a locked split in rulesetId A.
        JBSplit[] memory initialSplits = new JBSplit[](1);
        initialSplits[0] = _makeSplit(500_000_000, BENEFICIARY, uint48(block.timestamp + 365 days));

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: initialSplits});

        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        // Set completely different splits in rulesetId B — this SUCCEEDS even though
        // the locked split from rulesetId A is not included.
        JBSplit[] memory newSplits = new JBSplit[](1);
        newSplits[0] = _makeSplit(500_000_000, address(0xDEAD), 0); // No lock, different beneficiary.

        JBSplitGroup[] memory newGroups = new JBSplitGroup[](1);
        newGroups[0] = JBSplitGroup({groupId: GROUP_ID, splits: newSplits});

        // This should succeed — locks don't carry across rulesets.
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_B, newGroups);

        // Verify the new ruleset has different splits.
        JBSplit[] memory rulesetsB = splits.splitsOf(PROJECT_ID, RULESET_ID_B, GROUP_ID);
        assertEq(rulesetsB.length, 1, "Ruleset B should have splits");
        assertEq(rulesetsB[0].beneficiary, address(0xDEAD), "Locked split bypassed via new rulesetId");
    }

    // ───────────────────── Lock extension allowed ─────────────────────

    /// @notice Extending lockedUntil to a later time should succeed.
    function test_lockExtension_allowed() external {
        uint48 originalLock = uint48(block.timestamp + 180 days);
        uint48 extendedLock = uint48(block.timestamp + 365 days);

        JBSplit[] memory initialSplits = new JBSplit[](1);
        initialSplits[0] = _makeSplit(500_000_000, BENEFICIARY, originalLock);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: initialSplits});
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        // Extend the lock.
        JBSplit[] memory extendedSplits = new JBSplit[](1);
        extendedSplits[0] = _makeSplit(500_000_000, BENEFICIARY, extendedLock);

        JBSplitGroup[] memory extendedGroups = new JBSplitGroup[](1);
        extendedGroups[0] = JBSplitGroup({groupId: GROUP_ID, splits: extendedSplits});

        // Should succeed — lock extension is allowed.
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, extendedGroups);

        JBSplit[] memory result = splits.splitsOf(PROJECT_ID, RULESET_ID_A, GROUP_ID);
        assertEq(result[0].lockedUntil, extendedLock, "Lock should be extended");
    }

    // ───────────────────── Lock reduction blocked ─────────────────────

    /// @notice Reducing lockedUntil (while still locked) should revert.
    function test_lockReduction_blocked() external {
        uint48 originalLock = uint48(block.timestamp + 365 days);
        uint48 reducedLock = uint48(block.timestamp + 90 days);

        JBSplit[] memory initialSplits = new JBSplit[](1);
        initialSplits[0] = _makeSplit(500_000_000, BENEFICIARY, originalLock);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: initialSplits});
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        // Try to reduce the lock — should fail.
        JBSplit[] memory reducedSplits = new JBSplit[](1);
        reducedSplits[0] = _makeSplit(500_000_000, BENEFICIARY, reducedLock);

        JBSplitGroup[] memory reducedGroups = new JBSplitGroup[](1);
        reducedGroups[0] = JBSplitGroup({groupId: GROUP_ID, splits: reducedSplits});

        vm.expectRevert(JBSplits.JBSplits_PreviousLockedSplitsNotIncluded.selector);
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, reducedGroups);
    }

    // ───────────────────── Lock expired allows removal ─────────────────────

    /// @notice After lockedUntil passes, split can be removed.
    function test_lockExpired_canRemove() external {
        uint48 lockTime = uint48(block.timestamp + 30 days);

        JBSplit[] memory initialSplits = new JBSplit[](1);
        initialSplits[0] = _makeSplit(500_000_000, BENEFICIARY, lockTime);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: initialSplits});
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        // Warp past lock expiry.
        vm.warp(lockTime + 1);

        // Now remove the split — should succeed.
        JBSplit[] memory newSplits = new JBSplit[](1);
        newSplits[0] = _makeSplit(500_000_000, address(0xDEAD), 0);

        JBSplitGroup[] memory newGroups = new JBSplitGroup[](1);
        newGroups[0] = JBSplitGroup({groupId: GROUP_ID, splits: newSplits});

        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, newGroups);

        JBSplit[] memory result = splits.splitsOf(PROJECT_ID, RULESET_ID_A, GROUP_ID);
        assertEq(result[0].beneficiary, address(0xDEAD), "Expired lock allows removal");
    }

    // ───────────────────── Percent validation ─────────────────────

    /// @notice Total percent > SPLITS_TOTAL_PERCENT should revert.
    function test_percentExceeds100_reverts() external {
        JBSplit[] memory splitArray = new JBSplit[](2);
        splitArray[0] = _makeSplit(600_000_000, BENEFICIARY, 0); // 60%
        splitArray[1] = _makeSplit(500_000_000, address(0xDEAD), 0); // 50% → total 110%

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: splitArray});

        vm.expectRevert(JBSplits.JBSplits_TotalPercentExceeds100.selector);
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);
    }

    /// @notice Any split with percent=0 should revert.
    function test_zeroPercent_reverts() external {
        JBSplit[] memory splitArray = new JBSplit[](1);
        splitArray[0] = _makeSplit(0, BENEFICIARY, 0);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: splitArray});

        vm.expectRevert(JBSplits.JBSplits_ZeroSplitPercent.selector);
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);
    }

    // ───────────────────── Hook and beneficiary edge cases ─────────────────────

    /// @notice Arbitrary address as hook is accepted (no interface check).
    function test_hookAddress_notValidated() external {
        JBSplit[] memory splitArray = new JBSplit[](1);
        splitArray[0] = JBSplit({
            percent: 500_000_000,
            projectId: 0,
            beneficiary: payable(BENEFICIARY),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0x1234)) // Arbitrary address — no interface validation.
        });

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: splitArray});

        // Should succeed — no ERC165 or interface check.
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        JBSplit[] memory result = splits.splitsOf(PROJECT_ID, RULESET_ID_A, GROUP_ID);
        assertEq(address(result[0].hook), address(0x1234), "Arbitrary hook address accepted");
    }

    /// @notice address(0) beneficiary is valid (potential footgun).
    function test_beneficiaryZero_accepted() external {
        JBSplit[] memory splitArray = new JBSplit[](1);
        splitArray[0] = _makeSplit(500_000_000, address(0), 0);

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: GROUP_ID, splits: splitArray});

        // Should succeed — no zero-address check.
        splits.setSplitGroupsOf(PROJECT_ID, RULESET_ID_A, groups);

        JBSplit[] memory result = splits.splitsOf(PROJECT_ID, RULESET_ID_A, GROUP_ID);
        assertEq(result[0].beneficiary, address(0), "Zero beneficiary accepted (footgun)");
    }
}
