// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutHook} from "./IJBCashOutHook.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {JBAfterCashOutRecordedContext} from "../structs/JBAfterCashOutRecordedContext.sol";

/// @notice A terminal that can be cashed out from.
interface IJBCashOutTerminal is IJBTerminal {
    event HookAfterRecordCashOut(
        IJBCashOutHook indexed hook,
        JBAfterCashOutRecordedContext context,
        uint256 specificationAmount,
        uint256 fee,
        address caller
    );
    event CashOutTokens(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address holder,
        address beneficiary,
        uint256 cashOutCount,
        uint256 cashOutTaxRate,
        uint256 reclaimAmount,
        bytes metadata,
        address caller
    );

    /// @notice Cashes out a holder's tokens for a project, reclaiming the token's proportional share of the project's
    /// surplus.
    /// @param holder The address whose tokens are being cashed out.
    /// @param projectId The ID of the project whose tokens are being cashed out.
    /// @param cashOutCount The number of project tokens to cash out.
    /// @param tokenToReclaim The token to reclaim from the project's surplus.
    /// @param minTokensReclaimed The minimum number of terminal tokens expected to be reclaimed.
    /// @param beneficiary The address to send the reclaimed tokens to.
    /// @param metadata Extra data to send to the data hook and cash out hooks.
    /// @return reclaimAmount The amount of tokens reclaimed from the project's surplus.
    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        returns (uint256 reclaimAmount);
}
