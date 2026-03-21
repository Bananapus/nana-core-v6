// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

contract TestAccountingContextsOf_Local is JBMultiTerminalSetup {
    uint256 _projectId = 1;
    address _usdc = makeAddr("USDC");
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 _usdcCurrency = uint32(uint160(_usdc));

    function setUp() public {
        super.multiTerminalSetup();
    }

    function test_WhenAccountingContextsAreSet() external {
        // it will return contexts

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(this));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokens[0] = JBAccountingContext({token: _usdc, decimals: 6, currency: uint32(uint160(_usdc))});

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens[0])), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // Mock the store to return all contexts when queried
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextsOf, (address(_terminal), _projectId)),
            abi.encode(_tokens)
        );

        JBAccountingContext[] memory _storedContexts = _terminal.accountingContextsOf(_projectId);
        assertEq(_storedContexts[0].currency, _usdcCurrency);
        assertEq(_storedContexts[0].token, _usdc);
        assertEq(_storedContexts[0].decimals, 6);
    }

    function test_WhenAccountingContextsAreNotSet() external {
        // it will return an empty array

        // Mock the store to return empty array
        JBAccountingContext[] memory _empty = new JBAccountingContext[](0);
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextsOf, (address(_terminal), _projectId)),
            abi.encode(_empty)
        );

        JBAccountingContext[] memory _storedContexts = _terminal.accountingContextsOf(_projectId);
        assertEq(_storedContexts.length, 0);
    }
}
