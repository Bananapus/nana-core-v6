// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBPayoutTerminal} from "../interfaces/IJBPayoutTerminal.sol";
import {IJBSplits} from "../interfaces/IJBSplits.sol";
import {IJBTerminalStore} from "../interfaces/IJBTerminalStore.sol";
import {JBSplit} from "../structs/JBSplit.sol";
import {JBConstants} from "./JBConstants.sol";

/// @notice Minimal callback surface used only by this library to call back into the terminal's `executePayout(...)`.
/// @dev Kept local to this file because `executePayout(...)` is an implementation detail, not a shared public
/// interface.
interface IJBPayoutSplitGroupExecutor {
    function executePayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        address originalMessageSender
    )
        external
        returns (uint256 netPayoutAmount);
}

/// @notice External library for payout split-group distribution extracted to reduce terminal bytecode.
/// @dev Called via DELEGATECALL from the terminal, so events are emitted from the terminal's address.
library JBPayoutSplitGroupLib {
    event PayoutReverted(uint256 indexed projectId, JBSplit split, uint256 amount, bytes reason, address caller);
    event SendPayoutToSplit(
        uint256 indexed projectId,
        uint256 indexed rulesetId,
        uint256 indexed group,
        JBSplit split,
        uint256 amount,
        uint256 netAmount,
        address caller
    );

    /// @notice Sends payouts to the payout splits group specified in a project's ruleset.
    /// @param splits The splits contract to read splits from.
    /// @param store The terminal store used to restore balance when a payout fails.
    /// @param projectId The ID of the project to send the payouts of.
    /// @param token The address of the token being paid out.
    /// @param rulesetId The ID of the ruleset of the split group being paid.
    /// @param amount The total amount being paid out.
    /// @param caller The original caller of the terminal payout flow.
    /// @return leftoverAmount The leftover amount after split payouts.
    /// @return amountEligibleForFees The amount of payouts that are eligible for fees.
    function sendPayoutsToSplitGroupOf(
        IJBSplits splits,
        IJBTerminalStore store,
        uint256 projectId,
        address token,
        uint256 rulesetId,
        uint256 amount,
        address caller
    )
        external
        returns (uint256 leftoverAmount, uint256 amountEligibleForFees)
    {
        // The total percentage available to split.
        uint256 leftoverPercentage = JBConstants.SPLITS_TOTAL_PERCENT;
        uint256 group = uint256(uint160(token));

        // Get a reference to the project's payout splits.
        JBSplit[] memory payoutSplits = splits.splitsOf({projectId: projectId, rulesetId: rulesetId, groupId: group});

        leftoverAmount = amount;

        // Transfer between all splits.
        for (uint256 i; i < payoutSplits.length; i++) {
            // Get a reference to the split being iterated on.
            JBSplit memory split = payoutSplits[i];

            // The amount to send to the split.
            uint256 payoutAmount = mulDiv(leftoverAmount, split.percent, leftoverPercentage);

            // The final payout amount after taking out any fees.
            uint256 netPayoutAmount = _sendPayoutToSplit({
                store: store, split: split, projectId: projectId, token: token, amount: payoutAmount, caller: caller
            });

            // If the split hook is a feeless address, this payout doesn't incur a fee.
            if (netPayoutAmount != 0 && netPayoutAmount != payoutAmount) {
                amountEligibleForFees += payoutAmount;
            }

            if (payoutAmount != 0) {
                // Subtract from the amount to be sent to the beneficiary.
                unchecked {
                    leftoverAmount -= payoutAmount;
                }
            }

            unchecked {
                // Decrement the leftover percentage.
                leftoverPercentage -= split.percent;
            }

            emit SendPayoutToSplit({
                projectId: projectId,
                rulesetId: rulesetId,
                group: group,
                split: split,
                amount: payoutAmount,
                netAmount: netPayoutAmount,
                caller: caller
            });
        }
    }

    /// @notice Sends a payout to a split.
    /// @param store The terminal store used to restore balance when a payout fails.
    /// @param split The split to pay.
    /// @param projectId The ID of the project the split was specified by.
    /// @param token The address of the token being paid out.
    /// @param amount The total amount that the split is being paid.
    /// @param caller The original caller of the terminal payout flow.
    /// @return netPayoutAmount The amount sent to the split after subtracting fees.
    function _sendPayoutToSplit(
        IJBTerminalStore store,
        JBSplit memory split,
        uint256 projectId,
        address token,
        uint256 amount,
        address caller
    )
        private
        returns (uint256 netPayoutAmount)
    {
        // Failed split payouts consume the payout limit by design. The try-catch prevents a single
        // split from DoS-ing the entire payout. Failed splits' amounts are returned to the project balance via
        // `recordAddedBalanceFor`. Payout limit consumption is correct because the project authorized the
        // distribution.
        // slither-disable-next-line reentrancy-events
        try IJBPayoutSplitGroupExecutor(address(this))
            .executePayout({
                split: split, projectId: projectId, token: token, amount: amount, originalMessageSender: caller
            }) returns (
            uint256 payoutAmount
        ) {
            return payoutAmount;
        } catch (bytes memory failureReason) {
            emit PayoutReverted({
                projectId: projectId, split: split, amount: amount, reason: failureReason, caller: caller
            });

            // Add balance back to the project.
            store.recordAddedBalanceFor({projectId: projectId, token: token, amount: amount});

            // Since the payout failed the netPayoutAmount is zero.
            return 0;
        }
    }
}
