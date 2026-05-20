// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBFeelessAddresses} from "./interfaces/IJBFeelessAddresses.sol";
import {IJBFeelessHook} from "./interfaces/IJBFeelessHook.sol";

/// @notice A registry of addresses exempt from the protocol's 2.5% fee. Feeless addresses don't incur fees on
/// payouts they receive, surplus allowance they use, or cash outs where they are the beneficiary.
/// @dev All feeless status is managed by the contract owner (typically the protocol multisig).
/// @dev `projectId = 0` is the wildcard — an address feeless for project 0 is feeless for ALL projects.
contract JBFeelessAddresses is Ownable, IJBFeelessAddresses, IERC165 {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBFeelessAddresses_InvalidFeelessHook(IJBFeelessHook hook);

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Optional hook consulted (in addition to the static mappings) when computing feeless status.
    /// @dev OR'd with the mappings — the hook can only widen the feeless set, never shrink it. `address(0)` disables
    /// hook consultation.
    IJBFeelessHook public override feelessHook;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Raw feeless status per project per address.
    /// @dev `projectId = 0` stores the global (all-project) feeless status.
    mapping(uint256 projectId => mapping(address addr => bool)) internal _isFeelessFor;

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
        _isFeelessFor[0][addr] = flag;

        emit SetFeelessAddress({projectId: 0, addr: addr, isFeeless: flag, caller: _msgSender()});
    }

    /// @notice Add or remove an address from a project's fee-exempt list.
    /// @dev Can only be called by this contract's owner (typically the protocol multisig).
    /// @dev Use `projectId = 0` to set the global (all-project) feeless status.
    /// @param projectId The ID of the project. 0 means all projects.
    /// @param addr The address to set as feeless or not feeless for the project.
    /// @param flag Whether the address should be feeless for the project (`true`) or not (`false`).
    function setFeelessAddressFor(uint256 projectId, address addr, bool flag) external virtual override onlyOwner {
        _isFeelessFor[projectId][addr] = flag;

        emit SetFeelessAddress({projectId: projectId, addr: addr, isFeeless: flag, caller: _msgSender()});
    }

    /// @notice Sets (or clears) the feeless hook consulted by `isFeelessFor`.
    /// @dev Can only be called by this contract's owner (typically the protocol multisig).
    /// @dev If `hook` is non-zero, it must report ERC-165 support for `IJBFeelessHook` or this call reverts.
    /// @param hook The new hook. Pass `address(0)` to disable hook consultation.
    function setFeelessHook(IJBFeelessHook hook) external virtual override onlyOwner {
        if (address(hook) != address(0) && !hook.supportsInterface(type(IJBFeelessHook).interfaceId)) {
            revert JBFeelessAddresses_InvalidFeelessHook(hook);
        }

        feelessHook = hook;

        emit SetFeelessHook({hook: hook, caller: _msgSender()});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns whether the specified address is feeless for a specific project, considering the wildcard
    /// (projectId 0) feeless status, the project-specific feeless status, and the feeless hook (if set).
    /// @dev Calls the caller-aware overload with `caller = address(0)`. Intended for off-chain queries and for
    /// callers that don't have an outer caller to report.
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the address is feeless (globally, for the project, or per the hook).
    function isFeelessFor(address addr, uint256 projectId) external view override returns (bool) {
        return _isFeelessFor3({addr: addr, projectId: projectId, caller: address(0)});
    }

    /// @notice Returns whether the specified address is feeless for a specific project, providing the outer caller
    /// of the fee-bearing operation so hooks can scope grants by who initiated the action.
    /// @dev The static admin-set mappings are caller-agnostic and always apply. The hook (if set) receives `caller`
    /// (typically the terminal's `_msgSender()`) and may use it to narrow its grant — e.g. grant an ecosystem
    /// router feeless cash-outs only when the router itself is the caller, not when it appears as a split recipient
    /// of someone else's payout. Hook is invoked via try/catch — a reverting hook is treated as `false`.
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check.
    /// @param caller The outer caller (typically the terminal's `_msgSender()`).
    /// @return A flag indicating whether the address is feeless.
    function isFeelessFor(
        address addr,
        uint256 projectId,
        address caller
    )
        external
        view
        override
        returns (bool)
    {
        return _isFeelessFor3({addr: addr, projectId: projectId, caller: caller});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBFeelessAddresses).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Shared implementation backing both `isFeelessFor` overloads. Static mappings are caller-agnostic; the
    /// hook (if set) receives the outer caller and may use it to narrow its grant.
    function _isFeelessFor3(address addr, uint256 projectId, address caller) internal view returns (bool) {
        if (_isFeelessFor[0][addr] || _isFeelessFor[projectId][addr]) return true;

        IJBFeelessHook hook = feelessHook;
        if (address(hook) == address(0)) return false;

        try hook.isFeeless({projectId: projectId, addr: addr, caller: caller}) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
}
