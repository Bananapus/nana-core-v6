// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBCurrencyAmount} from "./JBCurrencyAmount.sol";

/// @notice Defines how much a project can withdraw from a specific terminal and token during a ruleset.
/// @dev A ruleset configuration should include at most one group for each `(terminal, token)` pair.
/// @dev Example — payout limit of 5 USD in an ETH terminal: the project can distribute up to 5 USD worth of ETH to
/// its splits per ruleset cycle. Example — surplus allowance of 5 USD: the project owner can pull up to 5 USD
/// worth of ETH from the surplus (balance above payout limits) during the ruleset.
/// @dev Multiple limits in different currencies are additive within their respective reset windows.
/// @dev Amounts use the same decimal precision as the terminal token (e.g. 18 for ETH, 6 for USDC).
/// @custom:member terminal The terminal address these limits apply to.
/// @custom:member token The token address within that terminal these limits apply to.
/// @custom:member payoutLimits Maximum amounts distributable to splits per ruleset cycle, each in a specific currency.
/// @custom:member surplusAllowances Maximum amounts withdrawable from surplus per ruleset, each in a specific currency.
struct JBFundAccessLimitGroup {
    address terminal;
    address token;
    JBCurrencyAmount[] payoutLimits;
    JBCurrencyAmount[] surplusAllowances;
}
