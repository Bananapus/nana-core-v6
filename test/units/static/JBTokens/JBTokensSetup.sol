// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {JBERC20} from "../../../../src/JBERC20.sol";
import {JBTokens} from "../../../../src/JBTokens.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBToken} from "../../../../src/interfaces/IJBToken.sol";
import {IJBTokens} from "../../../../src/interfaces/IJBTokens.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBTokensSetup is JBTest {
    // Mocks
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));
    IJBToken public jbToken;

    // Target Contract
    IJBTokens public _tokens;

    function tokensSetup() public virtual {
        // Instantiate the contract being tested
        jbToken = new JBERC20();
        _tokens = new JBTokens(directory, jbToken);
    }
}
