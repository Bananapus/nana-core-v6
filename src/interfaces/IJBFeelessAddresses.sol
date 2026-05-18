// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBFeelessHook} from "./IJBFeelessHook.sol";

/// @notice Tracks addresses that are exempt from fees, both globally and on a per-project basis.
/// @dev `projectId = 0` is the wildcard — an address feeless for project 0 is feeless for ALL projects.
interface IJBFeelessAddresses {
    /// @notice An address's feeless status was set for a project (or globally if projectId is 0).
    /// @param projectId The project the feeless status applies to. 0 means all projects.
    /// @param addr The address whose feeless status was set.
    /// @param isFeeless Whether the address is feeless.
    /// @param caller The address that set the feeless status.
    event SetFeelessAddress(uint256 indexed projectId, address indexed addr, bool indexed isFeeless, address caller);

    /// @notice The optional hook (set by the owner) that can grant feeless status with arbitrary logic. Set to the
    /// zero address to disable.
    /// @param hook The new feeless hook. The zero address disables hook consultation.
    /// @param caller The address that set the hook.
    event SetFeelessHook(IJBFeelessHook indexed hook, address caller);

    /// @notice The optional hook consulted (in addition to the static mappings) when computing feeless status.
    /// @dev `address(0)` means no hook is set.
    function feelessHook() external view returns (IJBFeelessHook);

    /// @notice Returns whether the specified address is feeless for a specific project, considering the wildcard
    /// (projectId 0) feeless status, the project-specific feeless status, and the feeless hook (if set).
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the address is feeless (globally, for the project, or per the hook).
    function isFeelessFor(address addr, uint256 projectId) external view returns (bool);

    /// @notice Sets whether an address is feeless globally (for all projects).
    /// @param addr The address to set the feeless status of.
    /// @param flag A flag indicating whether the address should be feeless.
    function setFeelessAddress(address addr, bool flag) external;

    /// @notice Sets whether an address is feeless for a specific project.
    /// @param projectId The ID of the project. 0 means all projects (same as `setFeelessAddress`).
    /// @param addr The address to set the feeless status of.
    /// @param flag A flag indicating whether the address should be feeless for the project.
    function setFeelessAddressFor(uint256 projectId, address addr, bool flag) external;

    /// @notice Sets (or clears) the feeless hook consulted by `isFeelessFor`.
    /// @param hook The new hook. Pass `address(0)` to disable hook consultation.
    function setFeelessHook(IJBFeelessHook hook) external;
}
