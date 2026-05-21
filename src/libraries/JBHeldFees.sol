// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBFeeTerminal} from "../interfaces/IJBFeeTerminal.sol";
import {JBFee} from "../structs/JBFee.sol";
import {JBFees} from "./JBFees.sol";

/// @notice External-library implementation of held-fee storage operations for `JBMultiTerminal`.
/// @dev Functions are `external` so they live in this library's deployed bytecode and are reached from the caller
/// terminal via `DELEGATECALL`, keeping terminal bytecode below the EIP-170 limit. Storage refs are passed as
/// parameters so the library reads/writes the caller's mappings.
library JBHeldFees {
    /// @notice Returns held fees back to a project's balance based on the specified incoming amount.
    /// @dev Walks unprocessed held fees in storage order. For each fee, checks if the incoming `amount` covers
    /// the original net payout (gross minus fee). If yes, the fee is fully credited back and the entry is
    /// tombstoned by advancing the index. If only part of the fee can be refunded, the entry's stored gross
    /// amount is shrunk in place using the back-calculated fee so a future top-up can still settle the remainder.
    /// @dev Partial refunds use `standardFeeAmountResultingIn` so repaying a dust amount cannot both credit the
    /// payer project and leave the fee project owed the 1-unit minimum fee. Reads `caller` from a parameter
    /// instead of `msg.sender` because the library runs under `DELEGATECALL` from the terminal — `msg.sender`
    /// here is the original external caller of the terminal, not the meta-tx-aware caller the terminal would
    /// emit. The terminal passes `_msgSender()` so the event carries the meta-tx sender as intended.
    /// @param heldFeesOf The terminal's held-fee storage mapping.
    /// @param nextHeldFeeIndexOf The terminal's per-project/token next-index storage mapping.
    /// @param projectId The project to return held fees to.
    /// @param token The token that the held fees are in.
    /// @param amount The incoming amount available to match against held fees.
    /// @param caller The address that triggered the return, forwarded into the `ReturnHeldFees` event.
    /// @return returnedFees The total fee amount returned to the project (sum of fully and partially refunded fees).
    function returnHeldFees(
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        mapping(uint256 => mapping(address => uint256)) storage nextHeldFeeIndexOf,
        uint256 projectId,
        address token,
        uint256 amount,
        address caller
    )
        external
        returns (uint256 returnedFees)
    {
        // The first slot not yet returned, processed, or forgiven. Earlier slots are tombstones and skipped.
        uint256 startIndex = nextHeldFeeIndexOf[projectId][token];

        // Upper bound for the loop. Returning held fees never appends new entries, so the live length is fixed
        // for the duration of this call.
        uint256 numberOfHeldFees = heldFeesOf[projectId][token].length;

        // No live entries — nothing to refund. Early return keeps the gas cost predictable for projects that
        // never held a fee.
        if (startIndex >= numberOfHeldFees) return 0;

        // Tracks how much of the incoming `amount` is still available to match against further held fees as the
        // loop consumes them. Initialized to the full incoming amount.
        uint256 leftoverAmount = amount;

        // Tracks how far the live-entry window has advanced. Only persisted if it actually moves, to avoid an
        // unnecessary SSTORE when the loop ends without fully refunding any fee.
        uint256 newStartIndex = startIndex;

        for (uint256 i = startIndex; i < numberOfHeldFees;) {
            // Stop early once the incoming amount has been fully consumed. Remaining held fees stay live and
            // can be refunded by a future top-up.
            if (leftoverAmount == 0) break;

            // Snapshot the held fee into memory so subsequent reads (`.amount`) don't re-fetch from storage.
            JBFee memory heldFee = heldFeesOf[projectId][token][i];

            // Recompute the standard fee that was originally withheld from this entry's gross amount.
            uint256 feeAmount = JBFees.standardFeeAmountFrom(heldFee.amount);

            // The net amount that originally left the project after the fee was withheld — the deposit threshold
            // this incoming amount must clear to fully release the fee.
            uint256 amountPaidOut = heldFee.amount - feeAmount;

            if (leftoverAmount >= amountPaidOut) {
                // Full refund: the incoming amount covers everything the project paid out for this entry, so
                // the whole fee comes back. Consume `amountPaidOut` from `leftoverAmount` and advance the
                // tombstone window past this slot.
                unchecked {
                    leftoverAmount -= amountPaidOut;
                    returnedFees += feeAmount;
                }
                newStartIndex = i + 1;
            } else {
                // Partial refund: only some of the original payout has been redeposited. Back-calculate the
                // fee that corresponds to the remaining net amount (using `standardFeeAmountResultingIn` so
                // the fee project never gets shorted on dust). Shrink the stored gross amount by both the
                // refunded net and its fee, leaving the slot live so the leftover can be refunded later.
                feeAmount = JBFees.standardFeeAmountResultingIn(leftoverAmount);
                unchecked {
                    // `JBFee.amount` is `uint224`; the subtraction operand is `uint256`. Narrow the operand to
                    // `uint224` for the in-place update. The held gross amount was itself stored as `uint224`
                    // and the partial refund is bounded above by it, so the narrowed subtrahend always fits.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    heldFeesOf[projectId][token][i].amount -= uint224(leftoverAmount + feeAmount);
                    returnedFees += feeAmount;
                }
                // All of the incoming amount has been matched — exit the loop next iteration.
                leftoverAmount = 0;
            }
            unchecked {
                ++i;
            }
        }

        // Persist the new tombstone boundary only if any entry was fully refunded — partial refunds leave the
        // boundary alone so they can be revisited.
        if (startIndex != newStartIndex) nextHeldFeeIndexOf[projectId][token] = newStartIndex;

        // Emit through the interface qualifier so the event topic matches what `IJBFeeTerminal` declares. The
        // log surfaces under the calling terminal's address (we're inside its DELEGATECALL frame), so off-chain
        // consumers filter on the terminal as usual.
        emit IJBFeeTerminal.ReturnHeldFees({
            projectId: projectId,
            token: token,
            amount: amount,
            returnedFees: returnedFees,
            leftoverAmount: leftoverAmount,
            caller: caller
        });
    }

    /// @notice Returns up to `count` held fees for a project/token, starting from the next unprocessed index.
    /// @param heldFeesOf The terminal's held-fee storage mapping (project => token => array).
    /// @param nextHeldFeeIndexOf The terminal's per-project/token next-index storage mapping.
    /// @param projectId The ID of the project to read held fees for.
    /// @param token The token the fees are denominated in.
    /// @param count The maximum number of held fees to return.
    /// @return heldFees A view-only copy of the unprocessed held fees, in storage order.
    function viewHeldFees(
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        mapping(uint256 => mapping(address => uint256)) storage nextHeldFeeIndexOf,
        uint256 projectId,
        address token,
        uint256 count
    )
        external
        view
        returns (JBFee[] memory heldFees)
    {
        // The first slot not yet returned, processed, or forgiven. Slots before this are tombstones (zeroed by
        // `processHeldFeesOf` / `returnHeldFees`) and must be skipped so callers only see live fees.
        uint256 startIndex = nextHeldFeeIndexOf[projectId][token];

        // Total entries ever appended for this project/token (live + tombstoned). Used as the upper bound when
        // bounding `count`.
        uint256 numberOfHeldFees = heldFeesOf[projectId][token].length;

        // Nothing live to return — either the array was never populated, or every entry has already been processed
        // since the last full-array delete. Return an empty array so callers can branch on `.length == 0`.
        if (startIndex >= numberOfHeldFees) return new JBFee[](0);

        // Cap `count` to the number of live entries so we don't index past `length`. Keeps the common
        // "ask for more than there is" case from over-allocating the return buffer.
        if (startIndex + count > numberOfHeldFees) count = numberOfHeldFees - startIndex;

        // Allocate the return buffer at exactly the size we'll fill — saves the caller from filtering trailing
        // empty entries.
        heldFees = new JBFee[](count);

        // Copy live entries from storage into the return buffer. `++i` is unchecked because `i < count` already
        // bounds it well below `type(uint256).max`.
        for (uint256 i; i < count;) {
            heldFees[i] = heldFeesOf[projectId][token][startIndex + i];
            unchecked {
                ++i;
            }
        }
    }
}
