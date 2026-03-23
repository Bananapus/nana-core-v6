// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {JBERC20} from "../../../../src/JBERC20.sol";
import {IJBToken} from "../../../../src/interfaces/IJBToken.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBERC20Setup is JBTest {
    address _owner = makeAddr("owner");

    // Implementation (constructor sets _name = "invalid", cannot be initialized)
    IJBToken public _implementation;

    // Target Contract (clone with empty _name, can be initialized)
    IJBToken public _erc20;

    function erc20Setup() public virtual {
        // Deploy the implementation
        _implementation = new JBERC20();

        // Clone it — clones start with empty storage, so initialize() works
        _erc20 = IJBToken(Clones.clone(address(_implementation)));
    }
}
