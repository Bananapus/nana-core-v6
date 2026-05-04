// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "../interfaces/IJBPriceFeed.sol";

/// @notice A trivial price feed that always returns 1:1 (one unit = one unit). Used when a payout limit is
/// denominated in the same currency as the terminal's token, so no actual conversion is needed.
contract JBMatchingPriceFeed is IJBPriceFeed {
    constructor() {}

    /// @inheritdoc IJBPriceFeed
    function currentUnitPrice(uint256 decimals) public view virtual override returns (uint256) {
        return 10 ** decimals;
    }
}
