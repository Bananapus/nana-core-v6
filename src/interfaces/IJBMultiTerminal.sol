// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutTerminal} from "./IJBCashOutTerminal.sol";
import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBFeeTerminal} from "./IJBFeeTerminal.sol";
import {IJBPayoutTerminal} from "./IJBPayoutTerminal.sol";
import {IJBPermitTerminal} from "./IJBPermitTerminal.sol";
import {IJBProjects} from "./IJBProjects.sol";
import {IJBSplits} from "./IJBSplits.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {IJBTerminalStore} from "./IJBTerminalStore.sol";
import {IJBTokens} from "./IJBTokens.sol";

/// @notice The interface for the protocol's multi-token payment terminal. Accepts ETH and ERC-20 payments, processes
/// cash outs (token redemptions), distributes payouts to splits, manages surplus allowance withdrawals, and handles
/// the 2.5% protocol fee lifecycle. The primary entry point for all fund movement in Juicebox.
interface IJBMultiTerminal is IJBTerminal, IJBFeeTerminal, IJBCashOutTerminal, IJBPayoutTerminal, IJBPermitTerminal {
    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The contract that stores splits for each project.
    function SPLITS() external view returns (IJBSplits);

    /// @notice The terminal store that manages this terminal's data.
    function STORE() external view returns (IJBTerminalStore);

    /// @notice The contract that manages token minting and burning.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The cumulative amount of fee-free intra-terminal payouts a project has received for a given token.
    /// @dev Incremented each time a fee-free payout lands (same terminal, no fee charged) and consumed during
    /// zero-tax cash outs to prevent a round-trip fee bypass (intra-terminal payout -> zero-tax cash out). Exposed
    /// for off-chain indexers and integrating contracts that need to reason about a project's outstanding fee-free
    /// exposure before performing related operations.
    /// @param projectId The ID of the project that received the payout.
    /// @param token The token that was received.
    /// @return The cumulative unconsumed fee-free surplus tracked for the (project, token) pair.
    function feeFreeSurplusOf(uint256 projectId, address token) external view returns (uint256);
}
