// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {IJBPermissioned} from "./../interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "./../interfaces/IJBPermissions.sol";

/// @notice Base contract that provides permission-checking helpers. Contracts that inherit this can require that the
/// caller either *is* the account or has been granted a specific permission by that account (via `JBPermissions`).
/// @dev Used by `JBController`, `JBMultiTerminal`, `JBDirectory`, and others to enforce operator authorization.
abstract contract JBPermissioned is Context, IJBPermissioned {
    //*********************************************************************//
    // --------------------------- custom errors -------------------------- //
    //*********************************************************************//

    error JBPermissioned_Unauthorized(address account, address sender, uint256 projectId, uint256 permissionId);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice A contract storing permissions.
    IJBPermissions public immutable override PERMISSIONS;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permissions A contract storing permissions.
    constructor(IJBPermissions permissions) {
        PERMISSIONS = permissions;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Check whether an operator is the account or has the relevant permission.
    /// @param operator The address to check.
    /// @param account The account to allow.
    /// @param projectId The project ID to check the permission under.
    /// @param permissionId The required permission ID. The operator must have this permission within the specified
    /// project ID.
    /// @return Whether the operator is the account or has the permission.
    function _hasPermissionFrom(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId
    )
        internal
        view
        returns (bool)
    {
        return operator == account
            || PERMISSIONS.hasPermission({
                operator: operator,
                account: account,
                projectId: projectId,
                permissionId: permissionId,
                includeRoot: true,
                includeWildcardProjectId: true
            });
    }

    /// @notice Require the message sender to be the account or have the relevant permission.
    /// @param account The account to allow.
    /// @param projectId The project ID to check the permission under.
    /// @param permissionId The required permission ID. The operator must have this permission within the specified
    /// project ID.
    function _requirePermissionFrom(address account, uint256 projectId, uint256 permissionId) internal view {
        address sender = _msgSender();
        if (
            sender != account
                && !PERMISSIONS.hasPermission({
                    operator: sender,
                    account: account,
                    projectId: projectId,
                    permissionId: permissionId,
                    includeRoot: true,
                    includeWildcardProjectId: true
                })
        ) revert JBPermissioned_Unauthorized(account, sender, projectId, permissionId);
    }

    /// @notice If the 'alsoGrantAccessIf' condition is truthy, proceed. Otherwise, require the message sender to be the
    /// account or
    /// have the relevant permission.
    /// @param account The account to allow.
    /// @param projectId The project ID to check the permission under.
    /// @param permissionId The required permission ID. The operator must have this permission within the specified
    /// project ID.
    /// @param alsoGrantAccessIf An override condition which will allow access regardless of permissions.
    function _requirePermissionAllowingOverrideFrom(
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool alsoGrantAccessIf
    )
        internal
        view
    {
        if (alsoGrantAccessIf) return;
        _requirePermissionFrom({account: account, projectId: projectId, permissionId: permissionId});
    }
}
