// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBFeelessAddresses} from "./interfaces/IJBFeelessAddresses.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";

/// @notice A registry of addresses exempt from the protocol's 2.5% fee. Feeless addresses don't incur fees on
/// payouts they receive, surplus allowance they use, or cash outs where they are the beneficiary.
/// @dev Global feeless status is managed by the contract owner (typically the protocol multisig).
/// @dev Per-project feeless status is managed by the project owner or an operator with the `SET_FEELESS_ADDRESS`
/// permission.
contract JBFeelessAddresses is Ownable, JBPermissioned, IJBFeelessAddresses, IERC165 {
    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Check if the specified address is feeless globally.
    /// @dev Feeless addresses can receive payouts without incurring a fee.
    /// @dev Feeless addresses can use the surplus allowance without incurring a fee.
    /// @dev Feeless addresses can be the beneficiary of cash outs without incurring a fee.
    /// @custom:param addr The address to check.
    mapping(address addr => bool) public override isFeeless;

    /// @notice Check if the specified address is feeless for a specific project.
    /// @custom:param projectId The ID of the project.
    /// @custom:param addr The address to check.
    mapping(uint256 projectId => mapping(address addr => bool)) public override isFeelessForProject;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param owner This contract's owner.
    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    constructor(address owner, IJBPermissions permissions, IJBProjects projects)
        Ownable(owner)
        JBPermissioned(permissions)
    {
        PROJECTS = projects;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Add or remove an address from the global fee-exempt list. Feeless addresses don't pay the 2.5% protocol
    /// fee on payouts received, surplus allowance used, or cash outs where they're the beneficiary.
    /// @dev Can only be called by this contract's owner (typically the protocol multisig).
    /// @param addr The address to set as feeless or not feeless.
    /// @param flag Whether the address should be feeless (`true`) or not feeless (`false`).
    function setFeelessAddress(address addr, bool flag) external virtual override onlyOwner {
        isFeeless[addr] = flag;

        emit SetFeelessAddress({addr: addr, isFeeless: flag, caller: _msgSender()});
    }

    /// @notice Add or remove an address from a project's fee-exempt list.
    /// @dev Can only be called by the project owner or an operator with the `SET_FEELESS_ADDRESS` permission.
    /// @param projectId The ID of the project to set the feeless status for.
    /// @param addr The address to set as feeless or not feeless for the project.
    /// @param flag Whether the address should be feeless for the project (`true`) or not (`false`).
    function setFeelessAddressFor(uint256 projectId, address addr, bool flag) external virtual override {
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_FEELESS_ADDRESS
        });

        isFeelessForProject[projectId][addr] = flag;

        emit SetFeelessAddressFor({projectId: projectId, addr: addr, isFeeless: flag, caller: _msgSender()});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns whether the specified address is feeless for a specific project, considering both global and
    /// per-project feeless status.
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the address is feeless (globally or for the project).
    function isFeelessFor(address addr, uint256 projectId) external view override returns (bool) {
        return isFeeless[addr] || isFeelessForProject[projectId][addr];
    }

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBFeelessAddresses).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
