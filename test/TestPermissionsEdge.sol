// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

/// @notice Defense-in-depth validation of JBPermissions ROOT escalation prevention.
/// Verifies that ROOT operators cannot forward ROOT, cannot set wildcard permissions,
/// and that the permission bitmap maintains integrity through set/get cycles.
contract TestPermissionsEdge_Local is TestBaseWorkflow {
    JBPermissions private _permissions;

    address private _account;
    address private _operator;
    address private _thirdParty;

    uint64 constant PROJECT_ID = 5;

    function setUp() public override {
        super.setUp();
        _permissions = jbPermissions();
        _account = makeAddr("account");
        _operator = makeAddr("operator");
        _thirdParty = makeAddr("thirdParty");
    }

    // ───────────────────── ROOT cannot be forwarded ─────────────────────

    /// @notice An operator with ROOT on project N cannot set ROOT for another operator.
    function test_rootCannotBeForwarded() external {
        // Give operator ROOT permission on PROJECT_ID.
        uint8[] memory rootPermissions = new uint8[](1);
        rootPermissions[0] = JBPermissionIds.ROOT;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: rootPermissions})
        );

        // Verify operator has ROOT.
        assertTrue(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, JBPermissionIds.ROOT, false, false),
            "Operator should have ROOT"
        );

        // Now operator tries to forward ROOT to thirdParty.
        uint8[] memory rootForThird = new uint8[](1);
        rootForThird[0] = JBPermissionIds.ROOT;

        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissions.JBPermissions_Unauthorized.selector, _account, _operator, PROJECT_ID, JBPermissionIds.ROOT
            )
        );
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _thirdParty, projectId: PROJECT_ID, permissionIds: rootForThird})
        );
    }

    // ───────────────────── Wildcard cannot be set by operator ─────────────────────

    /// @notice An operator with ROOT cannot set permissions for the wildcard project ID.
    function test_wildcardCannotBeSetByOperator() external {
        // Give operator ROOT on PROJECT_ID.
        uint8[] memory rootPermissions = new uint8[](1);
        rootPermissions[0] = JBPermissionIds.ROOT;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: rootPermissions})
        );

        // Operator tries to set permissions on wildcard (project 0).
        uint8[] memory somePermission = new uint8[](1);
        somePermission[0] = 5; // Some non-ROOT permission.

        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissions.JBPermissions_Unauthorized.selector, _account, _operator, 0, JBPermissionIds.ROOT
            )
        );
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _thirdParty, projectId: 0, permissionIds: somePermission})
        );
    }

    // ───────────────────── ROOT grants all permissions ─────────────────────

    /// @notice Fuzz: ROOT holder always has permission for any ID (when includeRoot=true).
    function testFuzz_rootGrantsAllPermissions(uint8 permissionId) external {
        vm.assume(permissionId > 0); // 0 is reserved.

        // Give operator ROOT.
        uint8[] memory rootPermissions = new uint8[](1);
        rootPermissions[0] = JBPermissionIds.ROOT;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: rootPermissions})
        );

        // Check any permissionId with includeRoot=true.
        assertTrue(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, permissionId, true, false),
            "ROOT should grant all permissions when includeRoot=true"
        );

        // Without includeRoot, only ROOT bit should be set.
        if (permissionId != JBPermissionIds.ROOT) {
            assertFalse(
                _permissions.hasPermission(_operator, _account, PROJECT_ID, permissionId, false, false),
                "Without includeRoot, only ROOT bit should match"
            );
        }
    }

    // ───────────────────── Permission ID boundaries ─────────────────────

    /// @notice Permission 0 cannot be set.
    function test_permissionId0_cannotBeSet() external {
        uint8[] memory zeroPermission = new uint8[](1);
        zeroPermission[0] = 0;

        vm.prank(_account);
        vm.expectRevert(JBPermissions.JBPermissions_NoZeroPermission.selector);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: zeroPermission})
        );
    }

    /// @notice Permission 255 (highest) works correctly.
    function test_permissionId255_works() external {
        uint8[] memory maxPermission = new uint8[](1);
        maxPermission[0] = 255;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: maxPermission})
        );

        assertTrue(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 255, false, false),
            "Permission 255 should work"
        );

        // Permission 254 should NOT be set.
        assertFalse(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 254, false, false),
            "Permission 254 should not be set"
        );
    }

    // ───────────────────── Replacement not additive ─────────────────────

    /// @notice Setting new permissions replaces old ones (old permissions lost).
    function test_replacementNotAdditive() external {
        // Set permission 5.
        uint8[] memory perm5 = new uint8[](1);
        perm5[0] = 5;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account, JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: perm5})
        );

        assertTrue(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 5, false, false), "Should have perm 5"
        );

        // Now set permission 10 — should REPLACE, not add to perm 5.
        uint8[] memory perm10 = new uint8[](1);
        perm10[0] = 10;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account, JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: perm10})
        );

        assertTrue(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 10, false, false), "Should have perm 10"
        );
        assertFalse(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 5, false, false),
            "Perm 5 should be LOST after replacement"
        );
    }

    // ───────────────────── Wildcard overrides project-specific ─────────────────────

    /// @notice Wildcard permission grants access to all projects.
    function test_wildcardOverridesProjectSpecific() external {
        // Set permission 5 on wildcard project (0).
        uint8[] memory perm5 = new uint8[](1);
        perm5[0] = 5;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account, JBPermissionsData({operator: _operator, projectId: 0, permissionIds: perm5})
        );

        // Check with includeWildcardProjectId=true on any project.
        assertTrue(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 5, false, true),
            "Wildcard should grant permission on any project"
        );

        // Check without wildcard — should not have permission on specific project.
        assertFalse(
            _permissions.hasPermission(_operator, _account, PROJECT_ID, 5, false, false),
            "Without wildcard flag, specific project check fails"
        );
    }

    // ───────────────────── Bit integrity fuzz ─────────────────────

    /// @notice Fuzz: packed permissions maintain bit integrity through set/get cycle.
    function testFuzz_setPermissions_bitIntegrity(uint256 bitmap) external {
        // Build permission ID array from bitmap.
        // Count set bits (excluding bit 0).
        uint256 count;
        for (uint256 i = 1; i < 256; i++) {
            if ((bitmap >> i) & 1 == 1) count++;
        }

        if (count == 0) return; // Skip empty bitmaps.

        uint8[] memory ids = new uint8[](count);
        uint256 idx;
        for (uint256 i = 1; i < 256; i++) {
            if ((bitmap >> i) & 1 == 1) {
                ids[idx] = uint8(i);
                idx++;
            }
        }

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account, JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: ids})
        );

        // Verify packed value matches.
        uint256 packed = _permissions.permissionsOf(_operator, _account, PROJECT_ID);

        // Check each bit.
        for (uint256 i = 1; i < 256; i++) {
            bool expected = (bitmap >> i) & 1 == 1;
            bool actual = ((packed >> i) & 1) == 1;
            assertEq(actual, expected, string.concat("Bit mismatch at position ", vm.toString(i)));
        }

        // Bit 0 should never be set.
        assertFalse(((packed >> 0) & 1) == 1, "Bit 0 should never be set");
    }

    // ───────────────────── ROOT operator can set non-ROOT permissions ─────────────────────

    /// @notice ROOT operator CAN set non-ROOT permissions for others on the same project.
    function test_rootOperator_canSetNonRootPermissions() external {
        // Give operator ROOT.
        uint8[] memory rootPermissions = new uint8[](1);
        rootPermissions[0] = JBPermissionIds.ROOT;

        vm.prank(_account);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _operator, projectId: PROJECT_ID, permissionIds: rootPermissions})
        );

        // Operator sets non-ROOT permission for thirdParty — should succeed.
        uint8[] memory nonRootPerm = new uint8[](1);
        nonRootPerm[0] = 5;

        vm.prank(_operator);
        _permissions.setPermissionsFor(
            _account,
            JBPermissionsData({operator: _thirdParty, projectId: PROJECT_ID, permissionIds: nonRootPerm})
        );

        assertTrue(
            _permissions.hasPermission(_thirdParty, _account, PROJECT_ID, 5, false, false),
            "ROOT operator should be able to delegate non-ROOT permissions"
        );
    }
}
