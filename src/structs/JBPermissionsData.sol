// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member operator The address to give permissions to.
/// @custom:member projectId The ID of the project to give the operator permissions for. Operators only have
/// permissions under this project's scope. An ID of 0 is a wildcard, which gives an operator permissions across all
/// projects.
/// @custom:member permissionIds The IDs of the permissions to grant. See the `JBPermissionIds` library.
struct JBPermissionsData {
    address operator;
    uint64 projectId;
    uint8[] permissionIds;
}
