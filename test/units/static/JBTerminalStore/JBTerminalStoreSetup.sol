// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBTerminalStore} from "../../../../src/JBTerminalStore.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPrices} from "../../../../src/interfaces/IJBPrices.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBTerminalStoreSetup is JBTest {
    // Mocks
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets public rulesets = IJBRulesets(makeAddr("rules"));
    IJBPrices public prices = IJBPrices(makeAddr("prices"));

    // Target Contract
    IJBTerminalStore public _store;

    function terminalStoreSetup() public virtual {
        // Instantiate the contract being tested
        _store = new JBTerminalStore(directory, prices, rulesets);
    }
}
