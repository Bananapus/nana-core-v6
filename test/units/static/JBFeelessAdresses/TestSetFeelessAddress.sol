// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {JBFeelessSetup} from "./JBFeelessSetup.sol";

contract TestSetFeelessAddress_Local is JBFeelessSetup {
    address _feeLess = makeAddr("something");

    function setUp() public {
        super.feelessAddressesSetup();
    }

    function test_WhenCallerIsOwner() external {
        // it should set isFeelessFor[0] and emit SetFeelessAddress
        vm.expectEmit();
        emit IJBFeelessAddresses.SetFeelessAddress(0, _feeLess, true, address(_owner));

        vm.prank(_owner);
        _feelessAddresses.setFeelessAddress(_feeLess, true);

        assertTrue(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: 0, caller: address(0)}));
    }

    function test_WhenCallerIsOwner_SetFeelessAddressFor() external {
        uint256 projectId = 42;

        vm.expectEmit();
        emit IJBFeelessAddresses.SetFeelessAddress(projectId, _feeLess, true, address(_owner));

        vm.prank(_owner);
        _feelessAddresses.setFeelessAddressFor({projectId: projectId, addr: _feeLess, flag: true});

        // Project-specific check
        assertTrue(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: projectId, caller: address(0)}));
        // Wildcard (project 0) should NOT be set
        assertFalse(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: 0, caller: address(0)}));
        // isFeelessFor should return true for the specific project
        assertTrue(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: projectId, caller: address(0)}));
        // isFeelessFor should return false for a different project
        assertFalse(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: 99, caller: address(0)}));
    }

    function test_WhenCallerIsOwner_WildcardAppliesToAllProjects() external {
        vm.prank(_owner);
        _feelessAddresses.setFeelessAddress(_feeLess, true);

        // Wildcard applies to any projectId
        assertTrue(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: 1, caller: address(0)}));
        assertTrue(_feelessAddresses.isFeelessFor({addr: _feeLess, projectId: 999, caller: address(0)}));
    }

    function test_RevertIf_RevertWhen_CallerIsNotOwner() external {
        address _multisig = makeAddr("multisig");
        vm.prank(_multisig);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        bytes memory expectedError = abi.encodeWithSelector(selector, _multisig);
        vm.expectRevert(expectedError);
        _feelessAddresses.setFeelessAddress(_feeLess, true);
    }

    function test_RevertIf_RevertWhen_CallerIsNotOwner_SetFeelessAddressFor() external {
        address _multisig = makeAddr("multisig");
        vm.prank(_multisig);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        bytes memory expectedError = abi.encodeWithSelector(selector, _multisig);
        vm.expectRevert(expectedError);
        _feelessAddresses.setFeelessAddressFor({projectId: 1, addr: _feeLess, flag: true});
    }
}
