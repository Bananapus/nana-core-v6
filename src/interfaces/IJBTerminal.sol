// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBPayHook} from "./IJBPayHook.sol";
import {JBAccountingContext} from "../structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "../structs/JBAfterPayRecordedContext.sol";

/// @notice A terminal that accepts payments and can be migrated.
interface IJBTerminal is IERC165 {
    event AddToBalance(
        uint256 indexed projectId, uint256 amount, uint256 returnedFees, string memo, bytes metadata, address caller
    );
    event HookAfterRecordPay(
        IJBPayHook indexed hook, JBAfterPayRecordedContext context, uint256 specificationAmount, address caller
    );

    event MigrateTerminal(
        uint256 indexed projectId, address indexed token, IJBTerminal indexed to, uint256 amount, address caller
    );
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
