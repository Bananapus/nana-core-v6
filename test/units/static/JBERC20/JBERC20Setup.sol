// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBERC20} from "../../../../src/JBERC20.sol";
import {IJBToken} from "../../../../src/interfaces/IJBToken.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBERC20Setup is JBTest {
    address _owner = makeAddr("owner");

    // Target Contract
    IJBToken public _erc20;

    function erc20Setup() public virtual {
        // Instantiate the contract being tested
        _erc20 = new JBERC20();
    }
}
