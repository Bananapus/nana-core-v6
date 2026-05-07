// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBDeadline} from "../JBDeadline.sol";

/// @notice A reusable deadline implementation with a fixed three-day duration.
contract JBDeadline3Days is JBDeadline {
    constructor() JBDeadline(3 days) {}
}
