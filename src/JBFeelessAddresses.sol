// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBFeelessAddresses} from "./interfaces/IJBFeelessAddresses.sol";

/// @notice A registry of addresses exempt from the protocol's 2.5% fee. Feeless addresses don't incur fees on
/// payouts they receive, surplus allowance they use, or cash outs where they are the beneficiary.
/// @dev All feeless status is managed by the contract owner (typically the protocol multisig).
/// @dev `projectId = 0` is the wildcard — an address feeless for project 0 is feeless for ALL projects.
contract JBFeelessAddresses is Ownable, IJBFeelessAddresses, IERC165 {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Check if the specified address is feeless for a specific project.
    /// @dev `projectId = 0` stores the global (all-project) feeless status.
    /// @custom:param projectId The ID of the project. 0 means all projects.
    /// @custom:param addr The address to check.
    mapping(uint256 projectId => mapping(address addr => bool)) public override isFeelessForProject;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param owner This contract's owner.
    constructor(address owner) Ownable(owner) {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Add or remove an address from the global (all-project) fee-exempt list.
    /// @dev Equivalent to `setFeelessAddressFor(0, addr, flag)`.
    /// @dev Can only be called by this contract's owner (typically the protocol multisig).
    /// @param addr The address to set as feeless or not feeless.
    /// @param flag Whether the address should be feeless (`true`) or not feeless (`false`).
    function setFeelessAddress(address addr, bool flag) external virtual override onlyOwner {
        isFeelessForProject[0][addr] = flag;

        emit SetFeelessAddress({projectId: 0, addr: addr, isFeeless: flag, caller: _msgSender()});
    }

    /// @notice Add or remove an address from a project's fee-exempt list.
    /// @dev Can only be called by this contract's owner (typically the protocol multisig).
    /// @dev Use `projectId = 0` to set the global (all-project) feeless status.
    /// @param projectId The ID of the project. 0 means all projects.
    /// @param addr The address to set as feeless or not feeless for the project.
    /// @param flag Whether the address should be feeless for the project (`true`) or not (`false`).
    function setFeelessAddressFor(uint256 projectId, address addr, bool flag) external virtual override onlyOwner {
        isFeelessForProject[projectId][addr] = flag;

        emit SetFeelessAddress({projectId: projectId, addr: addr, isFeeless: flag, caller: _msgSender()});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns whether the specified address is feeless for a specific project, considering both the wildcard
    /// (projectId 0) and project-specific feeless status.
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the address is feeless (globally or for the project).
    function isFeelessFor(address addr, uint256 projectId) external view override returns (bool) {
        return isFeelessForProject[0][addr] || isFeelessForProject[projectId][addr];
    }

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBFeelessAddresses).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
