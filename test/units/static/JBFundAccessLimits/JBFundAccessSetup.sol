// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBFundAccessLimits} from "../../../../src/JBFundAccessLimits.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "../../../../src/interfaces/IJBFundAccessLimits.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBFundAccessSetup is JBTest {
    // Target Contract
    IJBFundAccessLimits public _fundAccess;

    // Mocks
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));

    function fundAccessSetup() public virtual {
        // Instantiate the contract being tested
        _fundAccess = new JBFundAccessLimits(directory);
    }
}
