// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "../../../src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "../../../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {JBProjectCreationFeeReceiver} from "../../../src/periphery/JBProjectCreationFeeReceiver.sol";
import {JBTest} from "../../helpers/JBTest.sol";

contract MockProjectCreationFeeTerminal {
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable {}
}

contract TestJBProjectCreationFeeReceiver_Local is JBTest {
    IJBDirectory _directory = IJBDirectory(makeAddr("directory"));
    IJBTerminal _terminal;
    uint256 _projectId = JBConstants.FEE_BENEFICIARY_PROJECT_ID;
    uint256 _amount = 1 ether;

    JBProjectCreationFeeReceiver _receiver;

    function setUp() public {
        _terminal = IJBTerminal(address(new MockProjectCreationFeeTerminal()));
        _receiver = new JBProjectCreationFeeReceiver({directory: _directory, projectId: _projectId});
    }

    function test_WhenReceivingNativeTokens() external {
        // it will route the amount to the project's primary native terminal

        bytes memory primaryTerminalCall =
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_projectId, JBConstants.NATIVE_TOKEN));
        mockExpect(address(_directory), primaryTerminalCall, abi.encode(_terminal));

        bytes memory addToBalanceCall = abi.encodeCall(
            IJBTerminal.addToBalanceOf,
            (_projectId, JBConstants.NATIVE_TOKEN, _amount, false, "Project creation fee", bytes(""))
        );
        vm.expectCall(address(_terminal), _amount, addToBalanceCall);

        vm.expectEmit(address(_receiver));
        emit JBProjectCreationFeeReceiver.RouteProjectCreationFee({
            projectId: _projectId, terminal: _terminal, amount: _amount, caller: address(this)
        });

        vm.deal(address(this), _amount);
        (bool success,) = address(_receiver).call{value: _amount}("");

        assertTrue(success);
    }

    function test_WhenReceivingZeroNativeTokens() external {
        // it will no-op

        (bool success,) = address(_receiver).call{value: 0}("");

        assertTrue(success);
    }

    function test_WhenPrimaryNativeTerminalIsNotSet() external {
        // it will revert

        bytes memory primaryTerminalCall =
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_projectId, JBConstants.NATIVE_TOKEN));
        mockExpect(address(_directory), primaryTerminalCall, abi.encode(IJBTerminal(address(0))));

        vm.deal(address(this), _amount);
        (bool success, bytes memory returndata) = address(_receiver).call{value: _amount}("");

        assertFalse(success);
        assertEq(
            returndata,
            abi.encodeWithSelector(
                JBProjectCreationFeeReceiver.JBProjectCreationFeeReceiver_NoPrimaryTerminal.selector, _projectId
            )
        );
    }

    function test_WhenDirectoryIsZeroAddress() external {
        // it will revert

        vm.expectRevert(JBProjectCreationFeeReceiver.JBProjectCreationFeeReceiver_ZeroDirectory.selector);
        new JBProjectCreationFeeReceiver({directory: IJBDirectory(address(0)), projectId: _projectId});
    }

    function test_WhenProjectIdIsZero() external {
        // it will revert

        vm.expectRevert(JBProjectCreationFeeReceiver.JBProjectCreationFeeReceiver_ZeroProjectId.selector);
        new JBProjectCreationFeeReceiver({directory: _directory, projectId: 0});
    }
}
