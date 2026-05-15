// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJBCashOutHook} from "../interfaces/IJBCashOutHook.sol";
import {IJBFeelessAddresses} from "../interfaces/IJBFeelessAddresses.sol";
import {JBAfterCashOutRecordedContext} from "../structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "../structs/JBRuleset.sol";
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
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Protocol fee numerator (denominator is `JBConstants.MAX_FEE` = 1,000). 25 = 2.5%.
    uint256 internal constant _FEE = 25;

    //*********************************************************************//
    // ----------------------- external functions ------------------------ //
    //*********************************************************************//

    /// @notice Iterates `specifications`, calling each non-noop hook with the right ETH/ERC-20 setup, and
    /// accumulates the fee-eligible amount across non-feeless hooks.
    /// @dev For each spec: if the hook is feeless, it gets the full spec amount; otherwise the hook gets
    /// `amount - feeAmountFrom(amount)` and the gross spec amount is added to the eligible-for-fees total
    /// (the caller takes the fee separately via `_takeFeeFrom`). Cross-token semantics: the hook context's
    /// `forwardedAmount` carries the post-fee amount in the same token as `beneficiaryReclaimAmount`.
    /// @param feelessAddresses Registry of fee-exempt addresses (consulted per-hook).
    /// @param projectId The project being cashed out from.
    /// @param beneficiaryReclaimAmount The token amount reference (token, decimals, currency, gross value).
    /// @param holder The account whose project tokens were burned.
    /// @param cashOutCount The number of project tokens burned.
    /// @param metadata Bytes forwarded to each hook as `cashOutMetadata`.
    /// @param ruleset The ruleset active during the cash out.
    /// @param cashOutTaxRate The cash out tax rate applied.
    /// @param beneficiary The address forwarded as the hook context's `beneficiary` (typically the user-supplied
    /// recipient or `address(this)` for cross-project flows where the terminal custodies the reclaim mid-flow).
    /// @param specifications The hook specifications returned by the data hook.
    /// @return amountEligibleForFees Total spec amounts (gross) from non-feeless hooks, used by the caller to
    /// charge fees in a single pass.
    function fulfill(
        IJBFeelessAddresses feelessAddresses,
        uint256 projectId,
        JBTokenAmount memory beneficiaryReclaimAmount,
        address holder,
        uint256 cashOutCount,
        bytes memory metadata,
        JBRuleset memory ruleset,
        uint256 cashOutTaxRate,
        address payable beneficiary,
        JBCashOutHookSpecification[] memory specifications
    )
        external
        returns (uint256 amountEligibleForFees)
    {
        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: holder,
            projectId: projectId,
            rulesetId: ruleset.id,
            cashOutCount: cashOutCount,
            reclaimedAmount: beneficiaryReclaimAmount,
            forwardedAmount: beneficiaryReclaimAmount,
            cashOutTaxRate: cashOutTaxRate,
            beneficiary: beneficiary,
            hookMetadata: "",
            cashOutMetadata: metadata
        });

        for (uint256 i; i < specifications.length;) {
            JBCashOutHookSpecification memory specification = specifications[i];

            // A noop specification is informational only and doesn't trigger the hook.
            if (specification.noop) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Get the fee for the specified amount.
            uint256 specificationAmountFee = feelessAddresses.isFeelessFor({
                addr: address(specification.hook), projectId: projectId
            })
                ? 0
                : JBFees.feeAmountFrom({amountBeforeFee: specification.amount, feePercent: _FEE});

            // Add the specification's amount to the amount eligible for fees.
            if (specificationAmountFee != 0) {
                amountEligibleForFees += specification.amount;
                specification.amount -= specificationAmountFee;
            }

            // Pass the correct token `forwardedAmount` to the hook.
            context.forwardedAmount = JBTokenAmount({
                value: specification.amount,
                token: beneficiaryReclaimAmount.token,
                decimals: beneficiaryReclaimAmount.decimals,
                currency: beneficiaryReclaimAmount.currency
            });

            // Pass the correct metadata from the data hook's specification.
            context.hookMetadata = specification.metadata;

            // Trigger any inherited pre-transfer logic.
            // Keep a reference to the amount that'll be paid as a `msg.value`.
            uint256 payValue = _beforeTransferTo({
                to: address(specification.hook), token: beneficiaryReclaimAmount.token, amount: specification.amount
            });

            // Fulfill the specification.
            specification.hook.afterCashOutRecordedWith{value: payValue}(context);

            // Revoke the temporary pull allowance now that the hook call has finished.
            _afterTransferTo({to: address(specification.hook), token: beneficiaryReclaimAmount.token});

            emit HookAfterRecordCashOut({
                hook: specification.hook,
                context: context,
                specificationAmount: specification.amount,
                fee: specificationAmountFee,
                caller: msg.sender
            });
            unchecked {
                ++i;
            }
        }
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
