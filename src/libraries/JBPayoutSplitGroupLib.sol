// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBSplitHook} from "../interfaces/IJBSplitHook.sol";
import {IJBSplits} from "../interfaces/IJBSplits.sol";
import {IJBTerminalStore} from "../interfaces/IJBTerminalStore.sol";
import {JBSplit} from "../structs/JBSplit.sol";
import {JBSplitHookContext} from "../structs/JBSplitHookContext.sol";
import {JBConstants} from "./JBConstants.sol";
import {JBHeldSplits} from "./JBHeldSplits.sol";

/// @notice Minimal callback surface used only by this library to call back into the terminal's `executePayout(...)`.
/// @dev Kept local to this file because `executePayout(...)` is an implementation detail, not a shared public
/// interface.
interface IJBPayoutSplitGroupExecutor {
    /// @notice Executes one payout split from the terminal that is using this library.
    /// @param split The split to pay.
    /// @param projectId The ID of the project paying the split.
    /// @param token The token being paid out.
    /// @param amount The amount assigned to the split.
    /// @param originalMessageSender The account that started the payout flow.
    /// @return netPayoutAmount The amount the split recipient actually received (may be less than the
    /// post-fee amount if a split hook accepted a partial pull).
    /// @return feeEligibleAmount The gross-equivalent of `netPayoutAmount` that should accrue held fees.
    /// Equals `amount` on a fully-consumed non-feeless payout, `0` on feeless or when the hook took nothing,
    /// and a scaled value `amount * sent / netOffered` for a partial pull.
    function executePayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        address originalMessageSender
    )
        external
        returns (uint256 netPayoutAmount, uint256 feeEligibleAmount);
}

