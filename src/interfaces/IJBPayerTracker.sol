// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Exposes the original payer of a forwarded payment.
/// @dev Implemented by intermediaries that forward value on behalf of a user — `JBProjects` (while forwarding a
/// project creation fee, where the original payer is reported as the new project's owner) and `JBProjectPayer`
/// (while relaying received funds to a project's terminal). A downstream forwarder or router terminal queries this
/// to resolve the payment beneficiary, refund partial-fill leftovers, and attribute credit cash-outs to the true
/// payer instead of the intermediary contract.
interface IJBPayerTracker {
    /// @notice The original payer of the current forwarded payment.
    /// @return payer The original payer address, or `address(0)` if no forwarding is in progress.
    function originalPayer() external view returns (address payer);
}
