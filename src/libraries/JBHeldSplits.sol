// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBSplit} from "../structs/JBSplit.sol";

/// @notice Holds a split's share when its recipient cannot take it, so anyone can retry it later. Used by the
/// terminal for payouts and by the controller for reserved tokens: a failed split is never forgiven, skipped, burned
/// or rerouted, so the gas a caller picks can never change who the share belongs to.
/// @dev An internal library: the compiler inlines it into the terminal and the controller.
library JBHeldSplits {
    /// @notice A split's share could not be delivered, so it is held until a retry succeeds.
    /// @param projectId The ID of the project the share is from.
    /// @param token The token the share is in.
    /// @param split The split the share is held for, with a resolved beneficiary. Hash it to read the held amount.
    /// @param amount The amount held.
    /// @param reason The revert reason.
    event HoldSplit(uint256 indexed projectId, address indexed token, JBSplit split, uint256 amount, bytes reason);

    /// @notice A held share was retried and delivered.
    /// @param projectId The ID of the project the share is from.
    /// @param token The token the share is in.
    /// @param split The split that received the share.
    /// @param amount The amount that was held.
    /// @param netAmount The amount the recipient received after fees.
    /// @param caller The address that retried the delivery.
    event ProcessHeldSplit(
        uint256 indexed projectId,
        address indexed token,
        JBSplit split,
        uint256 amount,
        uint256 netAmount,
        address caller
    );

    error JBHeldSplits_NothingHeld(uint256 projectId, address token, bytes32 splitHash);

    /// @notice Holds a split's share.
    /// @param heldOf The caller's held share ledger.
    /// @param projectId The ID of the project the share is from.
    /// @param token The token the share is in.
    /// @param split The split the share was for, with its beneficiary already resolved (never the zero address for a
    /// direct payout), so a later retry cannot redirect the share to whoever retries.
    /// @param amount The amount to hold.
    /// @param reason The revert reason.
    function hold(
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldOf,
        uint256 projectId,
        address token,
        JBSplit memory split,
        uint256 amount,
        bytes memory reason
    )
        internal
    {
        heldOf[projectId][token][keccak256(abi.encode(split))] += amount;

        emit HoldSplit({projectId: projectId, token: token, split: split, amount: amount, reason: reason});
    }

    /// @notice Takes a held share out of the ledger so the caller can retry delivering it.
    /// @param heldOf The caller's held share ledger.
    /// @param projectId The ID of the project the share is from.
    /// @param token The token the share is in.
    /// @param split The held split.
    /// @return amount The amount that was held.
    /// @return splitHash The key the share was held under.
    function take(
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldOf,
        uint256 projectId,
        address token,
        JBSplit memory split
    )
        internal
        returns (uint256 amount, bytes32 splitHash)
    {
        splitHash = keccak256(abi.encode(split));
        amount = heldOf[projectId][token][splitHash];
        if (amount == 0) revert JBHeldSplits_NothingHeld({projectId: projectId, token: token, splitHash: splitHash});
        delete heldOf[projectId][token][splitHash];
    }

    /// @notice Emits `ProcessHeldSplit` for a delivered share.
    /// @param projectId The ID of the project the share is from.
    /// @param token The token the share is in.
    /// @param split The split that received the share.
    /// @param amount The amount that was held.
    /// @param netAmount The amount the recipient received after fees.
    /// @param caller The address that retried the delivery.
    function processed(
        uint256 projectId,
        address token,
        JBSplit memory split,
        uint256 amount,
        uint256 netAmount,
        address caller
    )
        internal
    {
        emit ProcessHeldSplit({
            projectId: projectId, token: token, split: split, amount: amount, netAmount: netAmount, caller: caller
        });
    }
}
