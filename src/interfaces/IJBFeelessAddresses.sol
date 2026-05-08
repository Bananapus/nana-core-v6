// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Tracks addresses that are exempt from fees, both globally and on a per-project basis.
interface IJBFeelessAddresses {
    /// @notice An address's global feeless status was set.
    /// @param addr The address whose feeless status was set.
    /// @param isFeeless Whether the address is feeless.
    /// @param caller The address that set the feeless status.
    event SetFeelessAddress(address indexed addr, bool indexed isFeeless, address caller);

    /// @notice An address's per-project feeless status was set.
    /// @param projectId The ID of the project the feeless status applies to.
    /// @param addr The address whose feeless status was set.
    /// @param isFeeless Whether the address is feeless for the project.
    /// @param caller The address that set the feeless status.
    event SetFeelessAddressFor(
        uint256 indexed projectId, address indexed addr, bool indexed isFeeless, address caller
    );

    /// @notice Returns whether the specified address is feeless globally.
    /// @param addr The address to check.
    /// @return A flag indicating whether the address is feeless.
    function isFeeless(address addr) external view returns (bool);

    /// @notice Returns whether the specified address is feeless for a specific project.
    /// @param projectId The ID of the project to check.
    /// @param addr The address to check.
    /// @return A flag indicating whether the address is feeless for the project.
    function isFeelessForProject(uint256 projectId, address addr) external view returns (bool);

    /// @notice Returns whether the specified address is feeless for a specific project, considering both global and
    /// per-project feeless status.
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the address is feeless (globally or for the project).
    function isFeelessFor(address addr, uint256 projectId) external view returns (bool);

    /// @notice Sets whether an address is feeless globally.
    /// @param addr The address to set the feeless status of.
    /// @param flag A flag indicating whether the address should be feeless.
    function setFeelessAddress(address addr, bool flag) external;

    /// @notice Sets whether an address is feeless for a specific project.
    /// @param projectId The ID of the project to set the feeless status for.
    /// @param addr The address to set the feeless status of.
    /// @param flag A flag indicating whether the address should be feeless for the project.
    function setFeelessAddressFor(uint256 projectId, address addr, bool flag) external;
}
