// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBTerminalStore} from "../../../../src/JBTerminalStore.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

contract TestAddAccountingContextsFor_Local is JBMultiTerminalSetup {
    uint256 _projectId = 1;
    address _usdc = makeAddr("USDC");
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 _usdcCurrency = uint32(uint160(_usdc));

    function setUp() public {
        super.multiTerminalSetup();
    }

    function test_WhenCallerIsNotPermissioned() external {
        // it will revert UNAUTHORIZED
    }

    modifier whenCallerIsPermissioned() {
        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(this));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        _;
    }

    function test_GivenTheContextIsAlreadySet() external whenCallerIsPermissioned {
        // it will revert ACCOUNTING_CONTEXT_ALREADY_SET

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokens[0] = JBAccountingContext({token: _usdc, decimals: 6, currency: uint32(uint160(_usdc))});

        // Mock recordAccountingContextOf to revert with AccountingContextAlreadySet
        vm.mockCallRevert(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)),
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_AccountingContextAlreadySet.selector, _usdc)
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_AccountingContextAlreadySet.selector, _usdc)
        );
        _terminal.addAccountingContextsFor(_projectId, _tokens);
    }

    function test_GivenHappyPathERC20() external whenCallerIsPermissioned {
        // it will set the context and emit SetAccountingContext

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokens[0] = JBAccountingContext({token: _usdc, decimals: 6, currency: uint32(uint160(_usdc))});

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // Mock the store to return the context when queried
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, _usdc)),
            abi.encode(_tokens[0])
        );

        JBAccountingContext memory _storedContext = _terminal.accountingContextForTokenOf(_projectId, _usdc);
        assertEq(_storedContext.token, _usdc);
        assertEq(_storedContext.decimals, 6);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_storedContext.currency, uint32(uint160(_usdc)));
    }

    function test_GivenHappyPathNative() external whenCallerIsPermissioned {
        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // Mock the store to return the context when queried
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, JBConstants.NATIVE_TOKEN)
            ),
            abi.encode(_tokens[0])
        );

        JBAccountingContext memory _storedContext =
            _terminal.accountingContextForTokenOf(_projectId, JBConstants.NATIVE_TOKEN);
        assertEq(_storedContext.token, JBConstants.NATIVE_TOKEN);
        assertEq(_storedContext.decimals, 18);
        assertEq(_storedContext.currency, uint32(uint160(JBConstants.NATIVE_TOKEN)));
    }

    function test_WhenCallerIsController() external {
        // it will alsoGrantAccess

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(0));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // Mock the store to return the context when queried
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, JBConstants.NATIVE_TOKEN)
            ),
            abi.encode(_tokens[0])
        );

        JBAccountingContext memory _storedContext =
            _terminal.accountingContextForTokenOf(_projectId, JBConstants.NATIVE_TOKEN);
        assertEq(_storedContext.token, JBConstants.NATIVE_TOKEN);
        assertEq(_storedContext.decimals, 18);
        assertEq(_storedContext.currency, uint32(uint160(JBConstants.NATIVE_TOKEN)));
    }

    function test_WhenCallerIsControllerAndRulesetDoesntAllow() external {
        // it will revert

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(0));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Mock recordAccountingContextOf to revert with AddingAccountingContextNotAllowed (validation now in store)
        vm.mockCallRevert(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)),
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_AddingAccountingContextNotAllowed.selector)
        );

        vm.expectRevert(JBTerminalStore.JBTerminalStore_AddingAccountingContextNotAllowed.selector);
        _terminal.addAccountingContextsFor(_projectId, _tokens);
    }

    function test_WhenCurrencyIsNativeButDecimalsDNEQ18() external {
        // it will revert JBTerminalStore_AccountingContextDecimalsMismatch

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(0));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 17, //invalid
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Mock recordAccountingContextOf to revert with DecimalsMismatch (validation now in store)
        vm.mockCallRevert(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)),
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_AccountingContextDecimalsMismatch.selector)
        );

        vm.expectRevert(JBTerminalStore.JBTerminalStore_AccountingContextDecimalsMismatch.selector);
        _terminal.addAccountingContextsFor(_projectId, _tokens);
    }

    function test_WhenTokenDecimalsDoesNotMatchAccountingContext() external {
        // it will revert JBTerminalStore_AccountingContextDecimalsMismatch

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(0));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        address someToken = makeAddr("someToken");

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({
            token: someToken,
            decimals: 17, // invalid- we will mock a return of 18 decimals
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(someToken))
        });

        // Mock recordAccountingContextOf to revert with DecimalsMismatch (validation now in store)
        vm.mockCallRevert(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)),
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_AccountingContextDecimalsMismatch.selector)
        );

        vm.expectRevert(JBTerminalStore.JBTerminalStore_AccountingContextDecimalsMismatch.selector);
        _terminal.addAccountingContextsFor(_projectId, _tokens);
    }

    function test_WhenCurrencyEQZero() external {
        // it will revert JBTerminalStore_ZeroAccountingContextCurrency

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(0));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        address someToken = makeAddr("someToken");

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokens[0] = JBAccountingContext({token: someToken, decimals: 18, currency: uint32(uint160(0))});

        // Mock recordAccountingContextOf to revert with ZeroAccountingContextCurrency (validation now in store)
        vm.mockCallRevert(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)),
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_ZeroAccountingContextCurrency.selector)
        );

        vm.expectRevert(JBTerminalStore.JBTerminalStore_ZeroAccountingContextCurrency.selector);
        _terminal.addAccountingContextsFor(_projectId, _tokens);
    }
}
