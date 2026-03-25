// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBDeadline} from "../JBDeadline.sol";

contract JBDeadline3Days is JBDeadline {
    constructor() JBDeadline(3 days) {}
}
