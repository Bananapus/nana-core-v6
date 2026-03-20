// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBPayHook} from "./IJBPayHook.sol";
import {JBAccountingContext} from "../structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "../structs/JBAfterPayRecordedContext.sol";
import {JBCashOutHookSpecification} from "../structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "../structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../structs/JBRuleset.sol";

/// @notice A terminal that accepts payments and can be migrated.
interface IJBTerminal is IERC165 {
    /// @notice Funds were added to a project's balance.
    /// @param projectId The ID of the project that received the funds.
    /// @param amount The amount of tokens added.
    /// @param returnedFees The amount of fees returned.
    /// @param memo A memo associated with the addition.
    /// @param metadata Extra metadata associated with the addition.
    /// @param caller The address that added the funds.
    event AddToBalance(
        uint256 indexed projectId, uint256 amount, uint256 returnedFees, string memo, bytes metadata, address caller
    );

    /// @notice A pay hook was called after a payment was recorded.
    /// @param hook The pay hook that was called.
    /// @param context The context passed to the hook.
    /// @param specificationAmount The amount specified for the hook.
    /// @param caller The address that called the pay function.
    event HookAfterRecordPay(
        IJBPayHook indexed hook, JBAfterPayRecordedContext context, uint256 specificationAmount, address caller
    );

    /// @notice A project's balance was migrated to another terminal.
    /// @param projectId The ID of the project that was migrated.
    /// @param token The token that was migrated.
    /// @param to The terminal the balance was migrated to.
    /// @param amount The amount of tokens migrated.
    /// @param caller The address that called the migrate function.
    event MigrateTerminal(
        uint256 indexed projectId, address indexed token, IJBTerminal indexed to, uint256 amount, address caller
    );

    /// @notice A payment was made to a project.
    /// @param rulesetId The ID of the ruleset during the payment.
    /// @param rulesetCycleNumber The cycle number of the ruleset during the payment.
    /// @param projectId The ID of the project that received the payment.
    /// @param payer The address that made the payment.
    /// @param beneficiary The address that received the project tokens.
    /// @param amount The amount of tokens paid.
    /// @param newlyIssuedTokenCount The number of project tokens minted.
    /// @param memo A memo associated with the payment.
    /// @param metadata Extra metadata associated with the payment.
    /// @param caller The address that called the pay function.
    event Pay(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address payer,
        address beneficiary,
        uint256 amount,
        uint256 newlyIssuedTokenCount,
        string memo,
        bytes metadata,
        address caller
    );

    /// @notice An accounting context was set for a project's token.
    /// @param projectId The ID of the project the accounting context was set for.
    /// @param context The accounting context that was set.
    /// @param caller The address that set the accounting context.
    event SetAccountingContext(uint256 indexed projectId, JBAccountingContext context, address caller);

    /// @notice Returns the accounting context for a project's token.
    /// @param projectId The ID of the project to get the accounting context of.
    /// @param token The token to get the accounting context for.
    /// @return The accounting context for the project's token.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory);

    /// @notice Returns all accounting contexts for a project.
    /// @param projectId The ID of the project to get the accounting contexts of.
    /// @return The accounting contexts for the project.
    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory);

    /// @notice Returns a project's current surplus for a set of accounting contexts.
    /// @param projectId The ID of the project to get the surplus of.
    /// @param accountingContexts The accounting contexts to include in the surplus calculation.
    /// @param decimals The number of decimals to express the surplus with.
    /// @param currency The currency to express the surplus in.
    /// @return The project's current surplus.
    function currentSurplusOf(
        uint256 projectId,
        JBAccountingContext[] memory accountingContexts,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Simulates cashing out project tokens from this terminal without modifying state.
    /// @param holder The address whose tokens are being cashed out.
    /// @param projectId The ID of the project whose tokens are being cashed out.
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

    /// @notice Simulates paying a project through this terminal without modifying state.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in.
    /// @param amount The amount of tokens being paid.
    /// @param beneficiary The address to mint project tokens to.
    /// @param metadata Extra data to pass along to the data hook and pay hooks.
    /// @return ruleset The project's current ruleset.
    /// @return beneficiaryTokenCount The number of project tokens that would be minted for the beneficiary.
    /// @return reservedTokenCount The number of project tokens that would be reserved.
    /// @return hookSpecifications Any pay hook specifications from the data hook.
    function previewPayFor(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        );

    /// @notice Adds accounting contexts for a project's tokens.
    /// @param projectId The ID of the project to add accounting contexts for.
    /// @param accountingContexts The accounting contexts to add.
    function addAccountingContextsFor(uint256 projectId, JBAccountingContext[] calldata accountingContexts) external;

    /// @notice Adds funds to a project's balance.
    /// @param projectId The ID of the project to add funds to.
    /// @param token The token being added.
    /// @param amount The amount of tokens being added.
    /// @param shouldReturnHeldFees Whether held fees should be returned based on the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Extra data to pass along to the emitted event.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable;

    /// @notice Migrates a project's funds from this terminal to another.
    /// @param projectId The ID of the project being migrated.
    /// @param token The address of the token being migrated.
    /// @param to The terminal to migrate to.
    /// @return balance The amount of funds that were migrated.
    function migrateBalanceOf(uint256 projectId, address token, IJBTerminal to) external returns (uint256 balance);

    /// @notice Pays a project in a specified token.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in.
    /// @param amount The amount of tokens being paid.
    /// @param beneficiary The address to mint project tokens to.
    /// @param minReturnedTokens The minimum number of project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Extra data to pass along to the pay hooks.
    /// @return beneficiaryTokenCount The number of tokens minted for the beneficiary.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount);
}
