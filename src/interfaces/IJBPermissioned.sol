// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPermissions} from "./IJBPermissions.sol";

/// @notice A contract that uses the permissions contract for access control.
interface IJBPermissioned {
    /// @notice The permissions contract used for access control.
    function PERMISSIONS() external view returns (IJBPermissions);
}
