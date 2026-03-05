// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBSplitsSetup} from "./JBSplitsSetup.sol";

contract TestSelfManagedSplitGroups_Local is JBSplitsSetup {
    address payable _bene = payable(makeAddr("beneficiary"));
    uint64 _projectId = 1;
    uint256 _rulesetId = block.timestamp;

    function setUp() public {
        super.splitsSetup();
    }

    // ───────────────────────────────── Helpers ─────────────────────────────────

    /// @dev Build a single-split group for the given groupId.
    function _makeSplitGroup(
        uint256 groupId,
        uint32 percent,
        address payable beneficiary
    )
        internal
        pure
        returns (JBSplitGroup[] memory groups)
    {
        groups = new JBSplitGroup[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: percent,
            projectId: 0,
            beneficiary: beneficiary,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});
    }

    /// @dev Mock directory to return `controller` for `_projectId`.
    function _mockController(address controller) internal {
        bytes memory call_ = abi.encodeCall(IJBDirectory.controllerOf, (uint256(_projectId)));
        bytes memory ret = abi.encode(controller);
        mockExpect(address(directory), call_, ret);
    }

    // ──────────────────── Self-managed namespace: happy paths ──────────────────

    function test_CallerCanSetSplitsInOwnGroupNamespace() external {
        // Any contract can set splits when groupId's lower 160 bits == msg.sender.
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT / 2, _bene);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory result = _splits.splitsOf(_projectId, _rulesetId, groupId);
        assertEq(result.length, 1);
        assertEq(result[0].beneficiary, _bene);
        assertEq(result[0].percent, JBConstants.SPLITS_TOTAL_PERCENT / 2);
    }

    function test_CallerCanSetSplitsWithUpperBitsSubcategory() external {
        // The upper 96 bits are free for sub-categorization.
        address caller = makeAddr("hookContract");
        uint256 subcategory = 42;
        uint256 groupId = (subcategory << 160) | uint256(uint160(caller));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT, _bene);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory result = _splits.splitsOf(_projectId, _rulesetId, groupId);
        assertEq(result.length, 1);
        assertEq(result[0].beneficiary, _bene);
    }

    function test_DifferentSubcategoriesAreIndependent() external {
        // Two different subcategories for the same caller store independently.
        address caller = makeAddr("hookContract");
        uint256 groupIdA = (1 << 160) | uint256(uint160(caller));
        uint256 groupIdB = (2 << 160) | uint256(uint160(caller));

        address payable beneA = payable(makeAddr("beneA"));
        address payable beneB = payable(makeAddr("beneB"));

        JBSplitGroup[] memory groupsA = _makeSplitGroup(groupIdA, JBConstants.SPLITS_TOTAL_PERCENT / 2, beneA);
        JBSplitGroup[] memory groupsB = _makeSplitGroup(groupIdB, JBConstants.SPLITS_TOTAL_PERCENT / 3, beneB);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groupsA);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groupsB);

        JBSplit[] memory resultA = _splits.splitsOf(_projectId, _rulesetId, groupIdA);
        JBSplit[] memory resultB = _splits.splitsOf(_projectId, _rulesetId, groupIdB);

        assertEq(resultA.length, 1);
        assertEq(resultA[0].beneficiary, beneA);
        assertEq(resultA[0].percent, JBConstants.SPLITS_TOTAL_PERCENT / 2);

        assertEq(resultB.length, 1);
        assertEq(resultB[0].beneficiary, beneB);
        assertEq(resultB[0].percent, JBConstants.SPLITS_TOTAL_PERCENT / 3);
    }

    function test_CallerCanSetMultipleSplitsInOwnGroup() external {
        // Multiple splits in the same self-managed group.
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        address payable bene1 = payable(makeAddr("bene1"));
        address payable bene2 = payable(makeAddr("bene2"));

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        JBSplit[] memory splits = new JBSplit[](2);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 2,
            projectId: 0,
            beneficiary: bene1,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        splits[1] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 2,
            projectId: 0,
            beneficiary: bene2,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory result = _splits.splitsOf(_projectId, _rulesetId, groupId);
        assertEq(result.length, 2);
        assertEq(result[0].beneficiary, bene1);
        assertEq(result[1].beneficiary, bene2);
    }

    function test_CallerCanOverwriteOwnSplits() external {
        // Caller can overwrite their own splits.
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        address payable beneOld = payable(makeAddr("beneOld"));
        address payable beneNew = payable(makeAddr("beneNew"));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT / 2, beneOld);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        // Overwrite with new beneficiary.
        groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT / 3, beneNew);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory result = _splits.splitsOf(_projectId, _rulesetId, groupId);
        assertEq(result.length, 1);
        assertEq(result[0].beneficiary, beneNew);
        assertEq(result[0].percent, JBConstants.SPLITS_TOTAL_PERCENT / 3);
    }

    function test_SelfManagedSplitsEmitSetSplitEvent() external {
        // Setting self-managed splits emits SetSplit with correct caller.
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT, _bene);

        vm.expectEmit();
        emit IJBSplits.SetSplit(_projectId, _rulesetId, groupId, groups[0].splits[0], caller);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    function test_SelfManagedSplitsWorkAcrossRulesets() external {
        // Caller can set splits in the same group but different rulesets.
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        uint256 rulesetA = 100;
        uint256 rulesetB = 200;

        address payable beneA = payable(makeAddr("beneA"));
        address payable beneB = payable(makeAddr("beneB"));

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, rulesetA, _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT, beneA));

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, rulesetB, _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT, beneB));

        JBSplit[] memory resultA = _splits.splitsOf(_projectId, rulesetA, groupId);
        JBSplit[] memory resultB = _splits.splitsOf(_projectId, rulesetB, groupId);

        assertEq(resultA[0].beneficiary, beneA);
        assertEq(resultB[0].beneficiary, beneB);
    }

    // ────────────────────── Self-managed: validation still applies ─────────────

    function test_SelfManagedSplitsRevertOnZeroPercent() external {
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: 0,
            projectId: 0,
            beneficiary: _bene,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        vm.prank(caller);
        vm.expectRevert(JBSplits.JBSplits_ZeroSplitPercent.selector);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    function test_SelfManagedSplitsRevertOnExcessPercent() external {
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        JBSplit[] memory splits = new JBSplit[](2);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: _bene,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        splits[1] = JBSplit({
            preferAddToBalance: false,
            percent: 1,
            projectId: 0,
            beneficiary: _bene,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        vm.prank(caller);
        vm.expectRevert(JBSplits.JBSplits_TotalPercentExceeds100.selector);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    function test_SelfManagedSplitsEnforceLocks() external {
        // Locked splits in a self-managed group cannot be removed.
        address caller = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(caller));

        // Set a locked split.
        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 2,
            projectId: 0,
            beneficiary: _bene,
            lockedUntil: uint48(block.timestamp + 100),
            hook: IJBSplitHook(address(0))
        });
        groups[0] = JBSplitGroup({groupId: groupId, splits: splits});

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        // Try to replace with a different split (omitting the locked one).
        JBSplit[] memory newSplits = new JBSplit[](1);
        newSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT / 2,
            projectId: 0,
            beneficiary: payable(makeAddr("otherBene")),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        groups[0] = JBSplitGroup({groupId: groupId, splits: newSplits});

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBSplits.JBSplits_PreviousLockedSplitsNotIncluded.selector, _projectId, _rulesetId
            )
        );
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    // ──────────────────────── Authorization: revert cases ──────────────────────

    function test_NonOwnerCannotSetSplitsInOtherNamespace() external {
        // A caller whose address doesn't match the groupId's lower 160 bits is rejected (unless controller).
        address caller = makeAddr("attacker");
        address victim = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(victim));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT / 2, _bene);

        // Mock: controller is someone else entirely.
        _mockController(makeAddr("realController"));

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(JBControlled.JBControlled_ControllerUnauthorized.selector, makeAddr("realController"))
        );
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    function test_NonOwnerCannotSetSplitsWithSubcategory() external {
        // Even with upper bits, the lower 160 bits must match msg.sender.
        address caller = makeAddr("attacker");
        address victim = makeAddr("hookContract");
        uint256 groupId = (99 << 160) | uint256(uint160(victim));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT, _bene);

        _mockController(makeAddr("realController"));

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(JBControlled.JBControlled_ControllerUnauthorized.selector, makeAddr("realController"))
        );
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    // ───────────────────── Controller can still set any group ──────────────────

    function test_ControllerCanSetSplitsInAnyGroup() external {
        // The controller can set splits in a group that "belongs" to another address.
        address controller = makeAddr("controller");
        address otherContract = makeAddr("hookContract");
        uint256 groupId = uint256(uint160(otherContract));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT, _bene);

        _mockController(controller);

        vm.prank(controller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory result = _splits.splitsOf(_projectId, _rulesetId, groupId);
        assertEq(result.length, 1);
        assertEq(result[0].beneficiary, _bene);
    }

    // ─────────────────── Mixed groups in one call ─────────────────────────────

    function test_MixedSelfManagedAndControllerGroupsInOneCall() external {
        // A single setSplitGroupsOf call with one self-managed group and one controller-gated group.
        address caller = makeAddr("hookContract");
        uint256 selfGroupId = uint256(uint160(caller));
        uint256 otherGroupId = 0;

        // Mock: caller IS the controller.
        _mockController(caller);

        JBSplitGroup[] memory groups = new JBSplitGroup[](2);
        JBSplit[] memory selfSplits = new JBSplit[](1);
        selfSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: payable(makeAddr("selfBene")),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplit[] memory otherSplits = new JBSplit[](1);
        otherSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: payable(makeAddr("otherBene")),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        groups[0] = JBSplitGroup({groupId: selfGroupId, splits: selfSplits});
        groups[1] = JBSplitGroup({groupId: otherGroupId, splits: otherSplits});

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory resultSelf = _splits.splitsOf(_projectId, _rulesetId, selfGroupId);
        JBSplit[] memory resultOther = _splits.splitsOf(_projectId, _rulesetId, otherGroupId);

        assertEq(resultSelf[0].beneficiary, payable(makeAddr("selfBene")));
        assertEq(resultOther[0].beneficiary, payable(makeAddr("otherBene")));
    }

    function test_MixedCallRevertsIfNonControllerSetsOtherGroup() external {
        // A call with one self-managed group (ok) and one non-owned group (reverts) in the same call.
        address caller = makeAddr("hookContract");
        uint256 selfGroupId = uint256(uint160(caller));
        uint256 otherGroupId = 0;

        _mockController(makeAddr("realController"));

        JBSplitGroup[] memory groups = new JBSplitGroup[](2);
        JBSplit[] memory selfSplits = new JBSplit[](1);
        selfSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: _bene,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplit[] memory otherSplits = new JBSplit[](1);
        otherSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: _bene,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // Self-managed group first (passes), then non-owned group (reverts).
        groups[0] = JBSplitGroup({groupId: selfGroupId, splits: selfSplits});
        groups[1] = JBSplitGroup({groupId: otherGroupId, splits: otherSplits});

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBControlled.JBControlled_ControllerUnauthorized.selector, makeAddr("realController")
            )
        );
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }

    // ────────────────────── Fuzz tests ─────────────────────────────────────────

    function testFuzz_AnyAddressCanSetOwnNamespace(address caller, uint96 upperBits, uint32 percent) external {
        vm.assume(caller != address(0));
        vm.assume(percent > 0 && percent <= JBConstants.SPLITS_TOTAL_PERCENT);

        uint256 groupId = (uint256(upperBits) << 160) | uint256(uint160(caller));

        JBSplitGroup[] memory groups = _makeSplitGroup(groupId, percent, _bene);

        vm.prank(caller);
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);

        JBSplit[] memory result = _splits.splitsOf(_projectId, _rulesetId, groupId);
        assertEq(result.length, 1);
        assertEq(result[0].percent, percent);
    }

    function testFuzz_NonOwnerRevertsForMismatchedNamespace(
        address caller,
        address groupOwner,
        address controller
    )
        external
    {
        vm.assume(caller != address(0) && groupOwner != address(0) && controller != address(0));
        vm.assume(caller != groupOwner);
        vm.assume(caller != controller);

        uint256 groupId = uint256(uint160(groupOwner));

        JBSplitGroup[] memory groups =
            _makeSplitGroup(groupId, JBConstants.SPLITS_TOTAL_PERCENT / 2, _bene);

        _mockController(controller);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(JBControlled.JBControlled_ControllerUnauthorized.selector, controller)
        );
        _splits.setSplitGroupsOf(_projectId, _rulesetId, groups);
    }
}
