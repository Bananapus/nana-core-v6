// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPriceFeed} from "../interfaces/IJBPriceFeed.sol";

contract JBMatchingPriceFeed is IJBPriceFeed {
    constructor() {}

    /// @inheritdoc IJBPriceFeed
    function currentUnitPrice(uint256 decimals) public view virtual override returns (uint256) {
        return 10 ** decimals;
    }
}
