// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice A controller that supports project migration to and from other controllers.
interface IJBMigratable is IERC165 {
    /// @notice A project was migrated from this controller to another.
    /// @param projectId The ID of the project that was migrated.
    /// @param to The controller the project was migrated to.
    /// @param caller The address that called the migrate function.
    event Migrate(uint256 indexed projectId, IERC165 to, address caller);

    /// @notice Called after this controller has been set as the project's controller in the directory.
    /// @param from The controller to migrate from.
    /// @param projectId The ID of the project that was migrated.
    function afterReceiveMigrationFrom(IERC165 from, uint256 projectId) external;

    /// @notice Prepares this controller to receive a project to migrate from another controller.
    /// @param from The controller to migrate from.
    /// @param projectId The ID of the project to migrate.
    function beforeReceiveMigrationFrom(IERC165 from, uint256 projectId) external;

    /// @notice Migrates a project from this controller to another.
    /// @param projectId The ID of the project to migrate.
    /// @param to The controller to migrate the project to.
    function migrate(uint256 projectId, IERC165 to) external;
}
