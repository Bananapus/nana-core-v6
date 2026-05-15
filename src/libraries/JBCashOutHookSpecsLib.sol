// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJBCashOutHook} from "../interfaces/IJBCashOutHook.sol";
import {IJBFeelessAddresses} from "../interfaces/IJBFeelessAddresses.sol";
import {JBAfterCashOutRecordedContext} from "../structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "../structs/JBTokenAmount.sol";
import {JBConstants} from "./JBConstants.sol";
import {JBFees} from "./JBFees.sol";

/// @notice Cash-out hook specification fulfillment for `JBMultiTerminal`. Extracted to reduce terminal
/// bytecode size, mirroring the `JBHeldFeesLib` pattern.
/// @dev Called via DELEGATECALL — `address(this)` inside library code is the terminal's address, so token
/// approvals and ETH-bearing hook calls operate on the terminal's balance and allowances. Events are
/// emitted from the terminal address. The `caller` field of `HookAfterRecordCashOut` uses raw `msg.sender`
/// (matching `JBHeldFeesLib`'s precedent) — this means meta-transactions through a trusted forwarder will
/// surface the forwarder address in the event slot, but the actual hook execution semantics are unaffected.
library JBCashOutHookSpecsLib {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // ------------------------------ events ----------------------------- //
    //*********************************************************************//

    /// @notice A cash out hook was called after a cash out was recorded.
    /// @param hook The cash out hook that was called.
    /// @param context The context passed to the hook.
    /// @param specificationAmount The amount specified for the hook.
    /// @param fee The fee taken from the hook's amount.
    /// @param caller The address that called the cash out function.
    event HookAfterRecordCashOut(
        IJBCashOutHook indexed hook,
        JBAfterCashOutRecordedContext context,
        uint256 specificationAmount,
        uint256 fee,
        address caller
    );

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a hook returns without consuming the full forwarded ERC-20 amount.
    error JBMultiTerminal_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);

    //*********************************************************************//
    // ----------------------- external functions ------------------------ //
    //*********************************************************************//

    /// @notice Iterates `specifications`, calling each non-noop hook with the right ETH/ERC-20 setup, and
    /// accumulates the fee-eligible amount across non-feeless hooks.
    /// @dev For each spec: if the hook is feeless, it gets the full spec amount; otherwise the hook gets
    /// `amount - feeAmountFrom(amount)` and the gross spec amount is added to the eligible-for-fees total
    /// (the caller takes the fee separately via `_takeFeeFrom`). Cross-token semantics: the hook context's
    /// `forwardedAmount` carries the post-fee amount in the same token as `context.reclaimedAmount`.
    /// @dev The caller builds `context` once (`JBAfterCashOutRecordedContext`) and passes it in; the
    /// library mutates `context.forwardedAmount` and `context.hookMetadata` per spec. Bundling the
    /// caller-side state into the existing hook-context struct keeps the call site under solc 0.8.28's
    /// non-via-ir 16-slot Yul stack ceiling (the prior 10-arg shape tripped it from
    /// `JBMultiTerminal._cashOutTokensOf`).
    /// @param feelessAddresses Registry of fee-exempt addresses (consulted per-hook).
    /// @param context Cash-out context to forward into each hook. `context.reclaimedAmount` doubles as the
    /// token-amount reference for per-spec transfers; `context.forwardedAmount` / `context.hookMetadata`
    /// are rewritten per iteration.
    /// @param specifications The hook specifications returned by the data hook.
    /// @return amountEligibleForFees Total spec amounts (gross) from non-feeless hooks, used by the caller to
    /// charge fees in a single pass.
    function fulfill(
        IJBFeelessAddresses feelessAddresses,
        JBAfterCashOutRecordedContext memory context,
        JBCashOutHookSpecification[] memory specifications
    )
        external
        returns (uint256 amountEligibleForFees)
    {
        // Loop body is extracted into a helper to keep `fulfill`'s stack frame shallow enough for solc 0.8.28
        // to compile *without* `via_ir`.
        for (uint256 i; i < specifications.length;) {
            amountEligibleForFees += _fulfillOne(feelessAddresses, context, specifications[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Fulfill a single hook specification: charge the protocol fee (if non-feeless), set up the hook
    /// call context, transfer the post-fee amount to the hook, and emit the after-cash-out event.
    /// @dev Returns the gross spec amount when the hook is non-feeless (so the caller can accumulate it into
    /// `amountEligibleForFees`), or `0` when the hook is feeless / noop. Mutates `context.forwardedAmount`
    /// and `context.hookMetadata` so the caller's next iteration can overwrite them.
    /// @param feelessAddresses Registry of fee-exempt addresses (consulted to skip the per-hook fee).
    /// @param context Cash-out context forwarded into the hook. `context.reclaimedAmount` is used as the
    /// token-amount reference for the per-spec transfer; `context.forwardedAmount` and
    /// `context.hookMetadata` are overwritten by this call.
    /// @param specification The hook specification to fulfill (hook address, amount, metadata, noop flag).
    /// @return grossSpecAmount The gross spec amount when the hook is non-feeless (for caller accumulation
    /// into `amountEligibleForFees`); `0` for feeless or noop specifications.
    function _fulfillOne(
        IJBFeelessAddresses feelessAddresses,
        JBAfterCashOutRecordedContext memory context,
        JBCashOutHookSpecification memory specification
    )
        private
        returns (uint256 grossSpecAmount)
    {
        // A noop specification is informational only and doesn't trigger the hook.
        if (specification.noop) return 0;

        // Get the fee for the specified amount.
        uint256 specificationAmountFee = feelessAddresses.isFeelessFor({
            addr: address(specification.hook), projectId: context.projectId
        })
            ? 0
            : JBFees.standardFeeAmountFrom({amountBeforeFee: specification.amount});

        // Surface the gross spec amount to the caller so it can be accumulated into `amountEligibleForFees`.
        if (specificationAmountFee != 0) {
            grossSpecAmount = specification.amount;
            specification.amount -= specificationAmountFee;
        }

        // Pass the correct token `forwardedAmount` to the hook.
        context.forwardedAmount = JBTokenAmount({
            value: specification.amount,
            token: context.reclaimedAmount.token,
            decimals: context.reclaimedAmount.decimals,
            currency: context.reclaimedAmount.currency
        });

        // Pass the correct metadata from the data hook's specification.
        context.hookMetadata = specification.metadata;

        // Trigger any inherited pre-transfer logic. Keep a reference to the amount that'll be paid as a `msg.value`.
        uint256 payValue = _beforeTransferTo({
            to: address(specification.hook), token: context.reclaimedAmount.token, amount: specification.amount
        });

        // Fulfill the specification.
        specification.hook.afterCashOutRecordedWith{value: payValue}(context);

        // Revoke the temporary pull allowance now that the hook call has finished.
        _afterTransferTo({to: address(specification.hook), token: context.reclaimedAmount.token});

        emit HookAfterRecordCashOut({
            hook: specification.hook,
            context: context,
            specificationAmount: specification.amount,
            fee: specificationAmountFee,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- private helpers --------------------------- //
    //*********************************************************************//

    /// @notice Native-token transfers use `msg.value` (return the amount). ERC20 transfers grant a temporary
    /// pull allowance and return 0 (the recipient is expected to consume it within the same call).
    function _beforeTransferTo(address to, address token, uint256 amount) private returns (uint256) {
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        IERC20(token).forceApprove({spender: to, value: amount});
        return 0;
    }

    /// @notice Asserts the recipient consumed the temporary ERC20 allowance. No-op for native token.
    function _afterTransferTo(address to, address token) private view {
        if (token == JBConstants.NATIVE_TOKEN) return;
        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: to});
        if (allowance != 0) revert JBMultiTerminal_TemporaryAllowanceNotConsumed(token, to, allowance);
    }
}
