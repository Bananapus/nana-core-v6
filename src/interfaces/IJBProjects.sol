// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IJBTokenUriResolver} from "./IJBTokenUriResolver.sol";

/// @notice Mints ERC-721s that represent project ownership and transfers.
interface IJBProjects is IERC721 {
    event Create(uint256 indexed projectId, address indexed owner, address caller);
    event SetTokenUriResolver(IJBTokenUriResolver indexed resolver, address caller);

    /// @notice Returns the total number of projects that have been created.
    function count() external view returns (uint256);

    /// @notice Returns the token URI resolver.
    function tokenUriResolver() external view returns (IJBTokenUriResolver);

    /// @notice Creates a new project and mints the project's ERC-721 to the specified owner.
    /// @param owner The address that will own the new project's ERC-721.
    /// @return projectId The ID of the newly created project.
    function createFor(address owner) external returns (uint256 projectId);

    /// @notice Sets the token URI resolver used to retrieve project token URIs.
    /// @param resolver The new token URI resolver.
    function setTokenUriResolver(IJBTokenUriResolver resolver) external;
}
