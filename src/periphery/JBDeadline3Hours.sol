// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBDeadline} from "../JBDeadline.sol";

contract JBDeadline3Hours is JBDeadline {
    constructor() JBDeadline(3 hours) {}
}
