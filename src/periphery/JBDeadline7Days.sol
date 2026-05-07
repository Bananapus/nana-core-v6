// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBDeadline} from "../JBDeadline.sol";

/// @notice A reusable deadline implementation with a fixed seven-day duration.
contract JBDeadline7Days is JBDeadline {
    constructor() JBDeadline(7 days) {}
}
