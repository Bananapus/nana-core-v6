// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBPermissionsData} from "./../structs/JBPermissionsData.sol";

/// @notice Stores permissions for all addresses and operators.
interface IJBPermissions {
    event OperatorPermissionsSet(
        address indexed operator,
        address indexed account,
        uint256 indexed projectId,
        uint8[] permissionIds,
        uint256 packed,
        address caller
    );

    /// @notice The project ID considered a wildcard, granting permissions to all projects.
    function WILDCARD_PROJECT_ID() external view returns (uint256);

    /// @notice Returns the packed permissions that an operator has for an account and project.
    /// @param operator The address of the operator.
    /// @param account The address of the account being operated on behalf of.
    /// @param projectId The project ID the permissions are scoped to. 0 is a wildcard for all projects.
    /// @return The packed permissions as a uint256 bitmap.
    function permissionsOf(address operator, address account, uint256 projectId) external view returns (uint256);

    /// @notice Checks if an operator has a specific permission for an account and project.
    /// @param operator The operator to check.
    /// @param account The account being operated on behalf of.
    /// @param projectId The project ID the permission is scoped to. 0 represents all projects.
    /// @param permissionId The permission ID to check for.
    /// @param includeRoot Whether to return true if the operator has the ROOT permission.
    /// @param includeWildcardProjectId Whether to return true if the operator has the permission on project ID 0.
    /// @return A flag indicating whether the operator has the specified permission.
    function hasPermission(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool includeRoot,
        bool includeWildcardProjectId
    )
        external
        view
        returns (bool);

    /// @notice Checks if an operator has all of the specified permissions for an account and project.
    /// @param operator The operator to check.
    /// @param account The account being operated on behalf of.
    /// @param projectId The project ID the permissions are scoped to. 0 represents all projects.
    /// @param permissionIds An array of permission IDs to check for.
    /// @param includeRoot Whether to return true if the operator has the ROOT permission.
    /// @param includeWildcardProjectId Whether to return true if the operator has the permissions on project ID 0.
    /// @return A flag indicating whether the operator has all of the specified permissions.
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
        returns (bool);

    /// @notice Sets permissions for an operator on behalf of an account.
    /// @param account The account setting its operator's permissions.
    /// @param permissionsData The data specifying the permissions the operator is being given.
    function setPermissionsFor(address account, JBPermissionsData calldata permissionsData) external;
}
