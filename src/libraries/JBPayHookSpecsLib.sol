// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJBFeelessAddresses} from "../interfaces/IJBFeelessAddresses.sol";
import {IJBTerminal} from "../interfaces/IJBTerminal.sol";
import {JBAfterPayRecordedContext} from "../structs/JBAfterPayRecordedContext.sol";
import {JBPayHookSpecification} from "../structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "../structs/JBTokenAmount.sol";
import {JBConstants} from "./JBConstants.sol";
import {JBFees} from "./JBFees.sol";

/// @notice Pay-hook specification fulfillment for `JBMultiTerminal`. Extracted to keep terminal bytecode
/// under EIP-170's 24 KB ceiling, mirroring the `JBCashOutHookSpecsLib` / `JBHeldFeesLib` pattern.
/// @dev Called via DELEGATECALL — `address(this)` inside library code is the terminal, so token approvals
/// and ETH-bearing hook calls operate on the terminal's balance and allowances, and `HookAfterRecordPay`
/// events are emitted from the terminal's address. The `caller` slot uses raw `msg.sender` (matching
/// `JBHeldFeesLib` / `JBCashOutHookSpecsLib`); meta-transactions through a trusted forwarder will surface
/// the forwarder address there, but hook execution semantics are unaffected.
library JBPayHookSpecsLib {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice A hook returned without consuming the full forwarded ERC-20 allowance. Reverts the call so
    /// stale allowances can never be re-used after the hook context closes.
    error JBMultiTerminal_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);

    //*********************************************************************//
    // ----------------------- external functions ------------------------ //
    //*********************************************************************//

    /// @notice Iterate `specifications`, calling each non-noop pay hook with the right ETH/ERC-20 transfer
    /// setup and emitting `HookAfterRecordPay` from the terminal's address.
    /// @dev Source-fee withholding (the "nuanced" variant of the source-fee model used by the fee-skipped
    /// internal funding paths): when `withholdFeeForSourceProjectId != 0`, each non-feeless non-noop hook
    /// receives `spec.amount - feeAmountFrom(spec.amount)` and the gross `spec.amount` is summed into
    /// `hookForwardGrossFeeEligible` so the caller can charge that fee against the source project.
    /// Withholding is skipped per-hook if the hook address is feeless for the source project; the gross is
    /// instead summed into `hookForwardGrossFeeExempt` so same-terminal cashout delivery can treat it as
    /// explicitly fee-bound without charging it. The public `pay` entrypoint passes
    /// `withholdFeeForSourceProjectId == 0` and receives zeroes back (pure pass-through).
    /// @param context Pay context forwarded into each hook. `context.forwardedAmount` and
    /// `context.hookMetadata` are rewritten per spec; the caller's reference is updated in place.
    /// @param specifications The hook specifications returned by the data hook.
    /// @param feelessAddresses Feeless-address registry. Only read when `withholdFeeForSourceProjectId != 0`;
    /// callers using the no-withhold path may safely pass any value (including `address(0)`).
    /// @param withholdFeeForSourceProjectId Source project ID for hook-fee withholding. `0` disables it.
    /// @return hookForwardGrossFeeEligible Sum of spec amounts whose source fee was withheld; `0` when
    /// `withholdFeeForSourceProjectId == 0` or when every spec was noop / feeless for the source.
    /// @return hookForwardGrossFeeExempt Sum of feeless hook spec amounts when source-fee binding is on.
    function fulfill(
        JBAfterPayRecordedContext memory context,
        JBPayHookSpecification[] memory specifications,
        IJBFeelessAddresses feelessAddresses,
        uint256 withholdFeeForSourceProjectId
    )
        external
        returns (uint256 hookForwardGrossFeeEligible, uint256 hookForwardGrossFeeExempt)
    {
        // Per-spec dispatch lives in `_fulfillOne` so this loop body stays shallow enough for solc 0.8.28
        // to compile without `via_ir`.
        for (uint256 i; i < specifications.length;) {
            (uint256 eligible, uint256 exempt) = _fulfillOne({
                context: context,
                specification: specifications[i],
                feelessAddresses: feelessAddresses,
                withholdFeeForSourceProjectId: withholdFeeForSourceProjectId
            });
            hookForwardGrossFeeEligible += eligible;
            hookForwardGrossFeeExempt += exempt;
            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ------------------------ private functions ------------------------ //
    //*********************************************************************//

    /// @notice Fulfill a single pay-hook specification: optionally withhold the source-project fee, set up
    /// the call context, transfer the (post-withhold) amount, invoke the hook, and emit `HookAfterRecordPay`.
    /// @param context Pay context. Mutated in place — `forwardedAmount` is rewritten to the
    /// post-withholding amount the hook actually receives, and `hookMetadata` is rewritten to this spec's
    /// metadata blob.
    /// @param specification The single hook spec being fulfilled.
    /// @param feelessAddresses Feeless-address registry (consulted only when withholding is on).
    /// @param withholdFeeForSourceProjectId Source project ID for hook-fee withholding (`0` disables).
    /// @return grossSpecAmountFeeEligible The original `specification.amount` when the source fee was
    /// withheld.
    /// @return grossSpecAmountFeeExempt The original `specification.amount` for feeless hooks while
    /// source-fee binding is enabled.
    function _fulfillOne(
        JBAfterPayRecordedContext memory context,
        JBPayHookSpecification memory specification,
        IJBFeelessAddresses feelessAddresses,
        uint256 withholdFeeForSourceProjectId
    )
        private
        returns (uint256 grossSpecAmountFeeEligible, uint256 grossSpecAmountFeeExempt)
    {
        // A noop specification is informational only — by convention it carries `amount == 0` and serves to
        // tell the hook that data was forwarded but no transfer should happen. Skip before any state change.
        if (specification.noop) return (0, 0);

        // Default: the hook receives exactly its spec amount (the public-pay path takes this branch).
        uint256 amountToHook = specification.amount;

        // Source-fee withholding branch. Triggered ONLY by the fee-skipped internal funding paths:
        //   - `JBMultiTerminal.executePayout` same-terminal cross-project pay split
        //   - `JBCashOutOpsLib.routeReclaimToBeneficiaryProject` (cashout → destination project)
        // Both pass the source project ID so a non-feeless hook's egress is taxed inline. Hooks the protocol
        // multisig has marked feeless for the source (or globally) keep the historical exemption.
        if (withholdFeeForSourceProjectId != 0) {
            if (feelessAddresses.isFeelessFor({
                    addr: address(specification.hook), projectId: withholdFeeForSourceProjectId
                })) {
                grossSpecAmountFeeExempt = specification.amount;
            } else {
                // Withhold the standard 2.5% fee on this spec. The terminal keeps the withheld portion as
                // backing for the source-side fee charged by the caller; the hook itself receives the net.
                // Returning the gross lets the caller aggregate across specs in a single `_takeFeeFrom`.
                unchecked {
                    uint256 feeWithheld = JBFees.standardFeeAmountFrom(specification.amount);
                    amountToHook = specification.amount - feeWithheld;
                    grossSpecAmountFeeEligible = specification.amount;
                }
            }
        }

        // Tell the hook what was actually forwarded to it. Hooks that compute against `forwardedAmount`
        // (e.g. proportional accounting downstream) see the post-withholding number, not the spec amount.
        context.forwardedAmount = JBTokenAmount({
            value: amountToHook,
            token: context.amount.token,
            decimals: context.amount.decimals,
            currency: context.amount.currency
        });

        // Per-spec metadata supplied by the data hook (opaque to this library; just forwarded).
        context.hookMetadata = specification.metadata;

        // Native ETH: `msg.value` is the transfer mechanism. ERC-20: grant a temporary pull allowance the
        // hook must consume during its call (asserted by `_afterTransferTo` below).
        uint256 payValue =
            _beforeTransferTo({to: address(specification.hook), token: context.amount.token, amount: amountToHook});

        // Invoke the hook with the resolved value/allowance. Reverts here bubble up — same as in the
        // pre-extraction in-terminal implementation.
        specification.hook.afterPayRecordedWith{value: payValue}(context);

        // Revoke any unconsumed ERC-20 pull allowance — see `_afterTransferTo` for the safety reasoning.
        _afterTransferTo({to: address(specification.hook), token: context.amount.token});

        emit IJBTerminal.HookAfterRecordPay({
            hook: specification.hook, context: context, specificationAmount: specification.amount, caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- private helpers --------------------------- //
    //*********************************************************************//

    /// @notice Set up the transfer modality for a hook call. Native ETH goes via `msg.value`; ERC-20 goes
    /// via a temporary pull allowance (the hook is expected to `transferFrom` the allowance during its
    /// call). Returns the amount to attach as `msg.value` (zero for ERC-20 since funds flow by allowance).
    function _beforeTransferTo(address to, address token, uint256 amount) private returns (uint256) {
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        IERC20(token).forceApprove({spender: to, value: amount});
        return 0;
    }

    /// @notice Sanity check the post-hook state: for ERC-20 transfers via allowance, the hook MUST have
    /// consumed the full allowance during its call. A leftover allowance indicates either a buggy hook
    /// (didn't pull) or a misbehaving hook attempting to retain pull access beyond the call frame — both
    /// are dangerous. Revert in either case so stale allowances never linger.
    function _afterTransferTo(address to, address token) private view {
        if (token == JBConstants.NATIVE_TOKEN) return;
        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: to});
        if (allowance != 0) revert JBMultiTerminal_TemporaryAllowanceNotConsumed(token, to, allowance);
    }
}
