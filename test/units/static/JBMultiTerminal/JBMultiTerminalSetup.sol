// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MetadataResolverHelper} from "../../../helpers/MetadataResolverHelper.sol";
import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBMultiTerminal} from "../../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "../../../../src/interfaces/IJBProjects.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBSplits} from "../../../../src/interfaces/IJBSplits.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "../../../../src/interfaces/IJBTokens.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/*
Contract that deploys a target contract with other mock contracts to satisfy the constructor.
Tests relative to this contract will be dependent on mock calls/emits and stdStorage.
*/
contract JBMultiTerminalSetup is JBTest {
    // Target Contract
    IJBMultiTerminal public _terminal;
    MetadataResolverHelper public _metadataHelper;

    // Mocks
    IJBPermissions public permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects public projects = IJBProjects(makeAddr("projects"));
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets public rulesets = IJBRulesets(makeAddr("rulesets"));
    IJBTokens public tokens = IJBTokens(makeAddr("tokens"));
    IJBSplits public splits = IJBSplits(makeAddr("splits"));
    IJBTerminalStore public store = IJBTerminalStore(makeAddr("store"));
    IJBFeelessAddresses public feelessAddresses = IJBFeelessAddresses(makeAddr("feeless"));
    IPermit2 public permit2 = IPermit2(makeAddr("permit2"));
    address trustedForwarder = makeAddr("forwarder");

    function multiTerminalSetup() public virtual {
        // Constructor will call to find directory from the terminal store
        mockExpect(address(store), abi.encodeCall(IJBTerminalStore.DIRECTORY, ()), abi.encode(address(directory)));

        // Plant `JBPayoutSplitGroupLib` at its pre-linked address so delegatecalls from the terminal resolve.
        _etchPayoutSplitGroupLib();

        // Instantiate the contract being tested
        _terminal = new JBMultiTerminal(
            feelessAddresses, permissions, projects, splits, store, tokens, permit2, trustedForwarder
        );

        _metadataHelper = new MetadataResolverHelper();
    }
}
