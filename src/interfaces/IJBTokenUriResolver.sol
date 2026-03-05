// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Resolves token URIs for project NFTs.
interface IJBTokenUriResolver {
    /// @notice Returns the token URI for a project.
    /// @param projectId The ID of the project to get the token URI of.
    /// @return tokenUri The token URI.
    function getUri(uint256 projectId) external view returns (string memory tokenUri);
}
