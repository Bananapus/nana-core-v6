// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {JBPermissionsData} from "./structs/JBPermissionsData.sol";

/// @notice The permission system for Juicebox. Any address can authorize another address (an "operator") to perform
/// specific actions on its behalf — like queuing rulesets, distributing payouts, or managing terminals.
/// @dev Permissions are stored as a packed `uint256` bitmap: each of the 256 bits represents one permission's
/// on/off state. Project ID 0 is a wildcard that grants an operator access across all projects — use with caution.
/// @dev The ROOT permission (ID 1) implicitly grants every other permission for the scoped project.
contract JBPermissions is ERC2771Context, IJBPermissions {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBPermissions_CantSetRootPermissionForWildcardProject();
    error JBPermissions_NoZeroPermission();
    error JBPermissions_PermissionIdOutOfBounds(uint256 permissionId);
    error JBPermissions_Unauthorized(address account, address operator, uint256 projectId, uint256 permissionId);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The project ID that acts as a wildcard — granting the operator permissions across all projects owned
    /// by
    /// the account. Setting permissions for project ID 0 is powerful and should be done carefully.
    uint256 public constant override WILDCARD_PROJECT_ID = 0;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The packed permission bitmap that an account has granted to an operator for a specific project.
    /// @dev Each bit in the returned `uint256` corresponds to a permission ID (0–255). A `1` bit means that
    /// permission
    /// is granted. See `JBPermissionIds` for the meaning of each ID.
    /// @custom:param operator The address of the operator.
    /// @custom:param account The address of the account being operated on behalf of.
    /// @custom:param projectId The project ID the permissions are scoped to. An ID of 0 grants permissions across all
    /// projects.
    mapping(address operator => mapping(address account => mapping(uint256 projectId => uint256)))
        public
        override permissionsOf;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Grant or revoke permissions for an operator on a specific project.
    /// @dev Only the account itself can set permissions without restriction. A ROOT operator on a specific project can
    /// set non-ROOT permissions for that same project on the account's behalf, but cannot grant ROOT or set wildcard
    /// (project ID 0) permissions — preventing privilege escalation.
    /// @param account The account whose operator permissions are being configured.
    /// @param permissionsData The operator address, project scope, and permission IDs to set.
    function setPermissionsFor(address account, JBPermissionsData calldata permissionsData) external override {
        // Pack the permission IDs into a uint256.
        uint256 packed = _packedPermissions(permissionsData.permissionIds);

        // Make sure the 0 permission is not set.
        if (_includesPermission({permissions: packed, permissionId: 0})) revert JBPermissions_NoZeroPermission();

        // Cache the sender.
        address msgSender = _msgSender();

        // Enforce permissions. ROOT operators are allowed to set permissions so long as they are not setting another
        // ROOT permission or setting permissions for a wildcard project ID.
        if (
            msgSender != account
                && (_includesPermission({permissions: packed, permissionId: JBPermissionIds.ROOT})
                    || permissionsData.projectId == WILDCARD_PROJECT_ID
                    || !hasPermission({
                        operator: msgSender,
                        account: account,
                        projectId: permissionsData.projectId,
                        permissionId: JBPermissionIds.ROOT,
                        includeRoot: true,
                        includeWildcardProjectId: true
                    }))
        ) {
            revert JBPermissions_Unauthorized({
                account: account,
                operator: msgSender,
                projectId: permissionsData.projectId,
                permissionId: JBPermissionIds.ROOT
            });
        }

        // Store the new value.
        permissionsOf[permissionsData.operator][account][permissionsData.projectId] = packed;

        emit OperatorPermissionsSet({
            operator: permissionsData.operator,
            account: account,
            projectId: permissionsData.projectId,
            permissionIds: permissionsData.permissionIds,
            packed: packed,
            caller: msgSender
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Check whether an operator has *all* of the specified permissions for an account and project.
    /// @param operator The address to check permissions for.
    /// @param account The account that granted (or didn't grant) the permissions.
    /// @param projectId The project ID to check within. Pass 0 to check the wildcard scope directly.
    /// @param permissionIds The permission IDs that must all be present.
    /// @param includeRoot If `true`, returns `true` immediately when the operator has the ROOT permission.
    /// @param includeWildcardProjectId If `true`, also checks wildcard (project 0) permissions as a fallback.
    /// @return Whether the operator holds every requested permission.
    function hasPermissions(
        address operator,
        address account,
        uint256 projectId,
        uint256[] calldata permissionIds,
        bool includeRoot,
        bool includeWildcardProjectId
    )
        external
        view
        override
        returns (bool)
    {
        // If the ROOT permission is set and should be included, return true.
        if (
            includeRoot
                && (_includesPermission({
                        permissions: permissionsOf[operator][account][projectId], permissionId: JBPermissionIds.ROOT
                    })
                    || (includeWildcardProjectId
                        && _includesPermission({
                            permissions: permissionsOf[operator][account][WILDCARD_PROJECT_ID],
                            permissionId: JBPermissionIds.ROOT
                        })))
        ) {
            return true;
        }

        // Keep a reference to the permission item being checked.
        uint256 operatorAccountProjectPermissions = permissionsOf[operator][account][projectId];

        // Keep a reference to the wildcard project permissions.
        uint256 operatorAccountWildcardProjectPermissions =
            includeWildcardProjectId ? permissionsOf[operator][account][WILDCARD_PROJECT_ID] : 0;

        // Returns true for empty permission arrays by design (vacuous truth). An empty set of
        // required permissions is trivially satisfied. Callers should validate non-empty permission arrays if needed.
        for (uint256 i; i < permissionIds.length;) {
            // Set the permission being iterated on.
            uint256 permissionId = permissionIds[i];

            // Indexes above 255 don't exist
            if (permissionId > 255) revert JBPermissions_PermissionIdOutOfBounds(permissionId);

            // Check each permissionId
            if (
                !_includesPermission({permissions: operatorAccountProjectPermissions, permissionId: permissionId})
                    && !_includesPermission({
                        permissions: operatorAccountWildcardProjectPermissions, permissionId: permissionId
                    })
            ) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Check whether an operator has a single permission for an account and project.
    /// @param operator The address to check.
    /// @param account The account that granted (or didn't grant) the permission.
    /// @param projectId The project ID to check within. Pass 0 to check the wildcard scope directly.
    /// @param permissionId The specific permission ID to look for (0–255).
    /// @param includeRoot If `true`, returns `true` immediately when the operator has the ROOT permission.
    /// @param includeWildcardProjectId If `true`, also checks wildcard (project 0) permissions as a fallback.
    /// @return Whether the operator holds the requested permission.
    function hasPermission(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool includeRoot,
        bool includeWildcardProjectId
    )
        public
        view
        override
        returns (bool)
    {
        // Indexes above 255 don't exist
        if (permissionId > 255) revert JBPermissions_PermissionIdOutOfBounds(permissionId);

        // Cache both permission slots upfront to avoid redundant storage reads.
        uint256 projectPermissions = permissionsOf[operator][account][projectId];
        uint256 wildcardPermissions =
            includeWildcardProjectId ? permissionsOf[operator][account][WILDCARD_PROJECT_ID] : 0;

        // If the ROOT permission is set and should be included, return true.
        if (
            includeRoot
                && (_includesPermission({permissions: projectPermissions, permissionId: JBPermissionIds.ROOT})
                    || _includesPermission({permissions: wildcardPermissions, permissionId: JBPermissionIds.ROOT}))
        ) {
            return true;
        }

        // Otherwise return the t/f flag of the specified id.
        return _includesPermission({permissions: projectPermissions, permissionId: permissionId})
            || _includesPermission({permissions: wildcardPermissions, permissionId: permissionId});
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Checks if a permission is included in a packed permissions data.
    /// @param permissions The packed permissions to check.
    /// @param permissionId The ID of the permission to check for.
    /// @return A flag indicating whether the permission is included.
    function _includesPermission(uint256 permissions, uint256 permissionId) internal pure returns (bool) {
        return ((permissions >> permissionId) & 1) == 1;
    }

    /// @notice Converts an array of permission IDs to a packed `uint256`.
    /// @param permissionIds The IDs of the permissions to pack.
    /// @return packed The packed value.
    function _packedPermissions(uint8[] calldata permissionIds) internal pure returns (uint256 packed) {
        for (uint256 i; i < permissionIds.length;) {
            // Set the permission being iterated on.
            uint256 permissionId = permissionIds[i];

            // Turn on the bit at the ID.
            // forge-lint: disable-next-line(incorrect-shift)
            packed |= 1 << permissionId;
            unchecked {
                ++i;
            }
        }
    }
}
