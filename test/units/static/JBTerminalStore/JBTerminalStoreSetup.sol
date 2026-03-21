// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBTerminalStore} from "../../../../src/JBTerminalStore.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPrices} from "../../../../src/interfaces/IJBPrices.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
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

        // Default mock: allow adding accounting contexts (return zero-id ruleset to bypass the
        // allowAddAccountingContext check in recordAccountingContextOf).
        JBRuleset memory _zeroRuleset = JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        vm.mockCall(address(rulesets), abi.encodeWithSelector(IJBRulesets.currentOf.selector), abi.encode(_zeroRuleset));
    }
}
