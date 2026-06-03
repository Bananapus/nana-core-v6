// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "../interfaces/IJBPriceFeed.sol";

/// @notice A trivial price feed that always returns 1:1 (one unit = one unit). Used when a payout limit is
/// denominated in the same currency as the terminal's token, so no actual conversion is needed.
contract JBMatchingPriceFeed is IJBPriceFeed {
    constructor() {}

    /// @notice Gets the current price (per 1 unit) from the feed.
    /// @param decimals The number of decimals the return value should use.
    /// @return The current unit price from the feed, as a fixed point number with the specified number of decimals.
    function currentUnitPrice(uint256 decimals) public view virtual override returns (uint256) {
        return 10 ** decimals;
    }
}
