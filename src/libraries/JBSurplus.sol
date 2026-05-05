// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "../interfaces/IJBTerminal.sol";

/// @notice Calculates a project's total surplus across all its terminals. Surplus is the amount held beyond what's
/// needed to cover the project's payout limits — it represents the pool available for cash outs and surplus allowance
/// usage. Aggregates across multiple terminals and tokens, converting to a common currency via `JBPrices`.
library JBSurplus {
    /// @notice Gets the total current surplus amount across all of a project's terminals.
    /// @dev This amount changes as the value of the balances changes in relation to the currency used to measure
    /// the project's payout limits.
    /// @param projectId The ID of the project to get the total surplus for.
    /// @param terminals The terminals to look for surplus within.
    /// @param tokens The tokens to include in the surplus calculation. If empty, all tokens are included.
    /// @param decimals The number of decimals that the fixed point surplus result should include.
    /// @param currency The currency that the surplus result should be in terms of.
    /// @return surplus The total surplus of a project's funds in terms of `currency`, as a fixed point number with the
    /// specified number of decimals.
    function currentSurplusOf(
        uint256 projectId,
        IJBTerminal[] memory terminals,
        address[] memory tokens,
        uint256 decimals,
        uint256 currency
    )
        internal
        view
        returns (uint256 surplus)
    {
        // Keep a reference to the number of terminals.
        uint256 numberOfTerminals = terminals.length;

        // Add the current surplus for each terminal.
        for (uint256 i; i < numberOfTerminals;) {
            surplus += terminals[i].currentSurplusOf({
                projectId: projectId, tokens: tokens, decimals: decimals, currency: currency
            });
            unchecked {
                ++i;
            }
        }
    }
}
