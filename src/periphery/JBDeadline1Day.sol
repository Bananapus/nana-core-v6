// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBDeadline} from "../JBDeadline.sol";

/// @notice A reusable deadline implementation with a fixed one-day duration.
contract JBDeadline1Day is JBDeadline {
    constructor() JBDeadline(1 days) {}
}
