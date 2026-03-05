// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A registry of metadata URIs for projects.
interface IJBProjectUriRegistry {
    /// @notice Returns the metadata URI for a project.
    /// @param projectId The ID of the project to get the metadata URI of.
    /// @return The project's metadata URI.
    function uriOf(uint256 projectId) external view returns (string memory);

    /// @notice Sets the metadata URI for a project.
    /// @param projectId The ID of the project to set the metadata URI of.
    /// @param uri The metadata URI to set.
    function setUriOf(uint256 projectId, string calldata uri) external;
}
