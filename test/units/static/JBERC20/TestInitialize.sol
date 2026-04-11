// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {JBERC20} from "../../../../src/JBERC20.sol";
import {JBERC20Setup} from "./JBERC20Setup.sol";

contract TestInitialize_Local is JBERC20Setup {
    string _name = "Nana";
    string _symbol = "NANA";

    function setUp() public {
        super.erc20Setup();
    }

    function test_ImplementationCannotBeInitialized() external {
        // The implementation has _name = "invalid" set in constructor, so initialize() must revert.
        vm.expectRevert(JBERC20.JBERC20_AlreadyInitialized.selector);
        _implementation.initialize(_name, _symbol, _tokens, _projects, _permissions);
    }

    function test_WhenANameIsAlreadySet() external {
        // it will revert

        _erc20.initialize(_name, _symbol, _tokens, _projects, _permissions);

        // ensure TOKENS is set
        address setTokens = address(JBERC20(address(_erc20)).TOKENS());
        assertEq(setTokens, _tokens);

        // will fail as internal name is no longer zero length
        vm.expectRevert();
        _erc20.initialize(_name, _symbol, _tokens, _projects, _permissions);
    }

    function test_WhenName_EQNothing() external {
        // it will revert

        // will fail as internal name is no longer than zero length
        vm.expectRevert();
        _erc20.initialize("", _symbol, _tokens, _projects, _permissions);
    }

    function test_WhenNameIsValidAndNotAlreadySet() external {
        // it will set the name, symbol, and store references

        _erc20.initialize(_name, _symbol, _tokens, _projects, _permissions);

        // ensure TOKENS is set
        address setTokens = address(JBERC20(address(_erc20)).TOKENS());
        assertEq(setTokens, _tokens);

        // name is set
        string memory _setName = IERC20Metadata(address(_erc20)).name();
        string memory _setSymbol = IERC20Metadata(address(_erc20)).symbol();

        assertEq(_setName, _name);
        assertEq(_setSymbol, _symbol);
    }
}
