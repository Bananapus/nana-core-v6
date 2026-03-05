// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A price feed that returns a current unit price.
interface IJBPriceFeed {
    /// @notice Gets the current price (per 1 unit) from the feed.
    /// @param decimals The number of decimals the return value should use.
    /// @return The current unit price from the feed, as a fixed point number with the specified number of decimals.
    function currentUnitPrice(uint256 decimals) external view returns (uint256);
}
