// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBProjects} from "./IJBProjects.sol";
import {IJBTerminal} from "./IJBTerminal.sol";

/// @notice Tracks the terminals and the controller used by each project.
interface IJBDirectory {
    event AddTerminal(uint256 indexed projectId, IJBTerminal indexed terminal, address caller);
    event SetController(uint256 indexed projectId, IERC165 indexed controller, address caller);
    event SetIsAllowedToSetFirstController(address indexed addr, bool indexed isAllowed, address caller);
    event SetPrimaryTerminal(
        uint256 indexed projectId, address indexed token, IJBTerminal indexed terminal, address caller
    );
    event SetTerminals(uint256 indexed projectId, IJBTerminal[] terminals, address caller);

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice Returns the controller for a project.
    /// @param projectId The ID of the project to get the controller of.
    /// @return The project's controller.
    function controllerOf(uint256 projectId) external view returns (IERC165);

    /// @notice Returns whether an address is allowed to set a project's first controller on its behalf.
    /// @param addr The address to check.
    /// @return A flag indicating whether the address is allowed.
    function isAllowedToSetFirstController(address addr) external view returns (bool);

    /// @notice Returns whether a terminal is one of a project's terminals.
    /// @param projectId The ID of the project to check.
    /// @param terminal The terminal to check.
    /// @return A flag indicating whether the terminal belongs to the project.
    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool);

    /// @notice Returns the primary terminal for a project's token.
    /// @param projectId The ID of the project to get the primary terminal of.
    /// @param token The token to get the primary terminal for.
    /// @return The primary terminal for the project's token.
    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal);

    /// @notice Returns a project's terminals.
    /// @param projectId The ID of the project to get the terminals of.
    /// @return The project's terminals.
    function terminalsOf(uint256 projectId) external view returns (IJBTerminal[] memory);

    /// @notice Sets a project's controller.
    /// @param projectId The ID of the project to set the controller of.
    /// @param controller The controller to set.
    function setControllerOf(uint256 projectId, IERC165 controller) external;

    /// @notice Sets whether an address is allowed to set a project's first controller on its behalf.
    /// @param addr The address to set the permission for.
    /// @param flag A flag indicating whether the address is allowed.
    function setIsAllowedToSetFirstController(address addr, bool flag) external;

    /// @notice Sets a project's primary terminal for a specific token.
    /// @param projectId The ID of the project to set the primary terminal of.
    /// @param token The token to set the primary terminal for.
    /// @param terminal The terminal to set as primary.
    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) external;

    /// @notice Sets a project's terminals.
    /// @param projectId The ID of the project to set the terminals of.
    /// @param terminals The terminals to set.
    function setTerminalsOf(uint256 projectId, IJBTerminal[] calldata terminals) external;
}
