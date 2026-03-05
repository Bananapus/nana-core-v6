// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Provides the directory with access control checks for setting a project's controller and terminals.
interface IJBDirectoryAccessControl {
    /// @notice Returns whether a project's controller can currently be set.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether setting the controller is allowed.
    function setControllerAllowed(uint256 projectId) external view returns (bool);

    /// @notice Returns whether a project's terminals can currently be set.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether setting the terminals is allowed.
    function setTerminalsAllowed(uint256 projectId) external view returns (bool);
}
