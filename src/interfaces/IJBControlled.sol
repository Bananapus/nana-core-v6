// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "./IJBDirectory.sol";

/// @notice A contract that is controlled by a project's controller via the directory.
interface IJBControlled {
    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);
}
