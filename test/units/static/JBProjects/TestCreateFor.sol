// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {stdError} from "forge-std/StdError.sol";
import {IJBProjects} from "../../../../src/interfaces/IJBProjects.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {JBProjects} from "../../../../src/JBProjects.sol";
import {JBProjectsSetup} from "./JBProjectsSetup.sol";

contract TestCreateFor_Local is JBProjectsSetup {
    using stdStorage for StdStorage;

    address _user = makeAddr("sudoer");
    address payable _feeReceiver = payable(makeAddr("feeReceiver"));
    uint256 _creationFee = 0.0005 ether;

    function setUp() public {
        super.projectsSetup();
    }

    function test_WhenProjectIdPlusOneIsGtUint256Max() external {
        // it will revert with overflow

        // set storage to uint256 max
        stdstore.target(address(_projects)).sig("count()").checked_write(type(uint256).max);

        assertEq(_projects.count(), type(uint256).max);

        vm.expectRevert(stdError.arithmeticError);
        _projects.createFor(address(this));
    }

    modifier whenProjectIdPlusOneIsLtOrEqToUint256Max() {
        _;
    }

    function test_GivenOwnerIsNotAContract() external whenProjectIdPlusOneIsLtOrEqToUint256Max {
        // it will mint and emit Create

        // created on behalf of user by this contract
        vm.expectEmit();
        emit IJBProjects.Create(1, _user, address(this));

        _projects.createFor(_user);

        // check count is incrementing
        assertEq(_projects.count(), 1);
    }

    function test_GivenItIsIERC721Receiver() external whenProjectIdPlusOneIsLtOrEqToUint256Max {
        // it will mint and emit Create

        // mock IERC721Receiver support (return interface selector for onERC721Received)
        bytes memory receiverCall =
            abi.encodeCall(IERC721Receiver.onERC721Received, (address(this), address(0), 1, bytes("")));
        bytes memory returned = abi.encode(IERC721Receiver.onERC721Received.selector);

        mockExpect(address(this), receiverCall, returned);

        _projects.createFor(address(this));
    }

    function test_GivenItDoesNotSupportIERC721Receiver() external whenProjectIdPlusOneIsLtOrEqToUint256Max {
        // it will revert

        // encode custom error
        bytes4 selector = bytes4(keccak256("ERC721InvalidReceiver(address)"));
        bytes memory expectedError = abi.encodeWithSelector(selector, address(this));

        vm.expectRevert(expectedError);
        _projects.createFor(address(this));
    }

    function test_GivenCreationFeeIsNotPaid() external whenProjectIdPlusOneIsLtOrEqToUint256Max {
        // it will revert

        vm.prank(_owner);
        _projects.setCreationFee({fee: _creationFee, receiver: _feeReceiver});

        vm.expectRevert(abi.encodeWithSelector(JBProjects.JBProjects_InvalidCreationFee.selector, 0, _creationFee));
        _projects.createFor(_user);
    }

    function test_GivenCreationFeeIsOverpaid() external whenProjectIdPlusOneIsLtOrEqToUint256Max {
        // it will revert

        vm.prank(_owner);
        _projects.setCreationFee({fee: _creationFee, receiver: _feeReceiver});

        vm.deal(address(this), _creationFee + 1);
        vm.expectRevert(
            abi.encodeWithSelector(JBProjects.JBProjects_InvalidCreationFee.selector, _creationFee + 1, _creationFee)
        );
        _projects.createFor{value: _creationFee + 1}(_user);
    }

    function test_GivenCreationFeeIsPaid() external whenProjectIdPlusOneIsLtOrEqToUint256Max {
        // it will mint and forward the fee

        vm.prank(_owner);
        _projects.setCreationFee({fee: _creationFee, receiver: _feeReceiver});

        vm.deal(address(this), _creationFee);

        vm.expectEmit();
        emit IJBProjects.Create(1, _user, address(this));

        uint256 projectId = _projects.createFor{value: _creationFee}(_user);

        assertEq(projectId, 1);
        assertEq(_projects.count(), 1);
        assertEq(_feeReceiver.balance, _creationFee);
        assertEq(address(_projects).balance, 0);
    }
}
