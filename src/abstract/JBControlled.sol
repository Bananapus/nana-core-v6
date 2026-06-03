// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBControlled} from "./../interfaces/IJBControlled.sol";
import {IJBDirectory} from "./../interfaces/IJBDirectory.sol";

/// @notice Base contract that restricts certain functions to the project's current controller (as registered in
/// `JBDirectory`). Used by `JBTokens`, `JBSplits`, `JBFundAccessLimits`, `JBRulesets`, and `JBPrices` to ensure only
/// the controller can update project state.
abstract contract JBControlled is IJBControlled {
    //*********************************************************************//
    // --------------------------- custom errors -------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the caller is not the controller of the specified project.
    error JBControlled_ControllerUnauthorized(address controller);

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    /// @notice Only allows the controller of the specified project to proceed.
    /// @param projectId The ID of the project.
    modifier onlyControllerOf(uint256 projectId) {
        _onlyControllerOf(projectId);
        _;
    }

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    constructor(IJBDirectory directory) {
        DIRECTORY = directory;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Only allows the controller of the specified project to proceed.
    function _onlyControllerOf(uint256 projectId) internal view {
        // Cache the controller address to avoid a redundant external call on revert.
        address controller = address(DIRECTORY.controllerOf(projectId));
        if (controller != msg.sender) {
            revert JBControlled_ControllerUnauthorized({controller: controller});
        }
    }
}
