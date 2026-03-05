// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice A controller that supports project migration to and from other controllers.
interface IJBMigratable is IERC165 {
    event Migrate(uint256 indexed projectId, IERC165 to, address caller);

    /// @notice Migrates a project from this controller to another.
    /// @param projectId The ID of the project being migrated.
    /// @param to The controller to migrate the project to.
    function migrate(uint256 projectId, IERC165 to) external;

    /// @notice Prepares this controller to receive a project being migrated from another controller.
    /// @param from The controller being migrated from.
    /// @param projectId The ID of the project being migrated.
    function beforeReceiveMigrationFrom(IERC165 from, uint256 projectId) external;

    /// @notice Called after this controller has been set as the project's controller in the directory.
    /// @param from The controller being migrated from.
    /// @param projectId The ID of the project that was migrated.
    function afterReceiveMigrationFrom(IERC165 from, uint256 projectId) external;
}
