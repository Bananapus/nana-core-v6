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
    /// @dev `caller` is the outer caller that triggered the fee-bearing terminal operation (as resolved by the
    /// terminal's `_msgSender()`, so ERC-2771 meta-tx forwarders are unwrapped). It is `address(0)` when the registry
    /// is queried without a caller hint (e.g. a direct off-chain `eth_call` to the registry). Use `caller` together
    /// with `addr` to scope grants: e.g. an ecosystem router can be feeless ONLY when it is itself the entity calling
    /// the terminal (so it gets fee-free cash-outs when zapping, but does NOT get feeless status when it merely
    /// appears as a split recipient of someone else's payout).
    /// @param projectId The ID of the project the fee would be charged on behalf of.
    /// @param addr The address being checked, typically a payout recipient, surplus allowance beneficiary, or cash-out
    /// beneficiary.
    /// @param caller The outer caller that initiated the terminal operation, or `address(0)` if not provided.
    /// @return A flag indicating whether the address is feeless for the project under the hook's custom logic.
    function isFeeless(uint256 projectId, address addr, address caller) external view returns (bool);
}
