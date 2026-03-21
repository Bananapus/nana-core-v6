// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBPrices} from "./IJBPrices.sol";
import {IJBRulesets} from "./IJBRulesets.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {JBAccountingContext} from "../structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "../structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../structs/JBRuleset.sol";
import {JBTokenAmount} from "../structs/JBTokenAmount.sol";

/// @notice Manages the bookkeeping for payments, cash outs, payouts, and surplus allowance usage for terminals.
interface IJBTerminalStore {
    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The contract that stores prices for each project.
    function PRICES() external view returns (IJBPrices);

    /// @notice The contract storing and managing project rulesets.
    function RULESETS() external view returns (IJBRulesets);

    /// @notice Returns the accounting context for a terminal's project token.
    /// @param terminal The terminal the accounting context applies to.
    /// @param projectId The ID of the project.
    /// @param token The token to get the accounting context for.
    /// @return The accounting context.
    function accountingContextOf(
        address terminal,
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory);

    /// @notice Returns all accounting contexts for a terminal's project.
    /// @param terminal The terminal the accounting contexts apply to.
    /// @param projectId The ID of the project.
    /// @return The accounting contexts.
    function accountingContextsOf(
        address terminal,
        uint256 projectId
    )
        external
        view
        returns (JBAccountingContext[] memory);

    /// @notice Returns the balance of a terminal for a project and token.
    /// @param terminal The terminal to get the balance of.
    /// @param projectId The ID of the project to get the balance for.
    /// @param token The token to get the balance of.
    /// @return The balance.
    function balanceOf(address terminal, uint256 projectId, address token) external view returns (uint256);

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

    /// @notice Returns the reclaimable surplus for a project across multiple terminals, considering only specific
    /// tokens.
    /// @param projectId The ID of the project.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param terminals The terminals to include in the surplus calculation. If empty, all project terminals are used.
    /// @param tokens The tokens to include in the surplus calculation.
    /// @param decimals The number of decimals to express the result with.
    /// @param currency The currency to express the result in.
    /// @return The reclaimable surplus amount.
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        IJBTerminal[] calldata terminals,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the current surplus for a project across specified terminals and tokens.
    /// @param projectId The ID of the project.
    /// @param terminals The terminals to include. If empty, all project terminals are used.
    /// @param tokens The tokens to include. If empty, all tokens per terminal are used.
    /// @param decimals The number of decimals to express the result with.
    /// @param currency The currency to express the result in.
    /// @return The current surplus.
    function currentSurplusOf(
        uint256 projectId,
        IJBTerminal[] calldata terminals,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the reclaimable surplus for a project across all terminals using all accounting contexts.
    /// @param projectId The ID of the project.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param decimals The number of decimals to express the result with.
    /// @param currency The currency to express the result in.
    /// @return The reclaimable surplus amount.
    function currentTotalReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
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

    /// @notice Simulates a cash out without modifying state.
    /// @param terminal The terminal to simulate the cash out from.
    /// @param holder The address cashing out.
    /// @param projectId The ID of the project being cashed out from.
    /// @param cashOutCount The number of project tokens being cashed out.
    /// @param tokenToReclaim The token being reclaimed.
    /// @param beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address.
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return reclaimAmount The amount that would be reclaimed.
    /// @return cashOutTaxRate The cash out tax rate that would be applied.
    /// @return hookSpecifications Any cash out hook specifications from the data hook.
    function previewCashOutFrom(
        address terminal,
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
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

    /// @notice Simulates a payment without modifying state.
    /// @param terminal The terminal to simulate the payment from.
    /// @param payer The address of the payer.
    /// @param amount The amount being paid.
    /// @param projectId The ID of the project being paid.
    /// @param beneficiary The address to mint project tokens to.
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return tokenCount The number of project tokens that would be minted, including reserved tokens.
    /// @return hookSpecifications Any pay hook specifications from the data hook.
    function previewPayFrom(
        address terminal,
        address payer,
        JBTokenAmount memory amount,
        uint256 projectId,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications);

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

    /// @notice Records an accounting context for a terminal's project token.
    /// @param projectId The ID of the project.
    /// @param contexts The accounting contexts to record.
    function recordAccountingContextOf(uint256 projectId, JBAccountingContext[] calldata contexts) external;

    /// @notice Records a balance addition for a project.
    /// @param projectId The ID of the project.
    /// @param token The token being added.
    /// @param amount The amount being added.
    function recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) external;

    /// @notice Records a cash out from a project.
    /// @param holder The address cashing out.
    /// @param projectId The ID of the project being cashed out from.
    /// @param cashOutCount The number of project tokens being cashed out.
    /// @param tokenToReclaim The token being reclaimed.
    /// @param beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address. Passed through to data
    /// hooks so they can skip their own fees when value stays in the protocol (e.g. project-to-project routing).
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return reclaimAmount The amount reclaimed.
    /// @return cashOutTaxRate The cash out tax rate applied.
    /// @return hookSpecifications Any cash out hook specifications from the data hook.
    function recordCashOutFor(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
        bytes calldata metadata
    )
        external
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        );

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
    /// @param token The token being paid out.
    /// @param amount The amount being paid out.
    /// @param currency The currency the amount is denominated in.
    /// @return ruleset The project's current ruleset.
    /// @return amountPaidOut The amount paid out in the token's native decimals.
    function recordPayoutFor(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency
    )
        external
        returns (JBRuleset memory ruleset, uint256 amountPaidOut);

    /// @notice Records a terminal migration for a project.
    /// @param projectId The ID of the project being migrated.
    /// @param token The token being migrated.
    /// @return balance The balance that was migrated.
    function recordTerminalMigration(uint256 projectId, address token) external returns (uint256 balance);

    /// @notice Records surplus allowance usage for a project.
    /// @param projectId The ID of the project using surplus allowance.
    /// @param token The token being used.
    /// @param amount The amount of surplus allowance to use.
    /// @param currency The currency the amount is denominated in.
    /// @return ruleset The project's current ruleset.
    /// @return usedAmount The amount used in the token's native decimals.
    function recordUsedAllowanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency
    )
        external
        returns (JBRuleset memory ruleset, uint256 usedAmount);
}
