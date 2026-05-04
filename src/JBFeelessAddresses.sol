// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBFeelessAddresses} from "./interfaces/IJBFeelessAddresses.sol";

/// @notice A registry of addresses exempt from the protocol's 2.5% fee. Feeless addresses don't incur fees on
/// payouts they receive, surplus allowance they use, or cash outs where they are the beneficiary. Managed by the
/// contract owner (typically the protocol multisig).
contract JBFeelessAddresses is Ownable, IJBFeelessAddresses, IERC165 {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Check if the specified address is feeless.
    /// @dev Feeless addresses can receive payouts without incurring a fee.
    /// @dev Feeless addresses can use the surplus allowance without incurring a fee.
    /// @dev Feeless addresses can be the beneficiary of cash outs without incurring a fee.
    /// @custom:param addr The address to check.
    mapping(address addr => bool) public override isFeeless;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param owner This contract's owner.
    constructor(address owner) Ownable(owner) {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Add or remove an address from the fee-exempt list. Feeless addresses don't pay the 2.5% protocol fee
    /// on payouts received, surplus allowance used, or cash outs where they're the beneficiary.
    /// @dev Can only be called by this contract's owner (typically the protocol multisig).
    /// @param addr The address to set as feeless or not feeless.
    /// @param flag Whether the address should be feeless (`true`) or not feeless (`false`).
    function setFeelessAddress(address addr, bool flag) external virtual override onlyOwner {
        isFeeless[addr] = flag;

        emit SetFeelessAddress({addr: addr, isFeeless: flag, caller: _msgSender()});
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
}
