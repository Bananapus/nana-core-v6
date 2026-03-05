// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBCurrencyAmount} from "./../structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "./../structs/JBFundAccessLimitGroup.sol";

/// @notice Stores fund access limits (payout limits and surplus allowances) for each project.
interface IJBFundAccessLimits {
    event SetFundAccessLimits(
        uint256 indexed rulesetId,
        uint256 indexed projectId,
        JBFundAccessLimitGroup fundAccessLimitGroup,
        address caller
    );

    /// @notice Returns the payout limit for a project, ruleset, terminal, token, and currency.
    /// @param projectId The ID of the project to get the payout limit of.
    /// @param rulesetId The ID of the ruleset the limit applies within.
    /// @param terminal The terminal the limit applies to.
    /// @param token The token the limit is denominated in.
    /// @param currency The currency the limit is denominated in.
    /// @return payoutLimit The payout limit.
    function payoutLimitOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token,
        uint256 currency
    )
        external
        view
        returns (uint256 payoutLimit);

    /// @notice Returns all payout limits for a project, ruleset, terminal, and token.
    /// @param projectId The ID of the project to get the payout limits of.
    /// @param rulesetId The ID of the ruleset the limits apply within.
    /// @param terminal The terminal the limits apply to.
    /// @param token The token the limits are denominated in.
    /// @return payoutLimits The payout limits as an array of currency-amount pairs.
    function payoutLimitsOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token
    )
        external
        view
        returns (JBCurrencyAmount[] memory payoutLimits);

    /// @notice Returns the surplus allowance for a project, ruleset, terminal, token, and currency.
    /// @param projectId The ID of the project to get the surplus allowance of.
    /// @param rulesetId The ID of the ruleset the allowance applies within.
    /// @param terminal The terminal the allowance applies to.
    /// @param token The token the allowance is denominated in.
    /// @param currency The currency the allowance is denominated in.
    /// @return surplusAllowance The surplus allowance.
    function surplusAllowanceOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token,
        uint256 currency
    )
        external
        view
        returns (uint256 surplusAllowance);

    /// @notice Returns all surplus allowances for a project, ruleset, terminal, and token.
    /// @param projectId The ID of the project to get the surplus allowances of.
    /// @param rulesetId The ID of the ruleset the allowances apply within.
    /// @param terminal The terminal the allowances apply to.
    /// @param token The token the allowances are denominated in.
    /// @return surplusAllowances The surplus allowances as an array of currency-amount pairs.
    function surplusAllowancesOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token
    )
        external
        view
        returns (JBCurrencyAmount[] memory surplusAllowances);

    /// @notice Sets the fund access limits for a project's ruleset.
    /// @param projectId The ID of the project to set the fund access limits of.
    /// @param rulesetId The ID of the ruleset the limits apply within.
    /// @param fundAccessLimitGroups An array of payout limits and surplus allowances for each terminal.
    function setFundAccessLimitsFor(
        uint256 projectId,
        uint256 rulesetId,
        JBFundAccessLimitGroup[] calldata fundAccessLimitGroups
    )
        external;
}
