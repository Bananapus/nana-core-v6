// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayerTracker} from "../../../../src/interfaces/IJBPayerTracker.sol";
import {JBProjectsSetup} from "./JBProjectsSetup.sol";

/// @notice A creation-fee receiver that records the `originalPayer()` its caller advertises while it receives the
/// forwarded fee. Used to prove `JBProjects` exposes the new project's owner during the forward.
contract TrackerObservingReceiver {
    address public observedPayer;
    bool public observed;

    receive() external payable {
        observedPayer = IJBPayerTracker(msg.sender).originalPayer();
        observed = true;
    }
}

contract TestPayerTracker_Local is JBProjectsSetup {
    TrackerObservingReceiver internal _receiver;
    address internal _projectOwner = makeAddr("projectOwner");
    uint256 internal _creationFee = 0.0005 ether;

    function setUp() public {
        super.projectsSetup();
        _receiver = new TrackerObservingReceiver();
    }

    function test_WhenInterfaceIdIsIJBPayerTracker() external view {
        // it will return true
        assertTrue(_projects.supportsInterface(type(IJBPayerTracker).interfaceId));
    }

    function test_GivenNoFeeForwardIsInProgress() external view {
        // it will return the zero address
        assertEq(_projects.originalPayer(), address(0));
    }

    function test_GivenAFeeForwardIsInProgress() external {
        // it will expose the new project's owner to the fee receiver, then clear it

        vm.prank(_owner);
        _projects.setCreationFee({fee: _creationFee, receiver: payable(address(_receiver))});

        vm.deal(address(this), _creationFee);
        _projects.createFor{value: _creationFee}(_projectOwner);

        // The receiver observed the new project's owner as the original payer during the forward.
        assertTrue(_receiver.observed());
        assertEq(_receiver.observedPayer(), _projectOwner);

        // The transient slot is cleared once the forward returns.
        assertEq(_projects.originalPayer(), address(0));
        assertEq(address(_receiver).balance, _creationFee);
    }
}
