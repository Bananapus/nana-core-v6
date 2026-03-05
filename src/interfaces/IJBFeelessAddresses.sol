// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Tracks addresses that are exempt from fees.
interface IJBFeelessAddresses {
    event SetFeelessAddress(address indexed addr, bool indexed isFeeless, address caller);

    /// @notice Returns whether the specified address is feeless.
    /// @param addr The address to check.
    /// @return A flag indicating whether the address is feeless.
    function isFeeless(address addr) external view returns (bool);

    /// @notice Sets whether an address is feeless.
    /// @param addr The address to set the feeless status of.
    /// @param flag A flag indicating whether the address should be feeless.
    function setFeelessAddress(address addr, bool flag) external;
}
