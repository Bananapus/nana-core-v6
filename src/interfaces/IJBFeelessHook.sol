// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Optional hook that can grant feeless status to addresses based on arbitrary off-chain or on-chain logic.
/// @dev Plugged into `JBFeelessAddresses` by the contract owner. The hook is OR'd with the static feeless mappings,
/// so it can only widen the feeless set, never shrink it.
/// @dev `JBFeelessAddresses` invokes this hook inside a try/catch — a reverting hook is treated as returning `false`,
/// so a broken hook cannot brick the fee path in terminals.
interface IJBFeelessHook is IERC165 {
    /// @notice Returns whether the address should be treated as feeless for the project.
    /// @param projectId The ID of the project the fee would be charged on behalf of.
    /// @param addr The address being checked (typically a payout recipient, surplus allowance beneficiary, or
    /// cash-out beneficiary).
    /// @return A flag indicating whether the address is feeless for the project under the hook's custom logic.
    function isFeeless(uint256 projectId, address addr) external view returns (bool);
}
