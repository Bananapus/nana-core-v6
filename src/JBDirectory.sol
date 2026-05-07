// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBDirectoryAccessControl} from "./interfaces/IJBDirectoryAccessControl.sol";
import {IJBMigratable} from "./interfaces/IJBMigratable.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBTerminal} from "./interfaces/IJBTerminal.sol";

/// @notice The routing table for the protocol. Every project registers which terminals accept its payments and which
/// controller manages its rulesets and tokens. Frontends and other contracts use the directory to discover where to
/// send funds for a given project and token.
/// @dev Also manages controller migration — when a project upgrades its controller, the directory orchestrates the
/// handoff including `beforeReceiveMigrationFrom`, `migrate`, and `afterReceiveMigrationFrom` lifecycle hooks.
contract JBDirectory is JBPermissioned, Ownable, IJBDirectory {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBDirectory_DuplicateTerminals(IJBTerminal terminal);
    error JBDirectory_InvalidProjectIdInDirectory(uint256 projectId, uint256 limit);
    error JBDirectory_SetControllerNotAllowed(uint256 projectId);
    error JBDirectory_SetTerminalsNotAllowed(uint256 projectId);
    error JBDirectory_TokenNotAccepted(uint256 projectId, address token, IJBTerminal terminal);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The specified project's controller, which dictates how its terminals interact with its tokens and
    /// rulesets.
    /// @custom:param projectId The ID of the project to get the controller of.
    mapping(uint256 projectId => IERC165) public override controllerOf;

    /// @notice Whether the specified address is allowed to set a project's first controller on their behalf.
    /// @dev These addresses/contracts have been vetted by this contract's owner.
    /// @custom:param addr The address to check.
    mapping(address addr => bool) public override isAllowedToSetFirstController;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The primary terminal that a project uses for the specified token.
    /// @custom:param projectId The ID of the project to get the primary terminal of.
    /// @custom:param token The token that the terminal accepts.
    mapping(uint256 projectId => mapping(address token => IJBTerminal)) internal _primaryTerminalOf;

    /// @notice The specified project's terminals.
    /// @custom:param projectId The ID of the project to get the terminals of.
    mapping(uint256 projectId => IJBTerminal[]) internal _terminalsOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param owner The address that will own the contract.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        address owner
    )
        JBPermissioned(permissions)
        Ownable(owner)
    {
        PROJECTS = projects;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Assign a new controller to a project. The controller dictates how the project's terminals interact with
    /// its tokens and rulesets. If the project already has a controller, this triggers a full migration lifecycle
    /// (`beforeReceiveMigrationFrom` → `migrate` → state update → `afterReceiveMigrationFrom`).
    /// @dev Can only be called if:
    /// - The ruleset's metadata has `allowSetController` enabled, and the caller is the project's owner or has
    /// `SET_CONTROLLER` permission.
    /// - OR the caller is the project's current controller.
    /// - OR the caller `isAllowedToSetFirstController` and the project has no controller yet.
    /// @param projectId The ID of the project to set the controller for.
    /// @param controller The address of the controller to set.
    function setControllerOf(uint256 projectId, IERC165 controller) external override {
        // Keep a reference to the current controller.
        IERC165 currentController = controllerOf[projectId];

        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_CONTROLLER,
            alsoGrantAccessIf: (isAllowedToSetFirstController[msg.sender] && address(currentController) == address(0))
        });

        // The project must exist.
        if (projectId > PROJECTS.count()) revert JBDirectory_InvalidProjectIdInDirectory(projectId, PROJECTS.count());

        // Get a reference to a flag indicating whether the project is allowed to set its controller.
        // Setting the controller is allowed if the project doesn't have a controller,
        // OR if the caller is the current controller,
        // OR if the project's ruleset allows setting the controller.
        bool allowSetController = address(currentController) == address(0)
            || !currentController.supportsInterface(type(IJBDirectoryAccessControl).interfaceId)
            ? true
            : IJBDirectoryAccessControl(address(currentController)).setControllerAllowed(projectId);

        // If setting the controller is not allowed, revert.
        if (!allowSetController) {
            revert JBDirectory_SetControllerNotAllowed(projectId);
        }

        // Prepare the new controller to receive the project.
        if (address(currentController) != address(0) && controller.supportsInterface(type(IJBMigratable).interfaceId)) {
            IJBMigratable(address(controller))
                .beforeReceiveMigrationFrom({from: currentController, projectId: projectId});
        }

        // Migrate if needed. The old controller's migrate() runs while the directory still points to it,
        // closing the reentrancy window where the directory would point to the new controller during migration.
        if (
            address(currentController) != address(0)
                && currentController.supportsInterface(type(IJBMigratable).interfaceId)
        ) {
            IJBMigratable(address(currentController)).migrate({projectId: projectId, to: controller});
        }

        // Set the new controller after migration completes.
        controllerOf[projectId] = controller;

        emit SetController({projectId: projectId, controller: controller, caller: msg.sender});

        // Notify the new controller that migration is complete and it is now the active controller.
        if (address(currentController) != address(0) && controller.supportsInterface(type(IJBMigratable).interfaceId)) {
            IJBMigratable(address(controller))
                .afterReceiveMigrationFrom({from: currentController, projectId: projectId});
        }
    }

    /// @notice Allow or disallow an address to set the first controller for new projects. Typically used to whitelist
    /// deployer contracts (like `JBController`) that set a controller during `launchProjectFor`.
    /// @dev Only this contract's owner can call this function. These addresses are vetted controllers and project
    /// launchers. A project owner can always set their own controller — this list only governs *first* controller
    /// assignment by third parties.
    /// @param addr The address to allow or disallow.
    /// @param flag Whether the address is allowed to set first controllers. `true` to allow, `false` to revoke.
    function setIsAllowedToSetFirstController(address addr, bool flag) external override onlyOwner {
        // Set the flag in the allowlist.
        isAllowedToSetFirstController[addr] = flag;

        emit SetIsAllowedToSetFirstController({addr: addr, isAllowed: flag, caller: msg.sender});
    }

    /// @notice Designate which terminal should receive payments by default when someone pays a project in a specific
    /// token. Useful when a project has multiple terminals that accept the same token.
    /// @dev Can only be called by the project's owner or an address with `SET_PRIMARY_TERMINAL` permission. The
    /// terminal must accept the token for this project. If the terminal isn't already in the project's terminal list,
    /// it will be added automatically (requires `ADD_TERMINALS` permission).
    /// @param projectId The ID of the project to set the primary terminal for.
    /// @param token The token to set the primary terminal for.
    /// @param terminal The terminal to set as the primary terminal.
    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_PRIMARY_TERMINAL
        });

        // If the terminal doesn't accept the token, revert.
        if (terminal.accountingContextForTokenOf({projectId: projectId, token: token}).token == address(0)) {
            revert JBDirectory_TokenNotAccepted(projectId, token, terminal);
        }

        // If the terminal is not already in the project's terminal list, require ADD_TERMINALS permission.
        if (!isTerminalOf({projectId: projectId, terminal: terminal})) {
            _requirePermissionFrom({
                account: PROJECTS.ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.ADD_TERMINALS
            });
        }

        // Implicit terminal addition is by design. A primary terminal must be in the terminals list;
        // implicit addition avoids requiring a separate addTerminalsOf call.
        _addTerminalIfNeeded({projectId: projectId, terminal: terminal});

        // Store the terminal as the project's primary terminal for the token.
        _primaryTerminalOf[projectId][token] = terminal;

        emit SetPrimaryTerminal({projectId: projectId, token: token, terminal: terminal, caller: msg.sender});
    }

    /// @notice Replace a project's entire terminal list. Terminals are the contracts that accept payments and process
    /// cash outs for a project. This overwrites the existing list.
    /// @dev Can only be called by the project's owner, an address with `SET_TERMINALS` permission, or the project's
    /// controller. Unless the caller is the controller, the ruleset must have `allowSetTerminals` enabled.
    /// @param projectId The ID of the project to set terminals for.
    /// @param terminals An array of terminal addresses to set for the project.
    function setTerminalsOf(uint256 projectId, IJBTerminal[] calldata terminals) external override {
        // Cache the controller to avoid redundant storage reads.
        IERC165 controller = controllerOf[projectId];

        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_TERMINALS,
            alsoGrantAccessIf: msg.sender == address(controller)
        });

        // Get a reference to the flag indicating whether the project is allowed to set its terminals.
        bool allowSetTerminals = !controller.supportsInterface(type(IJBDirectoryAccessControl).interfaceId)
            || IJBDirectoryAccessControl(address(controller)).setTerminalsAllowed(projectId);

        // If the caller is not the project's controller, the project's ruleset must allow setting terminals.
        if (msg.sender != address(controller) && !allowSetTerminals) {
            revert JBDirectory_SetTerminalsNotAllowed(projectId);
        }

        // Set the stored terminals for the project.
        _terminalsOf[projectId] = terminals;

        // If there are any duplicates, revert.
        if (terminals.length > 1) {
            for (uint256 i; i < terminals.length;) {
                for (uint256 j = i + 1; j < terminals.length;) {
                    if (terminals[i] == terminals[j]) revert JBDirectory_DuplicateTerminals(terminals[i]);
                    unchecked {
                        ++j;
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }
        emit SetTerminals({projectId: projectId, terminals: terminals, caller: msg.sender});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Look up the terminal where payments in a given token should be sent for a project. Returns the
    /// explicitly-set primary terminal, or falls back to the first terminal in the project's list that accepts the
    /// token. Returns the zero address if no terminal accepts the token.
    /// @param projectId The ID of the project to get the primary terminal of.
    /// @param token The token that the terminal accepts.
    /// @return The primary terminal's address.
    function primaryTerminalOf(uint256 projectId, address token) external view override returns (IJBTerminal) {
        // Keep a reference to the primary terminal for the provided project ID and token.
        IJBTerminal primaryTerminal = _primaryTerminalOf[projectId][token];

        // If a primary terminal for the token was explicitly set and it's one of the project's terminals, return it.
        if (
            primaryTerminal != IJBTerminal(address(0))
                && isTerminalOf({projectId: projectId, terminal: primaryTerminal})
        ) {
            return primaryTerminal;
        }

        // Keep a storage reference to the project's terminals to avoid copying the array to memory.
        IJBTerminal[] storage terminals = _terminalsOf[projectId];

        // Keep a reference to the number of terminals the project has.
        uint256 numberOfTerminals = terminals.length;

        // Return the first terminal which accepts the specified token.
        for (uint256 i; i < numberOfTerminals;) {
            // Keep a reference to the terminal being iterated on.
            IJBTerminal terminal = terminals[i];

            // If the terminal accepts the specified token, return it.
            if (terminal.accountingContextForTokenOf({projectId: projectId, token: token}).token != address(0)) {
                return terminal;
            }
            unchecked {
                ++i;
            }
        }

        // Not found.
        return IJBTerminal(address(0));
    }

    /// @notice Get all terminals registered for a project. Terminals are the contracts that hold a project's funds and
    /// process payments and cash outs on its behalf.
    /// @param projectId The ID of the project to get the terminals of.
    /// @return An array of the project's terminal addresses.
    function terminalsOf(uint256 projectId) external view override returns (IJBTerminal[] memory) {
        return _terminalsOf[projectId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Check whether a specific terminal is in a project's registered terminal list.
    /// @param projectId The ID of the project to check.
    /// @param terminal The terminal to check for.
    /// @return A flag indicating whether the project uses the terminal.
    function isTerminalOf(uint256 projectId, IJBTerminal terminal) public view override returns (bool) {
        // Keep a storage reference to the project's terminals to avoid copying the array to memory.
        IJBTerminal[] storage terminals = _terminalsOf[projectId];

        // Keep a reference to the number of terminals the project has.
        uint256 numberOfTerminals = terminals.length;

        // Loop through and return true if the terminal is found.
        for (uint256 i; i < numberOfTerminals;) {
            if (terminals[i] == terminal) return true;
            unchecked {
                ++i;
            }
        }

        // Otherwise, return false.
        return false;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice If a terminal hasn't already been added to a project's list of terminals, add it.
    /// @dev The project's ruleset must have `allowSetTerminals` set to `true`.
    /// @param projectId The ID of the project to add the terminal to.
    /// @param terminal The terminal to add.
    function _addTerminalIfNeeded(uint256 projectId, IJBTerminal terminal) internal {
        // Ensure that the terminal has not already been added.
        if (isTerminalOf({projectId: projectId, terminal: terminal})) return;

        // Keep a reference to the current controller.
        IERC165 controller = controllerOf[projectId];

        // Get a reference to a flag indicating whether the project is allowed to set its terminals.
        bool allowSetTerminals = !controller.supportsInterface(type(IJBDirectoryAccessControl).interfaceId)
            || IJBDirectoryAccessControl(address(controller)).setTerminalsAllowed(projectId);

        // The project's ruleset must allow setting terminals.
        if (!allowSetTerminals) {
            revert JBDirectory_SetTerminalsNotAllowed(projectId);
        }

        // Add the new terminal.
        _terminalsOf[projectId].push(terminal);

        emit AddTerminal({projectId: projectId, terminal: terminal, caller: msg.sender});
    }
}
