// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBControllerSetup} from "./JBControllerSetup.sol";

contract TestReceiveMigrationFrom_Local is JBControllerSetup {
    uint256 _projectId = 1;
    IERC165 _from = IERC165(makeAddr("from"));

    function setUp() public {
        super.controllerSetup();
    }

    function test_GivenThatTheCallerIsAlsoControllerOfProjectId() external {
        vm.expectRevert(
            abi.encodeWithSelector(JBController.JBController_OnlyDirectory.selector, address(this), address(directory))
        );

        vm.prank(address(this));
        IJBMigratable(address(_controller)).beforeReceiveMigrationFrom(_from, _projectId);
    }

    function test_GivenThatTheCallerIsDirectory() external {
        // mock supports interface call
        mockExpect(
            address(_from),
            abi.encodeCall(IERC165.supportsInterface, (type(IJBProjectUriRegistry).interfaceId)),
            abi.encode(true)
        );

        // mock call to from uriOf
        mockExpect(address(_from), abi.encodeCall(IJBProjectUriRegistry.uriOf, (_projectId)), abi.encode("Juicay"));

        // Mock does not support the controller interface.
        mockExpect(
            address(_from),
            abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)),
            abi.encode(false)
        );

        vm.prank(address(directory));
        IJBMigratable(address(_controller)).beforeReceiveMigrationFrom(_from, _projectId);
        string memory stored = _controller.uriOf(_projectId);
        assertEq(stored, "Juicay");
    }

    function test_GivenThatTheCallerIsDirectory_FromSupportsControllerInterface(uint8 tokenAmount) external {
        // mock supports interface call
        mockExpect(
            address(_from),
            abi.encodeCall(IERC165.supportsInterface, (type(IJBProjectUriRegistry).interfaceId)),
            abi.encode(true)
        );

        // mock call to from uriOf
        mockExpect(address(_from), abi.encodeCall(IJBProjectUriRegistry.uriOf, (_projectId)), abi.encode("Juicay"));

        // Mock does not support the controller interface.
        mockExpect(
            address(_from),
            abi.encodeCall(IERC165.supportsInterface, (type(IJBController).interfaceId)),
            abi.encode(true)
        );

        mockExpect(
            address(_from),
            abi.encodeCall(IJBController.pendingReservedTokenBalanceOf, (_projectId)),
            abi.encode(uint256(tokenAmount))
        );

        if (tokenAmount > 0) {
            // mock call to from mintTokensOf
            mockExpect(
                address(_from),
                abi.encodeCall(IJBController.sendReservedTokensToSplitsOf, (_projectId)),
                abi.encode(tokenAmount)
            );
        }

        vm.prank(address(directory));
        IJBMigratable(address(_controller)).beforeReceiveMigrationFrom(_from, _projectId);
        string memory stored = _controller.uriOf(_projectId);
        assertEq(stored, "Juicay");
    }

    function test_GivenThatTheCallerIsNotController() external {
        // it will revert

        vm.expectRevert(
            abi.encodeWithSelector(JBController.JBController_OnlyDirectory.selector, address(this), address(directory))
        );
        IJBMigratable(address(_controller)).beforeReceiveMigrationFrom(_from, _projectId);
    }
}
