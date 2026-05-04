// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBProjects} from "./IJBProjects.sol";
import {IJBTerminal} from "./IJBTerminal.sol";

/// @notice Interface for the protocol's routing table. Tracks which terminals accept payments for each project and
/// which controller manages each project's rulesets and tokens. Used by frontends and contracts to discover where to
/// send funds.
interface IJBDirectory {
    /// @notice A terminal was added to a project.
    /// @param projectId The ID of the project the terminal was added to.
    /// @param terminal The terminal that was added.
    /// @param caller The address that added the terminal.
    event AddTerminal(uint256 indexed projectId, IJBTerminal indexed terminal, address caller);

    /// @notice A project's controller was set.
    /// @param projectId The ID of the project whose controller was set.
    /// @param controller The controller that was set.
    /// @param caller The address that set the controller.
    event SetController(uint256 indexed projectId, IERC165 indexed controller, address caller);

    /// @notice An address's permission to set a project's first controller was updated.
    /// @param addr The address whose permission was updated.
    /// @param isAllowed Whether the address is allowed to set a project's first controller.
    /// @param caller The address that updated the permission.
    event SetIsAllowedToSetFirstController(address indexed addr, bool indexed isAllowed, address caller);

    /// @notice A project's primary terminal for a token was set.
    /// @param projectId The ID of the project whose primary terminal was set.
    /// @param token The token the primary terminal was set for.
    /// @param terminal The terminal that was set as primary.
    /// @param caller The address that set the primary terminal.
    event SetPrimaryTerminal(
        uint256 indexed projectId, address indexed token, IJBTerminal indexed terminal, address caller
    );

    /// @notice A project's terminals were set.
    /// @param projectId The ID of the project whose terminals were set.
    /// @param terminals The terminals that were set.
    /// @param caller The address that set the terminals.
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
