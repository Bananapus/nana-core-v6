// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "../interfaces/IJBDirectory.sol";
import {IJBTerminal} from "../interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "../interfaces/IJBTerminalStore.sol";
import {JBFee} from "../structs/JBFee.sol";
import {JBFees} from "./JBFees.sol";

/// @notice Local callback into the terminal's `executeProcessFee(...)`. Kept here because the function is an
/// implementation detail of the library/terminal pair, not a shared public interface.
interface IJBHeldFeesExecutor {
    /// @notice Sends a fee amount from a project to the fee-receiving terminal under an external CALL boundary,
    /// so the library can wrap the call in `try/catch` (revert in the fee route is forgiven, not propagated).
    /// @param projectId The project paying the fee.
    /// @param token The token the fee is denominated in.
    /// @param amount The fee amount.
    /// @param beneficiary The address that receives any platform tokens minted by the fee payment.
    /// @param feeTerminal The terminal that'll receive the fee.
    function executeProcessFee(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        IJBTerminal feeTerminal
    )
        external;
}

/// @notice Held-fee bookkeeping for `JBMultiTerminal`. Extracted to reduce terminal bytecode size.
/// @dev Called via DELEGATECALL — storage refs (`heldFeesOf`, `nextHeldFeeIndexOf`) point at the terminal's
/// storage. `address(this)` inside library code is the terminal's address. Events are therefore emitted from
/// the terminal.
library JBHeldFeesLib {
    //*********************************************************************//
    // ------------------------------ events ----------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a fee is sent to the fee-receiving terminal.
    /// @param projectId The project the fee was for.
    /// @param token The token the fee was paid in.
    /// @param amount The fee amount.
    /// @param wasHeld Whether the fee was previously held (true) or processed inline (false).
    /// @param beneficiary The address that received any platform tokens minted by the fee payment.
    /// @param caller The address that triggered the fee processing.
    event ProcessFee(
        uint256 indexed projectId,
        address indexed token,
        uint256 amount,
        bool wasHeld,
        address beneficiary,
        address caller
    );

    /// @notice Emitted when a fee payment reverts and the amount is returned to the project's balance.
    /// @param projectId The project the fee was for.
    /// @param token The token the fee was paid in.
    /// @param feeProjectId The ID of the fee-receiving project.
    /// @param amount The fee amount returned.
    /// @param reason The revert reason from the fee route.
    /// @param caller The address that triggered the fee processing.
    event FeeReverted(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed feeProjectId,
        uint256 amount,
        bytes reason,
        address caller
    );

    /// @notice Emitted when held fees are returned to the project's balance (e.g. on an `addToBalanceOf`).
    /// @param projectId The project whose held fees were returned.
    /// @param token The token the held fees were denominated in.
    /// @param amount The amount used as the basis for the return calculation.
    /// @param returnedFees The amount of fees actually returned.
    /// @param leftoverAmount Any leftover from the basis amount that did not match a held fee.
    /// @param caller The address that triggered the return.
    event ReturnHeldFees(
        uint256 indexed projectId,
        address indexed token,
        uint256 amount,
        uint256 returnedFees,
        uint256 leftoverAmount,
        address caller
    );

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Protocol fee numerator (denominator is `MAX_FEE` = 1,000). 25 = 2.5%.
    uint256 internal constant _FEE = 25;

    /// @notice Project ID of the protocol fee beneficiary.
    uint256 internal constant _FEE_BENEFICIARY_PROJECT_ID = 1;

    //*********************************************************************//
    // ----------------------- internal functions ------------------------ //
    //*********************************************************************//

    /// @notice Processes up to `count` unlocked held fees for `(projectId, token)`, forwarding each to the fee
    /// terminal and reclaiming the storage slot once the queue is drained.
    /// @dev Re-reads `nextHeldFeeIndexOf[projectId][token]` from storage each iteration to be reentrancy-safe
    /// against any nested call that may have advanced the index. The entry is deleted and the index advanced
    /// BEFORE the external call so a reverting fee route cannot be replayed.
    /// @param heldFeesOf Storage ref to the terminal's per-(project,token) held-fee queue.
    /// @param nextHeldFeeIndexOf Storage ref to the next-index cursor for each (project,token) queue.
    /// @param directory The terminal's directory, used to locate the fee-receiving terminal.
    /// @param store The terminal's store, used to credit the fee back to the project on a failed route.
    /// @param projectId The project to process held fees for.
    /// @param token The token the held fees are denominated in.
    /// @param count The maximum number of held fees to process.
    function processHeldFees(
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        mapping(uint256 => mapping(address => uint256)) storage nextHeldFeeIndexOf,
        IJBDirectory directory,
        IJBTerminalStore store,
        uint256 projectId,
        address token,
        uint256 count
    )
        external
    {
        // Resolve the fee-receiving terminal once outside the loop.
        IJBTerminal feeTerminal = directory.primaryTerminalOf({projectId: _FEE_BENEFICIARY_PROJECT_ID, token: token});

        for (uint256 i; i < count;) {
            uint256 currentIndex = nextHeldFeeIndexOf[projectId][token];

            // Queue exhausted — break early so we can run the array cleanup below.
            if (currentIndex >= heldFeesOf[projectId][token].length) break;

            JBFee memory heldFee = heldFeesOf[projectId][token][currentIndex];

            // Fees unlock sequentially; if the head isn't ready, nothing later is either.
            // forge-lint: disable-next-line(block-timestamp)
            if (heldFee.unlockTimestamp > block.timestamp) break;

            // Delete + advance index BEFORE the external call (reentrancy safety: a reentrant
            // `processHeldFeesOf` cannot re-process the same entry).
            delete heldFeesOf[projectId][token][currentIndex];
            nextHeldFeeIndexOf[projectId][token] = currentIndex + 1;

            processFee({
                store: store,
                projectId: projectId,
                token: token,
                amount: JBFees.feeAmountFrom({amountBeforeFee: heldFee.amount, feePercent: _FEE}),
                beneficiary: heldFee.beneficiary,
                feeTerminal: feeTerminal,
                wasHeld: true
            });

            unchecked {
                ++i;
            }
        }

        // Reclaim the array storage slot once the queue has been fully drained.
        if (
            nextHeldFeeIndexOf[projectId][token] >= heldFeesOf[projectId][token].length
                && heldFeesOf[projectId][token].length > 0
        ) {
            delete heldFeesOf[projectId][token];
            delete nextHeldFeeIndexOf[projectId][token];
        }
    }

    /// @notice Sends a fee to the fee-receiving terminal under a try/catch boundary.
    /// @dev Routed through `IJBHeldFeesExecutor(address(this)).executeProcessFee(...)` so the call is a real
    /// external CALL (try/catch semantics require it). Under DELEGATECALL `address(this)` is the terminal, so
    /// this becomes a call to the terminal's `executeProcessFee` whose `msg.sender == address(this)` check
    /// passes. On revert the amount is forgiven and added back to the project's balance — by design, a broken
    /// fee route should not permanently lock project funds.
    /// @param store The terminal's store, used for the forgive-on-revert credit.
    /// @param projectId The project paying the fee.
    /// @param token The token the fee is denominated in.
    /// @param amount The fee amount.
    /// @param beneficiary The address that receives any platform tokens minted by the fee payment.
    /// @param feeTerminal The terminal that'll receive the fee.
    /// @param wasHeld Whether the fee was previously held (true) or processed inline (false).
    function processFee(
        IJBTerminalStore store,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        IJBTerminal feeTerminal,
        bool wasHeld
    )
        public
    {
        try IJBHeldFeesExecutor(address(this)).executeProcessFee({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            feeTerminal: feeTerminal
        }) {
            emit ProcessFee({
                projectId: projectId,
                token: token,
                amount: amount,
                wasHeld: wasHeld,
                beneficiary: beneficiary,
                caller: msg.sender
            });
        } catch (bytes memory reason) {
            // Forgive the fee, credit it back to the project, and surface the failure for off-chain observability.
            emit FeeReverted({
                projectId: projectId,
                token: token,
                feeProjectId: _FEE_BENEFICIARY_PROJECT_ID,
                amount: amount,
                reason: reason,
                caller: msg.sender
            });

            store.recordAddedBalanceFor({projectId: projectId, token: token, amount: amount});
        }
    }

    /// @notice Returns held fees up to `amount` in FIFO order from the project's held-fee queue.
    /// @dev Walks the queue from `nextHeldFeeIndexOf` forward. Whole entries are consumed when `leftoverAmount`
    /// covers their post-fee amount; the final entry can be partially consumed by shrinking its `.amount` in
    /// place. The fee implied by the partial-consume branch uses `feeAmountResultingIn` (inverse of
    /// `feeAmountFrom`) so the credited fee aligns with the amount that was actually returned. Dust amounts
    /// below the floor produce `feeAmount == 0`.
    /// @param heldFeesOf Storage ref to the terminal's per-(project,token) held-fee queue.
    /// @param nextHeldFeeIndexOf Storage ref to the next-index cursor for each (project,token) queue.
    /// @param projectId The project to return held fees for.
    /// @param token The token the held fees are denominated in.
    /// @param amount The reference amount to base the return on (typically the inbound addToBalance amount).
    /// @return returnedFees The total fee amount returned to the project.
    function returnHeldFees(
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        mapping(uint256 => mapping(address => uint256)) storage nextHeldFeeIndexOf,
        uint256 projectId,
        address token,
        uint256 amount
    )
        external
        returns (uint256 returnedFees)
    {
        uint256 startIndex = nextHeldFeeIndexOf[projectId][token];
        uint256 numberOfHeldFees = heldFeesOf[projectId][token].length;

        // Empty queue — nothing to return.
        if (startIndex >= numberOfHeldFees) return 0;

        uint256 leftoverAmount = amount;
        uint256 count = numberOfHeldFees - startIndex;
        uint256 newStartIndex = startIndex;

        for (uint256 i; i < count;) {
            JBFee memory heldFee = heldFeesOf[projectId][token][startIndex + i];

            if (leftoverAmount == 0) {
                break;
            } else {
                // Recompute the fee charged on the stored gross amount so partial returns stay aligned.
                uint256 feeAmount = JBFees.feeAmountFrom({amountBeforeFee: heldFee.amount, feePercent: _FEE});
                uint256 amountPaidOut = heldFee.amount - feeAmount;

                if (leftoverAmount >= amountPaidOut) {
                    // Whole entry consumed: credit its full fee, advance the cursor past it.
                    unchecked {
                        leftoverAmount -= amountPaidOut;
                        returnedFees += feeAmount;
                    }
                    newStartIndex = startIndex + i + 1;
                } else {
                    // Partial entry: shrink the stored entry by what we consumed (incl. its own fee).
                    feeAmount = JBFees.feeAmountResultingIn({amountAfterFee: leftoverAmount, feePercent: _FEE});
                    unchecked {
                        heldFeesOf[projectId][token][startIndex + i].amount -= (leftoverAmount + feeAmount);
                        returnedFees += feeAmount;
                    }
                    leftoverAmount = 0;
                }
            }

            unchecked {
                ++i;
            }
        }

        if (startIndex != newStartIndex) nextHeldFeeIndexOf[projectId][token] = newStartIndex;

        emit ReturnHeldFees({
            projectId: projectId,
            token: token,
            amount: amount,
            returnedFees: returnedFees,
            leftoverAmount: leftoverAmount,
            caller: msg.sender
        });
    }
}
