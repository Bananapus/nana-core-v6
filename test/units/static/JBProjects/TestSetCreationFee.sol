// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBProjects} from "../../../../src/interfaces/IJBProjects.sol";
import {JBProjects} from "../../../../src/JBProjects.sol";
import {JBProjectsSetup} from "./JBProjectsSetup.sol";

contract TestSetCreationFee_Local is JBProjectsSetup {
    address payable _receiver = payable(makeAddr("receiver"));
    uint256 _fee = 0.0005 ether;

    function setUp() public {
        super.projectsSetup();
    }

    function test_WhenCallerIsOwner() external {
        // it will set the creation fee and receiver

        vm.expectEmit();
        emit IJBProjects.SetCreationFee({fee: _fee, receiver: _receiver, caller: _owner});

        vm.prank(_owner);
        _projects.setCreationFee({fee: _fee, receiver: _receiver});

        assertEq(_projects.creationFee(), _fee);
        assertEq(_projects.creationFeeReceiver(), _receiver);
    }

    function test_WhenCallerIsOwnerAndFeeIsZero() external {
        // it will allow clearing the receiver

        vm.prank(_owner);
        _projects.setCreationFee({fee: _fee, receiver: _receiver});

        vm.expectEmit();
        emit IJBProjects.SetCreationFee({fee: 0, receiver: payable(address(0)), caller: _owner});

        vm.prank(_owner);
        _projects.setCreationFee({fee: 0, receiver: payable(address(0))});

        assertEq(_projects.creationFee(), 0);
        assertEq(_projects.creationFeeReceiver(), address(0));
    }

    function test_WhenFeeIsNonZeroAndReceiverIsZero() external {
        // it will revert

        vm.prank(_owner);
        vm.expectRevert(JBProjects.JBProjects_ZeroCreationFeeReceiver.selector);
        _projects.setCreationFee({fee: _fee, receiver: payable(address(0))});
    }

    function test_WhenFeeExceedsMax() external {
        // it will revert

        uint256 _max = _projects.MAX_CREATION_FEE();
        uint256 _exceedingFee = _max + 1;

        vm.expectRevert(
            abi.encodeWithSelector(JBProjects.JBProjects_CreationFeeExceedsMax.selector, _exceedingFee, _max)
        );
        vm.prank(_owner);
        _projects.setCreationFee({fee: _exceedingFee, receiver: _receiver});
    }

    function test_WhenCallerIsNotOwner() external {
        // it will revert

        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        bytes memory expectedError = abi.encodeWithSelector(selector, address(this));

        vm.expectRevert(expectedError);
        _projects.setCreationFee({fee: _fee, receiver: _receiver});
    }
}