/// @notice Handles distributing payouts to a project's split recipients. Iterates through each split, sends the
/// proportional amount, and isolates failures: if a split payout reverts (e.g. a hook is broken), the amount is held
/// for that split in the terminal and anyone can retry it through `processHeldPayoutOf`, so one bad recipient never
/// blocks the others and never changes who the money belongs to.
/// @dev Extracted as an external library to reduce `JBMultiTerminal` bytecode size. Called via DELEGATECALL, so events
/// are emitted from the terminal's address.
library JBPayoutSplitGroupLib {
    /// @notice Holds a payout for a split whose recipient could not take it, so anyone can retry it later.
    /// @param heldPayoutOf The terminal's held payout ledger.
    /// @param projectId The ID of the project the payout is from.
    /// @param token The token of the payout.
    /// @param split The split the payout was for, with its beneficiary already resolved (never the zero address for
    /// a direct payout), so a later retry cannot redirect the payout to whoever retries.
    /// @param amount The gross amount to hold.
    /// @param reason The reason the payout reverted.
    function holdPayout(
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldPayoutOf,
        uint256 projectId,
        address token,
        JBSplit memory split,
        uint256 amount,
        bytes memory reason
    )
        public
    {
        JBHeldSplits.hold({
            heldOf: heldPayoutOf, projectId: projectId, token: token, split: split, amount: amount, reason: reason
        });
    }

    /// @notice Retries a held payout: takes it out of the ledger and runs `executePayout` with no catch, so a
    /// recipient that still fails reverts the call and the amount stays held.
    /// @param heldPayoutOf The terminal's held payout ledger.
    /// @param projectId The ID of the project the payout is from.
    /// @param token The token of the payout.
    /// @param split The held split.
    /// @param caller The address retrying the payout.
    /// @return feeEligible The fee basis of the payout, floored to the fee denominator.
    function processHeldPayout(
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldPayoutOf,
        uint256 projectId,
        address token,
        JBSplit memory split,
        address caller
    )
        external
        returns (uint256 feeEligible)
    {
        (uint256 amount,) = JBHeldSplits.take({heldOf: heldPayoutOf, projectId: projectId, token: token, split: split});

        (uint256 netAmount, uint256 feeBasis) = IJBPayoutSplitGroupExecutor(address(this))
            .executePayout({
            split: split, projectId: projectId, token: token, amount: amount, originalMessageSender: split.beneficiary
        });
        feeEligible = feeBasis - (feeBasis % 40);

        JBHeldSplits.processed({
            projectId: projectId, token: token, split: split, amount: amount, netAmount: netAmount, caller: caller
        });
    }
    /// @notice A payout was sent to a split.
    /// @param projectId The ID of the project that the payout was made from.
    /// @param rulesetId The ID of the ruleset the split belongs to.
    /// @param group The group the split belongs to.
    /// @param split The split that was paid.
    /// @param amount The amount that was sent to the split.
    /// @param netAmount The amount that the split recipient actually received, after fees.
    /// @param caller The address that called the payout function.
    event SendPayoutToSplit(
        uint256 indexed projectId,
        uint256 indexed rulesetId,
        uint256 indexed group,
        JBSplit split,
        uint256 amount,
        uint256 netAmount,
        address caller
    );

    /// @notice Invokes a split hook with partial-pull-aware allowance handling.
    /// @dev For ERC-20: grants the hook an allowance, calls `processSplitWith`, and revokes any unconsumed
    /// allowance. For native ETH: pushes via `msg.value`. The hook may take less than offered (revert or
    /// short-pull); the unsent portion is routed back to the project balance via `store.recordAddedBalanceFor`,
    /// scaled to include the proportional fee allocation so the held fee is effectively charged only on the
    /// consumed amount. Fee-eligibility is inferred from `netPayoutAmount < amount`.
    /// @dev Called via DELEGATECALL from the terminal, so `address(this)` is the terminal and `msg.sender`
    /// observed by the hook is the terminal — hooks that check `DIRECTORY.isTerminalOf(msg.sender)` continue
    /// to work unchanged.
    /// @param split The split (must have a non-zero hook address).
    /// @param projectId The originating project ID.
    /// @param token The token being distributed. Use `JBConstants.NATIVE_TOKEN` for ETH.
    /// @param amount The gross amount allocated to this split (pre-fee).
    /// @param netPayoutAmount The amount the hook is offered (post-fee for non-feeless splits, == amount otherwise).
    /// @param store The terminal store used to credit any refund back to the project and to look up decimals.
    /// @return sent The amount the hook actually received.
    /// @return feeEligibleAmount The gross-equivalent of `sent` (used for held-fee accounting). Zero for
    /// feeless splits or when the hook consumed nothing.
    function invokeSplitHookWithPartial(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 netPayoutAmount,
        IJBTerminalStore store
    )
        external
        returns (uint256 sent, uint256 feeEligibleAmount)
    {
        // Native vs ERC-20 governs the transfer mechanism (push via msg.value vs allowance pull).
        bool isNative = token == JBConstants.NATIVE_TOKEN;

        // Build the hook context inline so the terminal call site doesn't have to. `decimals` is looked up from
        // the terminal store's recorded accounting context for this (projectId, token) pair.
        JBSplitHookContext memory context = JBSplitHookContext({
            token: token,
            amount: netPayoutAmount,
            decimals: store.accountingContextOf({terminal: address(this), projectId: projectId, token: token}).decimals,
            projectId: projectId,
            groupId: uint256(uint160(token)),
            split: split
        });

        // Set up the transfer: ETH is pushed via `value:` on the hook call; ERC-20 grants the hook a pull
        // allowance for the offered net amount.
        uint256 payValue;
        if (isNative) {
            payValue = netPayoutAmount;
        } else {
            SafeERC20.forceApprove({token: IERC20(token), spender: address(split.hook), value: netPayoutAmount});
        }

        // A reverting hook propagates to `executePayout`'s caller, which holds the whole payout for a retry. The
        // success path cannot use a balance delta because the hook may reenter into this terminal (pay/cashOut/etc.)
        // and shift our balance independently of its own consumption.
        split.hook.processSplitWith{value: payValue}(context);

        if (isNative) {
            // Native ETH is pushed via `value:`. There is no on-the-fly "give some back" mechanism, so a successful
            // hook consumed exactly `netPayoutAmount`. Any side-effects the hook produced via reentrant terminal
            // calls (pay/addToBalance/cashOut) are recorded through those calls' own bookkeeping and must
            // not bleed into this split's consumption accounting.
            sent = netPayoutAmount;
        } else {
            // ERC-20 hooks pull via `transferFrom` against the allowance we granted. The allowance delta
            // is the only consumption measure that is robust against reentrant balance manipulation: the
            // hook cannot raise its own allowance, and any pull on this allowance reduces it 1:1 with
            // what the hook actually received. Reentrant flows through other paths use independent
            // allowances/values and so cannot inflate this measurement.
            sent = netPayoutAmount - IERC20(token).allowance({owner: address(this), spender: address(split.hook)});

            // Revoke any unconsumed ERC-20 allowance immediately after the call so the hook can never pull later.
            SafeERC20.forceApprove({token: IERC20(token), spender: address(split.hook), value: 0});
        }

        // If the hook took less than offered, refund the proportional gross portion to the project's balance.
        // refund = amount * (netPayoutAmount - sent) / netPayoutAmount. For full consumption this branch is
        // skipped. For zero consumption this refunds the full `amount` (i.e. the gross, fee allocation included).
        if (sent < netPayoutAmount) {
            uint256 refund = mulDiv({x: amount, y: netPayoutAmount - sent, denominator: netPayoutAmount});
            if (refund != 0) {
                store.recordAddedBalanceFor({projectId: projectId, token: token, amount: refund});
            }
        }

        // `netPayoutAmount < amount` iff the terminal deducted a fee above (non-feeless split). Report the
        // gross-equivalent of what the hook actually consumed so the held fee scales with consumption rather
        // than with the project's original payout intent.
        if (netPayoutAmount < amount && sent != 0) {
            feeEligibleAmount = mulDiv({x: amount, y: sent, denominator: netPayoutAmount});
        }
    }

    /// @notice Holds a project owner's leftover payout that the owner could not receive.
    /// @param heldPayoutOf The terminal's held payout ledger.
    /// @param projectId The ID of the project the payout is from.
    /// @param token The token of the payout.
    /// @param owner The project owner the payout is for.
    /// @param amount The gross amount to hold.
    /// @param reason The reason the transfer reverted.
    function holdOwnerPayout(
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldPayoutOf,
        uint256 projectId,
        address token,
        address owner,
        uint256 amount,
        bytes memory reason
    )
        external
    {
        holdPayout({
            heldPayoutOf: heldPayoutOf,
            projectId: projectId,
            token: token,
            split: JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(owner),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            }),
            amount: amount,
            reason: reason
        });
    }

    /// @notice Sends one split its payout, holding the amount for it if the payout reverts.
    /// @dev Kept out of the loop so the try/catch has its own stack frame. The split's beneficiary is already
    /// resolved, so it doubles as the message sender fallback `executePayout` would otherwise apply.
    /// @param heldPayoutOf The terminal's held payout ledger, written when the payout fails.
    /// @param projectId The ID of the project to send the payout of.
    /// @param token The address of the token to pay out.
    /// @param split The split to pay.
    /// @param payoutAmount The gross amount to pay.
    /// @return netPayoutAmount The amount the split received after fees, 0 if the payout is held.
    /// @return feeEligible The fee basis of this payout, floored to the fee denominator.
    function _sendPayoutToSplit(
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldPayoutOf,
        uint256 projectId,
        address token,
        JBSplit memory split,
        uint256 payoutAmount
    )
        private
        returns (uint256 netPayoutAmount, uint256 feeEligible)
    {
        try IJBPayoutSplitGroupExecutor(address(this))
            .executePayout({
            split: split,
            projectId: projectId,
            token: token,
            amount: payoutAmount,
            originalMessageSender: split.beneficiary
        }) returns (
            uint256 sentAmount, uint256 feeBasis
        ) {
            netPayoutAmount = sentAmount;
            // The standard fee is `STANDARD_FEE / MAX_FEE`, currently 25 / 1000 = 1 / 40. The `40` below is
            // that reduced denominator, not an independent fee parameter. Round each split's fee basis down to
            // it so aggregation cannot charge more than per-split floors.
            feeEligible = feeBasis - (feeBasis % 40);
        } catch (bytes memory failureReason) {
            holdPayout({
                heldPayoutOf: heldPayoutOf,
                projectId: projectId,
                token: token,
                split: split,
                amount: payoutAmount,
                reason: failureReason
            });
        }
    }

    /// @notice Sends payouts to the payout splits group specified in a project's ruleset.
    /// @param splits The splits contract to read splits from.
    /// @param heldPayoutOf The terminal's held payout ledger, written when a payout fails.
    /// @param projectId The ID of the project to send the payouts of.
    /// @param token The address of the token to pay out.
    /// @param rulesetId The ID of the ruleset of the split group to pay.
    /// @param amount The total amount to pay out.
    /// @param caller The original caller of the terminal payout flow.
    /// @return leftoverAmount The leftover amount after split payouts.
    /// @return amountEligibleForFees The amount of payouts that are eligible for fees.
    function sendPayoutsToSplitGroupOf(
        IJBSplits splits,
        mapping(
            uint256 projectId => mapping(address token => mapping(bytes32 splitHash => uint256 amount))
        ) storage heldPayoutOf,
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

        // Get a reference to the project's payout splits.
        JBSplit[] memory payoutSplits =
            splits.splitsOf({projectId: projectId, rulesetId: rulesetId, groupId: uint256(uint160(token))});

        leftoverAmount = amount;

        // Transfer between all splits.
        for (uint256 i; i < payoutSplits.length;) {
            // Get a reference to the split being iterated on.
            JBSplit memory split = payoutSplits[i];

            // A direct split with no beneficiary pays the caller. Resolve it now so the split that is paid, held
            // and emitted is the same one, and a held payout can never be redirected to whoever retries it.
            if (split.hook == IJBSplitHook(address(0)) && split.beneficiary == address(0)) {
                split.beneficiary = payable(caller);
            }

            // The amount to send to the split.
            uint256 payoutAmount = mulDiv({x: leftoverAmount, y: split.percent, denominator: leftoverPercentage});

            // Send the payout. Returns (netPayoutAmount sent, fee basis). For non-hook splits and fully-consumed
            // hook splits, the fee basis equals `payoutAmount` (non-feeless) or 0 (feeless). For a partial split-hook
            // pull, it scales with consumed. Failed payouts consume the payout limit by design — the try/catch keeps
            // a single bad split from DoS-ing the rest and holds the amount for that split.
            uint256 netPayoutAmount;
            {
                uint256 feeEligible;
                (netPayoutAmount, feeEligible) = _sendPayoutToSplit({
                    heldPayoutOf: heldPayoutOf,
                    projectId: projectId,
                    token: token,
                    split: split,
                    payoutAmount: payoutAmount
                });
                amountEligibleForFees += feeEligible;
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
                group: uint256(uint160(token)),
                split: split,
                amount: payoutAmount,
                netAmount: netPayoutAmount,
                caller: caller
            });
            unchecked {
                ++i;
            }
        }
    }
}
