// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutHook} from "./IJBCashOutHook.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {JBAfterCashOutRecordedContext} from "../structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "../structs/JBRuleset.sol";

/// @notice A terminal that can be cashed out from.
interface IJBCashOutTerminal is IJBTerminal {
    /// @notice A cash out was processed for a project.
    /// @param rulesetId The ID of the ruleset during the cash out.
    /// @param rulesetCycleNumber The cycle number of the ruleset during the cash out.
    /// @param projectId The ID of the project to cash out from.
    /// @param holder The address whose tokens were cashed out.
    /// @param beneficiary The address that received the reclaimed funds.
    /// @param cashOutCount The number of tokens cashed out.
    /// @param cashOutTaxRate The cash out tax rate applied, out of `JBConstants.MAX_CASH_OUT_TAX_RATE`.
    /// @param reclaimAmount The amount of funds reclaimed.
    /// @param metadata Extra metadata associated with the cash out.
    /// @param caller The address that called the cash out function.
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

    /// @notice A cash out hook was called after a cash out was recorded.
    /// @param hook The cash out hook that was called.
    /// @param context The context passed to the hook.
    /// @param specificationAmount The amount specified for the hook.
    /// @param fee The fee taken from the hook's amount.
    /// @param caller The address that called the cash out function.
    event HookAfterRecordCashOut(
        IJBCashOutHook indexed hook,
        JBAfterCashOutRecordedContext context,
        uint256 specificationAmount,
        uint256 fee,
        address caller
    );

    /// @notice Simulates cashing out project tokens from this terminal without modifying state.
    /// @param holder The address cashing out tokens.
    /// @param projectId The ID of the project cashing out tokens.
    /// @param cashOutCount The number of project tokens to cash out.
    /// @param tokenToReclaim The token to reclaim from the project's surplus.
    /// @param beneficiary The address that would receive the reclaimed tokens.
    /// @param metadata Extra data to send to the data hook and cash out hooks.
    /// @return ruleset The project's current ruleset.
    /// @return reclaimAmount The amount of tokens that would be reclaimed from the project's surplus.
    /// @return cashOutTaxRate The cash out tax rate that would be applied.
    /// @return hookSpecifications Any cash out hook specifications from the data hook.
    function previewCashOutFrom(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        );

    /// @notice Burn a holder's project tokens to reclaim a proportional share of the project's surplus (paid out as a
    /// terminal token).
    /// @param holder The address whose project tokens are being burned.
    /// @param projectId The ID of the project whose project tokens are being burned.
    /// @param cashOutCount The number of project tokens to burn.
    /// @param tokenToReclaim The terminal token to reclaim from the project's surplus.
    /// @param minTokensReclaimed The minimum number of terminal tokens that must be reclaimed.
    /// @param beneficiary The address to send the reclaimed terminal tokens to.
    /// @param metadata Extra data to send to the data hook and cash out hooks.
    /// @return reclaimAmount The number of terminal tokens reclaimed from the project's surplus.
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

    /// @notice Burn a holder's project tokens and atomically pay the reclaim into another project. The
    /// destination terminal is whichever terminal the directory has registered as the beneficiary project's
    /// primary terminal for `tokenToReclaim` (which may itself be a router that swaps before paying).
    /// Cashout-side hooks (if specified by the data hook) execute additively.
    /// @dev The source-side cashout fee is skipped. Round-trip fee preservation is enforced by snapshotting
    /// the beneficiary project's accounting-context balances on this terminal before and after the routing,
    /// and crediting `_feeFreeSurplusOf` by the per-token delta on each context that grew. The beneficiary
    /// project's current ruleset can set `pauseCrossProjectFeeFreeInflows` to opt out.
    /// @param holder The address whose project tokens are being burned.
    /// @param projectId The ID of the project whose project tokens are being burned.
    /// @param cashOutCount The number of project tokens to burn.
    /// @param tokenToReclaim The terminal token reclaimed from the source project's surplus.
    /// @param beneficiaryProjectId The destination project.
    /// @param beneficiary The address that receives the newly minted tokens of the destination project.
    /// @param minTokensOut The minimum number of destination-project tokens that must be minted; reverts otherwise.
    /// @param cashOutMetadata Forwarded to the source project's data hook and any cashout hook specifications.
    /// @param payMetadata Forwarded to the destination project's pay flow.
    /// @return reclaimAmount The gross reclaim amount returned by the store.
    /// @return beneficiaryTokenCount The number of destination-project tokens minted to `beneficiary`.
    function cashOutAsPaymentToProjectOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 beneficiaryProjectId,
        address beneficiary,
        uint256 minTokensOut,
        bytes calldata cashOutMetadata,
        bytes calldata payMetadata
    )
        external
        returns (uint256 reclaimAmount, uint256 beneficiaryTokenCount);
}
