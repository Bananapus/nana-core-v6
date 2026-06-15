// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayerTracker} from "../../../../src/interfaces/IJBPayerTracker.sol";
import {JBProjects} from "../../../../src/JBProjects.sol";
import {JBProjectsSetup} from "./JBProjectsSetup.sol";

/// @notice A creation-fee receiver that records the `originalPayer()` its caller advertises while it receives the
/// forwarded fee. Used to prove `JBProjects` exposes the resolved fee payer during the forward.
contract TrackerObservingReceiver {
    address public observedPayer;
    bool public observed;

    receive() external payable {
        observedPayer = IJBPayerTracker(msg.sender).originalPayer();
        observed = true;
    }
}

/// @notice An intermediary deployer that forwards the creation fee to `JBProjects.createFor` while advertising a
/// fixed upstream payer via `IJBPayerTracker` — mirrors a real deployer paying the fee on a user's behalf.
contract DeployerTracker is IJBPayerTracker {
    JBProjects internal _projects;
    address public override originalPayer;

    constructor(JBProjects projects) {
        _projects = projects;
    }

    function createProjectFor(address owner, address payer) external payable returns (uint256 projectId) {
        originalPayer = payer;
        projectId = _projects.createFor{value: msg.value}(owner);
        originalPayer = address(0);
    }
}

    /// @notice A non-tracker contract whose `originalPayer()` probe reverts — `JBProjects` must fall back to it.
    contract RevertingProbeForwarder {
        JBProjects internal _projects;

        constructor(JBProjects projects) {
            _projects = projects;
        }

        function createProjectFor(address owner) external payable returns (uint256 projectId) {
            projectId = _projects.createFor{value: msg.value}(owner);
        }
    }

    contract TestPayerTracker_Local is JBProjectsSetup {
        TrackerObservingReceiver internal _receiver;
        address internal _projectOwner = makeAddr("projectOwner");
        address internal _eoaPayer = makeAddr("eoaPayer");
        uint256 internal _creationFee = 0.0005 ether;

        function setUp() public {
            super.projectsSetup();
            _receiver = new TrackerObservingReceiver();
            vm.prank(_owner);
            _projects.setCreationFee({fee: _creationFee, receiver: payable(address(_receiver))});
        }

        function test_WhenInterfaceIdIsIJBPayerTracker() external view {
            // it will return true
            assertTrue(_projects.supportsInterface(type(IJBPayerTracker).interfaceId));
        }

        function test_GivenNoFeeForwardIsInProgress() external view {
            // it will return the zero address
            assertEq(_projects.originalPayer(), address(0));
        }

        function test_GivenAnEoaCallerPaysTheFee() external {
            // it will resolve the original payer to the direct EOA caller, not the project owner

            vm.deal(_eoaPayer, _creationFee);
            vm.prank(_eoaPayer);
            _projects.createFor{value: _creationFee}(_projectOwner);

            assertTrue(_receiver.observed());
            assertEq(_receiver.observedPayer(), _eoaPayer, "payer must be the fee payer, not the project owner");
            assertEq(_projects.originalPayer(), address(0), "transient cleared after forward");
        }

        function test_GivenATrackerCallerForwardsTheFee() external {
            // it will resolve the original payer to the caller's advertised upstream payer

            DeployerTracker deployer = new DeployerTracker(_projects);
            vm.deal(address(this), _creationFee);

            deployer.createProjectFor{value: _creationFee}(_projectOwner, _eoaPayer);

            assertTrue(_receiver.observed());
            assertEq(_receiver.observedPayer(), _eoaPayer, "payer must propagate through the deployer tracker");
        }

        function test_GivenANonTrackerContractCallerPaysTheFee() external {
            // it will fall back to the immediate caller when the probe reverts

            RevertingProbeForwarder forwarder = new RevertingProbeForwarder(_projects);
            vm.deal(address(this), _creationFee);

            forwarder.createProjectFor{value: _creationFee}(_projectOwner);

            assertTrue(_receiver.observed());
            assertEq(_receiver.observedPayer(), address(forwarder), "non-tracker caller is the payer");
        }
    }
