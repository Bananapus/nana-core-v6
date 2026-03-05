// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBPrices} from "./IJBPrices.sol";
import {IJBRulesets} from "./IJBRulesets.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {JBAccountingContext} from "./../structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "./../structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "./../structs/JBPayHookSpecification.sol";
import {JBRuleset} from "./../structs/JBRuleset.sol";
import {JBTokenAmount} from "./../structs/JBTokenAmount.sol";

/// @notice Manages the bookkeeping for payments, cash outs, payouts, and surplus allowance usage for terminals.
interface IJBTerminalStore {
    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The contract that stores prices for each project.
    function PRICES() external view returns (IJBPrices);

    /// @notice The contract storing and managing project rulesets.
    function RULESETS() external view returns (IJBRulesets);

    /// @notice Returns the balance of a terminal for a project and token.
    /// @param terminal The terminal to get the balance of.
    /// @param projectId The ID of the project to get the balance for.
    /// @param token The token to get the balance of.
    /// @return The balance.
    function balanceOf(address terminal, uint256 projectId, address token) external view returns (uint256);

    /// @notice Returns the amount of payout limit used by a terminal for a project in a given cycle.
    /// @param terminal The terminal to get the used payout limit of.
    /// @param projectId The ID of the project.
    /// @param token The token the payout limit is denominated in.
    /// @param rulesetCycleNumber The cycle number to get the used payout limit for.
    /// @param currency The currency the payout limit is denominated in.
    /// @return The amount of payout limit used.
    function usedPayoutLimitOf(
        address terminal,
        uint256 projectId,
        address token,
        uint256 rulesetCycleNumber,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the amount of surplus allowance used by a terminal for a project in a given ruleset.
    /// @param terminal The terminal to get the used surplus allowance of.
    /// @param projectId The ID of the project.
    /// @param token The token the surplus allowance is denominated in.
    /// @param rulesetId The ID of the ruleset to get the used surplus allowance for.
    /// @param currency The currency the surplus allowance is denominated in.
    /// @return The amount of surplus allowance used.
    function usedSurplusAllowanceOf(
        address terminal,
        uint256 projectId,
        address token,
        uint256 rulesetId,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the reclaimable surplus for a project given a cash-out count, total supply, and surplus.
    /// @param projectId The ID of the project.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param totalSupply The total token supply.
    /// @param surplus The project's surplus.
    /// @return The reclaimable surplus amount.
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 surplus
    )
        external
        view
        returns (uint256);

    /// @notice Returns the reclaimable surplus for a project across multiple terminals.
    /// @param projectId The ID of the project.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param terminals The terminals to include in the surplus calculation.
    /// @param accountingContexts The accounting contexts to include.
    /// @param decimals The number of decimals to express the result with.
    /// @param currency The currency to express the result in.
    /// @return The reclaimable surplus amount.
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        IJBTerminal[] calldata terminals,
        JBAccountingContext[] calldata accountingContexts,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the current surplus for a terminal and project.
    /// @param terminal The terminal to get the surplus of.
    /// @param projectId The ID of the project.
    /// @param accountingContexts The accounting contexts to include.
    /// @param decimals The number of decimals to express the result with.
    /// @param currency The currency to express the result in.
    /// @return The current surplus.
    function currentSurplusOf(
        address terminal,
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the current total surplus for a project across all terminals.
    /// @param projectId The ID of the project.
    /// @param decimals The number of decimals to express the result with.
    /// @param currency The currency to express the result in.
    /// @return The current total surplus.
    function currentTotalSurplusOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Records a balance addition for a project.
    /// @param projectId The ID of the project.
    /// @param token The token being added.
    /// @param amount The amount being added.
    function recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) external;

    /// @notice Records a payment to a project.
    /// @param payer The address of the payer.
    /// @param amount The amount being paid.
    /// @param projectId The ID of the project being paid.
    /// @param beneficiary The address to mint project tokens to.
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return tokenCount The number of project tokens minted.
    /// @return hookSpecifications Any pay hook specifications from the data hook.
    function recordPaymentFrom(
        address payer,
        JBTokenAmount memory amount,
        uint256 projectId,
        address beneficiary,
        bytes calldata metadata
    )
        external
        returns (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications);

    /// @notice Records a payout from a project.
    /// @param projectId The ID of the project paying out.
    /// @param accountingContext The accounting context of the token being paid out.
    /// @param amount The amount being paid out.
    /// @param currency The currency the amount is denominated in.
    /// @return ruleset The project's current ruleset.
    /// @return amountPaidOut The amount paid out in the token's native decimals.
    function recordPayoutFor(
        uint256 projectId,
        JBAccountingContext calldata accountingContext,
        uint256 amount,
        uint256 currency
    )
        external
        returns (JBRuleset memory ruleset, uint256 amountPaidOut);

    /// @notice Records a cash out from a project.
    /// @param holder The address cashing out.
    /// @param projectId The ID of the project being cashed out from.
    /// @param cashOutCount The number of project tokens being cashed out.
    /// @param accountingContext The accounting context of the token being reclaimed.
    /// @param balanceAccountingContexts The accounting contexts to include in the balance calculation.
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return reclaimAmount The amount reclaimed.
    /// @return cashOutTaxRate The cash out tax rate applied.
    /// @return hookSpecifications Any cash out hook specifications from the data hook.
    function recordCashOutFor(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        JBAccountingContext calldata accountingContext,
        JBAccountingContext[] calldata balanceAccountingContexts,
        bytes calldata metadata
    )
        external
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        );

    /// @notice Records a terminal migration for a project.
    /// @param projectId The ID of the project being migrated.
    /// @param token The token being migrated.
    /// @return balance The balance that was migrated.
    function recordTerminalMigration(uint256 projectId, address token) external returns (uint256 balance);

    /// @notice Records surplus allowance usage for a project.
    /// @param projectId The ID of the project using surplus allowance.
    /// @param accountingContext The accounting context of the token being used.
    /// @param amount The amount of surplus allowance to use.
    /// @param currency The currency the amount is denominated in.
    /// @return ruleset The project's current ruleset.
    /// @return usedAmount The amount used in the token's native decimals.
    function recordUsedAllowanceOf(
        uint256 projectId,
        JBAccountingContext calldata accountingContext,
        uint256 amount,
        uint256 currency
    )
        external
        returns (JBRuleset memory ruleset, uint256 usedAmount);
}
