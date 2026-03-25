// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissions} from "../../../../src/JBPermissions.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBPermissionsSetup is JBTest {
    // Target Contract
    IJBPermissions public _permissions;

    function permissionsSetup() public virtual {
        // Instantiate the contract being tested
        _permissions = new JBPermissions(address(0));
    }
}
