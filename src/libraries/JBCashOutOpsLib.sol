// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJBCashOutTerminal} from "../interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "../interfaces/IJBController.sol";
import {IJBDirectory} from "../interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "../interfaces/IJBFeeTerminal.sol";
import {IJBFeelessAddresses} from "../interfaces/IJBFeelessAddresses.sol";
import {IJBProjects} from "../interfaces/IJBProjects.sol";
import {IJBTerminal} from "../interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "../interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "../structs/JBAccountingContext.sol";
import {JBAfterCashOutRecordedContext} from "../structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../structs/JBCashOutHookSpecification.sol";
import {JBFee} from "../structs/JBFee.sol";
import {JBRuleset} from "../structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "../structs/JBTokenAmount.sol";
import {JBCashOutHookSpecsLib} from "./JBCashOutHookSpecsLib.sol";
import {JBConstants} from "./JBConstants.sol";
import {JBFees} from "./JBFees.sol";
import {JBHeldFeesLib} from "./JBHeldFeesLib.sol";

/// @notice Callback surface used by this library's cross-project routing functions to invoke the terminal's
/// internal `_efficientPay` from library code.
/// @dev The wrappers on the terminal authenticate `msg.sender == address(this)` (same pattern as
/// `executePayout` / `executeProcessFee`). Under DELEGATECALL from this library, `address(this)` is the
/// terminal, so a library-initiated external call to `address(this)` produces `msg.sender == terminal` and
/// passes the check.
interface IJBCashOutOpsExecutor {
    /// @notice Wrapper around `JBMultiTerminal._efficientPay`. Returns the `newlyIssuedTokenCount` minted
    /// to `beneficiary`, the fee-eligible hook gross, and the feeless/exempt hook gross reported by
    /// `JBPayHookSpecsLib.fulfill`.
    function executeEfficientPay(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        address payer,
        address beneficiary,
        bytes calldata metadata,
        uint256 withholdFeeForSourceProjectId
    )
        external
        returns (uint256 newlyIssuedTokenCount, uint256 hookForwardGrossFeeEligible, uint256 hookForwardGrossFeeExempt);
}

/// @notice Cashout-side operations for `JBMultiTerminal`: direct cashouts, cross-project cashout-and-deliver
/// (pay / addToBalance variants), and terminal balance migration. Extracted to keep `JBMultiTerminal`
/// runtime bytecode under EIP-170's 24 KB ceiling on non-via-ir builds (`721-hook` depends on
/// `nana-core-v6` and cannot use `via_ir`, so the terminal must fit without it).
///
/// @dev Called via DELEGATECALL from `JBMultiTerminal`, so `address(this)` inside library code is the
/// terminal and all storage reads / writes go through the terminal's storage layout. Library functions
/// take the terminal's immutables (store, directory, feelessAddresses, projects) as the `Deps` struct, and
/// the relevant mapping storage refs (`_feeFreeSurplusOf`, `_heldFeesOf`) as `storage` parameters —
/// immutables on the terminal are not visible to external library code under DELEGATECALL, and storage
/// refs can't be packed into a memory struct.
///
/// @dev `msg.sender` inside library code is the original transaction's `msg.sender` (DELEGATECALL preserves
/// context). For ERC-2771 meta-transactions this means library-emitted events carry the trusted forwarder
/// in the `caller` slot — matching the precedent set by `JBHeldFeesLib` and `JBCashOutHookSpecsLib`.
library JBCashOutOpsLib {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Beneficiary project has no accounting contexts on this terminal — no bucket exists for the
    /// reclaim to land in, so the source-fee skip on the cashout side would leak. Reverts the entire flow.
    error JBMultiTerminal_BeneficiaryProjectHasNoAccountingContexts(uint256 projectId);

    /// @notice Routing finished but none of the beneficiary project's accounting-context balances grew on
    /// this terminal. Either the destination silently dropped the reclaim or routed it to a different
    /// terminal not registered as the destination's primary. Reverts so the source-fee skip never leaks.
    error JBMultiTerminal_BeneficiaryProjectNotPaid(uint256 projectId);

    /// @notice A fee-skipped source reclaim was not provably retained as destination fee-free surplus or
    /// charged as hook egress in the source token/value basis.
    error JBMultiTerminal_SourceFeeSkippedReclaimNotFeeBound(
        uint256 projectId, address token, uint256 reclaimAmount, uint256 feeBoundAmount
    );

    /// @notice The directory has no primary terminal registered for the beneficiary project + token.
    error JBMultiTerminal_RecipientProjectTerminalNotFound(uint256 projectId, address token);

    /// @notice Migration target terminal does not accept the migrating project's token.
    error JBMultiTerminal_TerminalTokensIncompatible(uint256 projectId, address token, IJBTerminal terminal);

    /// @notice The token is not in the project's accounting contexts on this terminal.
    error JBMultiTerminal_TokenNotAccepted(address token);

    /// @notice A cross-terminal recipient did not consume its temporary ERC-20 allowance.
    error JBMultiTerminal_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);

    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice Held-fee lock duration in seconds (28 days). Must match `JBMultiTerminal._FEE_HOLDING_SECONDS`
    /// so held fees written from this library and the terminal share an unlock timestamp formula.
    uint256 internal constant _FEE_HOLDING_SECONDS = 2_419_200;

    //*********************************************************************//
    // ----------------------------- structs ---------------------------- //
    //*********************************************************************//

    /// @notice Bundle of terminal immutables passed by `memory` (single stack slot) so library function
    /// signatures stay shallow enough for solc 0.8.28 to compile without `via_ir`.
    struct Deps {
        IJBTerminalStore store;
        IJBDirectory directory;
        IJBFeelessAddresses feelessAddresses;
        IJBProjects projects;
    }

    /// @notice Argument bundle for `cashOutTokensOf`. Same stack-shape rationale as `Deps`.
    struct CashOutArgs {
        address holder;
        uint256 projectId;
        uint256 cashOutCount;
        address tokenToReclaim;
        address payable beneficiary;
        bytes metadata;
    }

    /// @notice Argument bundle for `executeCrossProjectCashOut`. Same stack-shape rationale as `Deps`.
    struct CrossProjectCashOutArgs {
        address holder;
        uint256 projectId;
        uint256 cashOutCount;
        address tokenToReclaim;
        // Address recorded in the `CashOutTokens` event and credited any hook-fee project tokens. For the
        // `Full` variant this is the user-supplied destination beneficiary; for `DonationOnly` it's
        // `_msgSender()` (no separate destination recipient).
        address beneficiary;
        bytes cashOutMetadata;
    }

    /// @notice Argument bundle for `routeReclaimToBeneficiaryProject`. Same stack-shape rationale as `Deps`.
    struct RouteAsPayArgs {
        address tokenToReclaim;
        uint256 reclaimAmount;
        uint256 sourceProjectId;
        uint256 beneficiaryProjectId;
        address beneficiary;
        // The original caller. Forwarded as `payer` into the destination's pay flow so the `_msgSender()`
        // semantics are preserved across the library DELEGATECALL.
        address payer;
        bytes payMetadata;
    }

    //*********************************************************************//
    // ----------------------- external functions ------------------------ //
    //*********************************************************************//

    /// @notice Direct cashout — drop-in replacement for the in-terminal `_cashOutTokensOf` body.
    /// @dev Records the cashout in the store (which burns the project tokens via the controller), applies
    /// the per-branch fee policy (non-zero tax → fee on full reclaim; zero tax → fee on the consumed
    /// portion of `_feeFreeSurplusOf` for round-trip prevention; feeless beneficiary → no fee), fulfills
    /// any cashout hook specs via `JBCashOutHookSpecsLib`, caps the project's fee-free surplus at the
    /// post-outflow balance, takes the aggregated cashout-hook fees, and emits `CashOutTokens`.
    /// @param deps Terminal immutables.
    /// @param feeFreeSurplusOf Storage ref to `JBMultiTerminal._feeFreeSurplusOf`.
    /// @param heldFeesOf Storage ref to `JBMultiTerminal._heldFeesOf`.
    /// @param args Cashout arguments — see `CashOutArgs`.
    /// @return reclaimAmount Net terminal tokens sent to `args.beneficiary` (post-fee, post-hook).
    function cashOutTokensOf(
        Deps memory deps,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        CashOutArgs memory args
    )
        external
        returns (uint256 reclaimAmount)
    {
        // Cache the feeless flag — drives fee policy below and is also passed to the data hook context.
        bool beneficiaryIsFeeless =
            deps.feelessAddresses.isFeelessFor({addr: args.beneficiary, projectId: args.projectId});

        // Record the cashout (which decrements project balance + burns project tokens via the controller)
        // and pull back the data-hook-decided cashout tax rate + hook specs.
        JBRuleset memory ruleset;
        uint256 cashOutTaxRate;
        JBCashOutHookSpecification[] memory hookSpecifications;
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = _recordAndBurnCashOut({
            deps: deps,
            holder: args.holder,
            projectId: args.projectId,
            cashOutCount: args.cashOutCount,
            tokenToReclaim: args.tokenToReclaim,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: args.metadata
        });

        // Per-branch fee policy + transfer-out (only when there's something to reclaim — a data hook can
        // return zero reclaim e.g. when implementing custom cash-out gating).
        uint256 amountEligibleForFees;
        if (reclaimAmount != 0) {
            (reclaimAmount, amountEligibleForFees) = _applyCashOutFeeAndTransfer({
                feeFreeSurplusOf: feeFreeSurplusOf,
                projectId: args.projectId,
                tokenToReclaim: args.tokenToReclaim,
                beneficiary: args.beneficiary,
                beneficiaryIsFeeless: beneficiaryIsFeeless,
                cashOutTaxRate: cashOutTaxRate,
                reclaimAmount: reclaimAmount
            });
        }

        // Run any cashout hooks declared by the data hook. Hook fees accumulate into the aggregate eligible
        // total so they can be charged in a single `_takeFeeFrom` below.
        if (hookSpecifications.length != 0) {
            amountEligibleForFees += _fulfillCashOutHooks({
                deps: deps,
                args: args,
                rulesetId: ruleset.id,
                reclaimAmount: reclaimAmount,
                cashOutTaxRate: cashOutTaxRate,
                hookSpecifications: hookSpecifications
            });
        }

        // Cap fee-free surplus at remaining balance. Placed AFTER hook fulfillment so any balance
        // reductions from hook reentrancy are also accounted for — `_feeFreeSurplusOf[projectId]` must
        // never exceed actual recorded balance, otherwise round-trip prevention over-charges on the next
        // zero-tax cashout.
        _capFeeFreeSurplus({
            store: deps.store, feeFreeSurplusOf: feeFreeSurplusOf, projectId: args.projectId, token: args.tokenToReclaim
        });

        // Cashout fees are NEVER held — `shouldHoldFees: false` matches the long-standing direct-cashout
        // behavior. Held fees only apply to the payout / allowance paths where the project owner can opt in.
        if (amountEligibleForFees != 0) {
            _takeFeeFrom({
                deps: deps,
                heldFeesOf: heldFeesOf,
                projectId: args.projectId,
                token: args.tokenToReclaim,
                amount: amountEligibleForFees,
                beneficiary: args.beneficiary,
                shouldHoldFees: false
            });
        }

        emit IJBCashOutTerminal.CashOutTokens({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: args.projectId,
            holder: args.holder,
            beneficiary: args.beneficiary,
            cashOutCount: args.cashOutCount,
            cashOutTaxRate: cashOutTaxRate,
            reclaimAmount: reclaimAmount,
            metadata: args.metadata,
            caller: msg.sender
        });
    }

    /// @notice Shared cashout-prep step for both cross-project entrypoints (the `Full` and `DonationOnly`
    /// variants of `cashOutAndDeliver`). Records the cashout with `beneficiaryIsFeeless: true` (the source
    /// fee is bound on the destination via the routing step's `_feeFreeSurplusOf` credit), burns the
    /// holder's project tokens, runs any cashout-side hooks, caps the source's fee-free surplus, and takes
    /// hook fees. Returns the gross reclaim amount that the caller must route to the destination project.
    /// @dev `beneficiary` is recorded in the `CashOutTokens` event and credited any fee-project tokens
    /// minted from hook fees. For the `Full` variant it's the user-supplied destination beneficiary; for
    /// `DonationOnly` the caller passes `_msgSender()` (no separate destination recipient).
    /// @return reclaimAmount Gross reclaim from the source project's surplus (before destination routing).
    function executeCrossProjectCashOut(
        Deps memory deps,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        CrossProjectCashOutArgs memory args
    )
        external
        returns (uint256 reclaimAmount)
    {
        // `beneficiaryIsFeeless: true` — the cashout-side fee is intentionally skipped here. Same-terminal
        // routing binds the equivalent fee through `_feeFreeSurplusOf[beneficiaryProjectId]` credits and
        // any source-fee-bound hook forwarding; external/router routing charges the source fee up front.
        JBRuleset memory ruleset;
        uint256 cashOutTaxRate;
        JBCashOutHookSpecification[] memory hookSpecifications;
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = _recordAndBurnCashOut({
            deps: deps,
            holder: args.holder,
            projectId: args.projectId,
            cashOutCount: args.cashOutCount,
            tokenToReclaim: args.tokenToReclaim,
            beneficiaryIsFeeless: true,
            metadata: args.cashOutMetadata
        });

        emit IJBCashOutTerminal.CashOutTokens({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: args.projectId,
            holder: args.holder,
            beneficiary: args.beneficiary,
            cashOutCount: args.cashOutCount,
            cashOutTaxRate: cashOutTaxRate,
            reclaimAmount: reclaimAmount,
            metadata: args.cashOutMetadata,
            caller: msg.sender
        });

        // Cashout-side hook fees still apply — those funds leave the protocol to external hooks. The hook
        // context's beneficiary is `address(this)` (the terminal) since the terminal is custodying the
        // reclaim mid-flow; any fee-project tokens minted from hook fees are credited to `args.beneficiary`
        // when the caller's `_takeFeeFrom` below mints them.
        uint256 amountEligibleForFees;
        if (hookSpecifications.length != 0) {
            amountEligibleForFees = _fulfillCrossProjectCashOutHooks({
                deps: deps,
                args: args,
                rulesetId: ruleset.id,
                reclaimAmount: reclaimAmount,
                cashOutTaxRate: cashOutTaxRate,
                hookSpecifications: hookSpecifications
            });
        }

        // Cap the source project's fee-free surplus at remaining balance after the outflow. Same invariant
        // as `cashOutTokensOf`: every cashout path keeps `_feeFreeSurplusOf[projectId]` consistent with the
        // post-outflow balance so later zero-tax cashouts don't fee phantom amounts.
        _capFeeFreeSurplus({
            store: deps.store, feeFreeSurplusOf: feeFreeSurplusOf, projectId: args.projectId, token: args.tokenToReclaim
        });

        // Cashout-style: immediate processing (no holding). Matches `cashOutTokensOf`.
        if (amountEligibleForFees != 0) {
            _takeFeeFrom({
                deps: deps,
                heldFeesOf: heldFeesOf,
                projectId: args.projectId,
                token: args.tokenToReclaim,
                amount: amountEligibleForFees,
                beneficiary: args.beneficiary,
                shouldHoldFees: false
            });
        }
    }

    /// @notice `cashOutAndDeliver`'s `Full` variant: route the reclaim to B's primary terminal as a `pay`
    /// (mints destination-project tokens), with per-spec source-fee withholding on any non-feeless non-noop
    /// pay-hook divert.
    /// @dev Per-spec ("nuanced") source-fee binding: when the destination terminal is THIS terminal, we
    /// pass `sourceProjectId` through `executeEfficientPay` into `JBPayHookSpecsLib.fulfill`, which
    /// withholds the standard fee from each applicable non-feeless hook payment. The returned
    /// `hookForwardGross` is charged immediately against the source project (cashout-style: never held).
    /// Feeless hook egress is returned separately as fee-exempt/bound. Cross-terminal routing passes `0`
    /// for withholding — the destination terminal owns its own fee model and we can't intercept its
    /// internal hook payments from here.
    /// @dev Same-terminal source-token reclaim not credited as destination fee-free surplus and not already
    /// charged as non-feeless hook egress reverts. External/router routes charge the source fee up front
    /// and route the net amount, so swapped value can return without becoming destination fee-free surplus.
    /// @return beneficiaryTokenCount Destination-project tokens minted to `args.beneficiary`.
    function routeReclaimToBeneficiaryProject(
        Deps memory deps,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        RouteAsPayArgs memory args
    )
        external
        returns (uint256 beneficiaryTokenCount)
    {
        // Resolve the destination terminal (may equal `address(this)` for same-terminal pays, or be a
        // router that swaps before depositing back).
        IJBTerminal destinationTerminal =
            _resolveBeneficiaryTerminal(deps.directory, args.beneficiaryProjectId, args.tokenToReclaim);
        if (destinationTerminal != IJBTerminal(address(this))) {
            return _routeExternalReclaimToBeneficiaryProject({
                deps: deps, heldFeesOf: heldFeesOf, args: args, destinationTerminal: destinationTerminal
            });
        }

        JBAccountingContext[] memory contexts;
        uint256[] memory balancesBefore;
        // Snapshot B's per-context balances on this terminal BEFORE the routing. The post-routing
        // comparison identifies which bucket the reclaim actually landed in.
        (contexts, balancesBefore) = _snapshotBeneficiaryContextBalances(deps.store, args.beneficiaryProjectId);

        // Per-spec source-fee withholding is only effective when the destination pay actually lands on
        // THIS terminal (the lib has no leverage over an external terminal's pay flow). Cross-terminal
        // routes return `hookForwardGross == 0` by construction.

        // Library callback into the terminal's `_efficientPay` (which dispatches same-terminal-internal
        // vs cross-terminal-external pay). The `payer` field carries the original caller through the
        // DELEGATECALL so the pay flow's payer-identity semantics are preserved.
        uint256 hookForwardGross;
        uint256 hookForwardGrossFeeExempt;
        (beneficiaryTokenCount, hookForwardGross, hookForwardGrossFeeExempt) = IJBCashOutOpsExecutor(address(this))
            .executeEfficientPay({
            terminal: destinationTerminal,
            projectId: args.beneficiaryProjectId,
            token: args.tokenToReclaim,
            amount: args.reclaimAmount,
            payer: args.payer,
            beneficiary: args.beneficiary,
            metadata: args.payMetadata,
            withholdFeeForSourceProjectId: args.sourceProjectId
        });

        uint256 creditedSourceTokenAmount = _creditGrowingBeneficiaryContexts({
            store: deps.store,
            feeFreeSurplusOf: feeFreeSurplusOf,
            beneficiaryProjectId: args.beneficiaryProjectId,
            tokenToReclaim: args.tokenToReclaim,
            contexts: contexts,
            balancesBefore: balancesBefore
        });

        uint256 feeBoundAmount = creditedSourceTokenAmount + hookForwardGross + hookForwardGrossFeeExempt;
        if (feeBoundAmount < args.reclaimAmount) {
            if (feeBoundAmount == 0) revert JBMultiTerminal_BeneficiaryProjectNotPaid(args.beneficiaryProjectId);
            revert JBMultiTerminal_SourceFeeSkippedReclaimNotFeeBound({
                projectId: args.beneficiaryProjectId,
                token: args.tokenToReclaim,
                reclaimAmount: args.reclaimAmount,
                feeBoundAmount: feeBoundAmount
            });
        }

        // Charge the source fee on the hook-forwarded gross. Backing already exists in the terminal —
        // `JBPayHookSpecsLib.fulfill` per-spec withheld each fee amount from the hook payments.
        if (hookForwardGross != 0) {
            _takeFeeFrom({
                deps: deps,
                heldFeesOf: heldFeesOf,
                projectId: args.sourceProjectId,
                token: args.tokenToReclaim,
                amount: hookForwardGross,
                beneficiary: args.beneficiary,
                shouldHoldFees: false
            });
        }
    }

    function _routeExternalReclaimToBeneficiaryProject(
        Deps memory deps,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        RouteAsPayArgs memory args,
        IJBTerminal destinationTerminal
    )
        private
        returns (uint256 beneficiaryTokenCount)
    {
        // External/router terminals may swap or forward value before it returns here, so this terminal
        // cannot prove retained source-token backing. Charge the source fee up front and only route net.
        uint256 amountToRoute = args.reclaimAmount
            - _takeFeeFrom({
                deps: deps,
                heldFeesOf: heldFeesOf,
                projectId: args.sourceProjectId,
                token: args.tokenToReclaim,
                amount: args.reclaimAmount,
                beneficiary: args.beneficiary,
                shouldHoldFees: false
            });

        (beneficiaryTokenCount,,) = IJBCashOutOpsExecutor(address(this))
            .executeEfficientPay({
            terminal: destinationTerminal,
            projectId: args.beneficiaryProjectId,
            token: args.tokenToReclaim,
            amount: amountToRoute,
            payer: args.payer,
            beneficiary: args.beneficiary,
            metadata: args.payMetadata,
            withholdFeeForSourceProjectId: 0
        });
    }

    /// @notice `cashOutAndDeliver`'s `DonationOnly` variant: route the reclaim to B's primary terminal as
    /// `addToBalanceOf` (no destination mint, no data-hook invocation).
    /// @dev Parallel to `routeReclaimToBeneficiaryProject` for the pay variant. Same-terminal routes are
    /// fee-free when the full source-token amount is retained here. External/router routes pay the source
    /// fee up front and route net because this terminal cannot prove retained source-token backing after
    /// the external hop. Held-fee return on the destination side is hardcoded `false` — this entry is for
    /// value top-up only, never held-fee unlock.
    function routeReclaimAsAddToBalance(
        Deps memory deps,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        uint256 sourceProjectId,
        uint256 beneficiaryProjectId,
        address tokenToReclaim,
        uint256 reclaimAmount,
        bytes calldata addToBalanceMetadata
    )
        external
    {
        IJBTerminal destinationTerminal =
            _resolveBeneficiaryTerminal(deps.directory, beneficiaryProjectId, tokenToReclaim);
        bool isSameTerminal = destinationTerminal == IJBTerminal(address(this));

        uint256 amountToRoute = reclaimAmount;
        if (!isSameTerminal) {
            amountToRoute -= _takeFeeFrom({
                deps: deps,
                heldFeesOf: heldFeesOf,
                projectId: sourceProjectId,
                token: tokenToReclaim,
                amount: reclaimAmount,
                beneficiary: msg.sender,
                shouldHoldFees: false
            });
        }

        JBAccountingContext[] memory contexts;
        uint256[] memory balancesBefore;
        if (isSameTerminal) {
            (contexts, balancesBefore) = _snapshotBeneficiaryContextBalances(deps.store, beneficiaryProjectId);
        }

        _efficientAddToBalance({
            store: deps.store,
            terminal: destinationTerminal,
            projectId: beneficiaryProjectId,
            token: tokenToReclaim,
            amount: amountToRoute,
            metadata: addToBalanceMetadata
        });

        if (!isSameTerminal) return;

        uint256 creditedSourceTokenAmount = _creditGrowingBeneficiaryContexts({
            store: deps.store,
            feeFreeSurplusOf: feeFreeSurplusOf,
            beneficiaryProjectId: beneficiaryProjectId,
            tokenToReclaim: tokenToReclaim,
            contexts: contexts,
            balancesBefore: balancesBefore
        });

        if (creditedSourceTokenAmount < reclaimAmount) {
            if (creditedSourceTokenAmount == 0) revert JBMultiTerminal_BeneficiaryProjectNotPaid(beneficiaryProjectId);
            revert JBMultiTerminal_SourceFeeSkippedReclaimNotFeeBound({
                projectId: beneficiaryProjectId,
                token: tokenToReclaim,
                reclaimAmount: reclaimAmount,
                feeBoundAmount: creditedSourceTokenAmount
            });
        }
    }

    /// @notice Drop-in replacement for the in-terminal `migrateBalanceOf` body. Records the migration in
    /// the store, optionally takes the standard 2.5% fee on the migrated balance (unless `to` is feeless
    /// for the project or this IS the fee project), and transfers the net balance to the destination
    /// terminal via its `addToBalanceOf`.
    /// @dev The terminal's external entry handles the `MIGRATE_TERMINAL` permission check before calling
    /// this; here we focus on the storage update + fee + transfer. Held fees are intentionally NOT moved
    /// — they belong to the fee beneficiary (project #1) and remain processable from the original terminal
    /// even after migration. The migrating project's `_feeFreeSurplusOf` counter is cleared (the deferred
    /// fee liability is settled by the migration fee below).
    /// @return balance Pre-fee migrated balance returned by the store.
    function migrateBalanceOf(
        Deps memory deps,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        returns (uint256 balance)
    {
        // The destination terminal must accept the same token, otherwise the migration would strand funds.
        if (to.accountingContextForTokenOf({projectId: projectId, token: token}).currency == 0) {
            revert JBMultiTerminal_TerminalTokensIncompatible({projectId: projectId, token: token, terminal: to});
        }

        // Clear the deferred-fee counter — settled by the migration fee below.
        delete feeFreeSurplusOf[projectId][token];

        // Zero the project's balance on this terminal and return what it was.
        balance = deps.store.recordTerminalMigration({projectId: projectId, token: token});

        emit IJBTerminal.MigrateTerminal({
            projectId: projectId, token: token, to: to, amount: balance, caller: msg.sender
        });

        if (balance == 0) return balance;

        // Migration to a non-feeless terminal incurs the standard 2.5% fee, same as any other egress. The
        // fee project itself is exempt (migrating fee-collected funds would otherwise re-tax them).
        uint256 feeAmount;
        if (
            !deps.feelessAddresses.isFeelessFor({addr: address(to), projectId: projectId})
                && projectId != JBConstants.FEE_BENEFICIARY_PROJECT_ID
        ) {
            feeAmount = _takeFeeFrom({
                deps: deps,
                heldFeesOf: heldFeesOf,
                projectId: projectId,
                token: token,
                amount: balance,
                beneficiary: payable(deps.projects.ownerOf(projectId)),
                shouldHoldFees: false
            });
        }

        // Forward the net to the destination terminal. Source is `address(this)` (this terminal), so no
        // PERMIT2 path is needed — for ERC-20 we just grant a temporary allowance the recipient consumes.
        uint256 migrationAmount = balance - feeAmount;
        if (token == JBConstants.NATIVE_TOKEN) {
            to.addToBalanceOf{value: migrationAmount}({
                projectId: projectId,
                token: token,
                amount: migrationAmount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });
        } else {
            IERC20(token).forceApprove({spender: address(to), value: migrationAmount});
            to.addToBalanceOf({
                projectId: projectId,
                token: token,
                amount: migrationAmount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });
            // Same allowance-consumed sanity as `_afterTransferTo` in the terminal: if the destination
            // returned without pulling the full allowance, revoke it so it can't be pulled later.
            uint256 leftoverAllowance = IERC20(token).allowance({owner: address(this), spender: address(to)});
            if (leftoverAllowance != 0) {
                IERC20(token).forceApprove({spender: address(to), value: 0});
            }
        }
    }

    /// @notice True iff `destProjectId`'s current ruleset routes inbound pays through a non-zero data hook.
    /// @dev External entry called from `JBMultiTerminal.executePayout` (which is the only other caller
    /// besides this library's internal routing). Lib-internal callers use `_destinationUsesDataHookForPay`
    /// directly to avoid the external-call dispatch overhead.
    function destinationUsesDataHookForPay(IJBDirectory directory, uint256 destProjectId) external view returns (bool) {
        return _destinationUsesDataHookForPay(directory, destProjectId);
    }

    //*********************************************************************//
    // ------------------------ private functions ------------------------ //
    //*********************************************************************//

    /// @notice Apply the cashout fee policy and transfer the net reclaim to the beneficiary.
    /// @dev Three branches, all already validated against the audit suite:
    ///   - feeless beneficiary: no fee, full reclaim
    ///   - non-zero tax: fee on full reclaim
    ///   - zero tax (round-trip prevention): fee only on the consumed portion of `_feeFreeSurplusOf`
    function _applyCashOutFeeAndTransfer(
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        uint256 projectId,
        address tokenToReclaim,
        address payable beneficiary,
        bool beneficiaryIsFeeless,
        uint256 cashOutTaxRate,
        uint256 reclaimAmount
    )
        private
        returns (uint256 netReclaim, uint256 amountEligibleForFees)
    {
        netReclaim = reclaimAmount;
        if (!beneficiaryIsFeeless) {
            if (cashOutTaxRate != 0) {
                // Non-zero tax: fee applies to the full reclaim. The user receives less; the fee project
                // gets the difference.
                amountEligibleForFees = reclaimAmount;
                unchecked {
                    netReclaim = reclaimAmount - JBFees.standardFeeAmountFrom(reclaimAmount);
                }
            } else {
                // Zero tax: fee applies only up to the deferred-fee balance accumulated from prior
                // intra-terminal fee-free inflows. This is the "round-trip prevention" mechanism — without
                // it a project could shuttle funds in (fee-free) and out (zero-tax cashout, also fee-free)
                // to bypass the protocol fee entirely.
                uint256 feeFreeSurplus = feeFreeSurplusOf[projectId][tokenToReclaim];
                if (feeFreeSurplus != 0) {
                    uint256 feeableAmount = reclaimAmount < feeFreeSurplus ? reclaimAmount : feeFreeSurplus;
                    unchecked {
                        feeFreeSurplusOf[projectId][tokenToReclaim] = feeFreeSurplus - feeableAmount;
                    }
                    amountEligibleForFees = feeableAmount;
                    unchecked {
                        netReclaim = reclaimAmount - JBFees.standardFeeAmountFrom(feeableAmount);
                    }
                }
            }
        }

        if (netReclaim != 0) {
            _transferOut({to: beneficiary, token: tokenToReclaim, amount: netReclaim});
        }
    }

    /// @notice Build the cashout-hook context for the direct-cashout path and forward to
    /// `JBCashOutHookSpecsLib.fulfill`. Extracted to keep `cashOutTokensOf`'s stack frame shallow enough
    /// to compile without `via_ir`.
    function _fulfillCashOutHooks(
        Deps memory deps,
        CashOutArgs memory args,
        uint256 rulesetId,
        uint256 reclaimAmount,
        uint256 cashOutTaxRate,
        JBCashOutHookSpecification[] memory hookSpecifications
    )
        private
        returns (uint256 amountEligibleForFees)
    {
        JBTokenAmount memory reclaimTokenAmount =
            _tokenAmountOf(deps.store, args.projectId, args.tokenToReclaim, reclaimAmount);

        // Build the struct field-by-field rather than as a literal — a 10-field struct literal trips
        // solc 0.8.28's non-via-ir Yul stack ceiling from inside this function.
        JBAfterCashOutRecordedContext memory ctx;
        ctx.holder = args.holder;
        ctx.projectId = args.projectId;
        ctx.rulesetId = rulesetId;
        ctx.cashOutCount = args.cashOutCount;
        ctx.reclaimedAmount = reclaimTokenAmount;
        ctx.forwardedAmount = reclaimTokenAmount;
        ctx.cashOutTaxRate = cashOutTaxRate;
        ctx.beneficiary = args.beneficiary;
        ctx.cashOutMetadata = args.metadata;

        amountEligibleForFees = JBCashOutHookSpecsLib.fulfill(deps.feelessAddresses, ctx, hookSpecifications);
    }

    /// @notice Build the cashout-hook context for the cross-project path and forward to
    /// `JBCashOutHookSpecsLib.fulfill`. Hook beneficiary is `address(this)` (the terminal is custodying
    /// the reclaim mid-flow — the destination beneficiary doesn't see the funds until the routing step).
    function _fulfillCrossProjectCashOutHooks(
        Deps memory deps,
        CrossProjectCashOutArgs memory args,
        uint256 rulesetId,
        uint256 reclaimAmount,
        uint256 cashOutTaxRate,
        JBCashOutHookSpecification[] memory hookSpecifications
    )
        private
        returns (uint256 amountEligibleForFees)
    {
        JBTokenAmount memory reclaimTokenAmount =
            _tokenAmountOf(deps.store, args.projectId, args.tokenToReclaim, reclaimAmount);

        JBAfterCashOutRecordedContext memory ctx;
        ctx.holder = args.holder;
        ctx.projectId = args.projectId;
        ctx.rulesetId = rulesetId;
        ctx.cashOutCount = args.cashOutCount;
        ctx.reclaimedAmount = reclaimTokenAmount;
        ctx.forwardedAmount = reclaimTokenAmount;
        ctx.cashOutTaxRate = cashOutTaxRate;
        ctx.beneficiary = payable(address(this));
        ctx.cashOutMetadata = args.cashOutMetadata;

        amountEligibleForFees = JBCashOutHookSpecsLib.fulfill(deps.feelessAddresses, ctx, hookSpecifications);
    }

    /// @notice Record the cashout in the store and burn the holder's project tokens via the controller.
    /// @dev The controller / store handle the data-hook callout and access checks. `cashOutCount == 0` is
    /// allowed (the data hook may decide to return zero reclaim without burning anything).
    function _recordAndBurnCashOut(
        Deps memory deps,
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
        bytes memory metadata
    )
        private
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        IJBController controller = IJBController(address(deps.directory.controllerOf(projectId)));

        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = deps.store
            .recordCashOutFor({
                holder: holder,
                projectId: projectId,
                cashOutCount: cashOutCount,
                tokenToReclaim: tokenToReclaim,
                beneficiaryIsFeeless: beneficiaryIsFeeless,
                metadata: metadata
            });

        if (cashOutCount != 0) {
            controller.burnTokensOf({holder: holder, projectId: projectId, tokenCount: cashOutCount, memo: ""});
        }
    }

    /// @notice Resolve the beneficiary project's primary terminal for the reclaim token. Reverts if the
    /// directory has no entry — without a destination, the source-fee skip would leak.
    function _resolveBeneficiaryTerminal(
        IJBDirectory directory,
        uint256 beneficiaryProjectId,
        address tokenToReclaim
    )
        private
        view
        returns (IJBTerminal destinationTerminal)
    {
        destinationTerminal = directory.primaryTerminalOf({projectId: beneficiaryProjectId, token: tokenToReclaim});
        if (address(destinationTerminal) == address(0)) {
            revert JBMultiTerminal_RecipientProjectTerminalNotFound({
                projectId: beneficiaryProjectId, token: tokenToReclaim
            });
        }
    }

    /// @notice Snapshot B's accounting contexts and pre-routing balances on this terminal. Reverts if B
    /// has no accounting contexts here (no bucket exists for the reclaim to land in).
    function _snapshotBeneficiaryContextBalances(
        IJBTerminalStore store,
        uint256 beneficiaryProjectId
    )
        private
        view
        returns (JBAccountingContext[] memory contexts, uint256[] memory balancesBefore)
    {
        contexts = store.accountingContextsOf({terminal: address(this), projectId: beneficiaryProjectId});
        if (contexts.length == 0) {
            revert JBMultiTerminal_BeneficiaryProjectHasNoAccountingContexts(beneficiaryProjectId);
        }
        balancesBefore = new uint256[](contexts.length);
        for (uint256 i; i < contexts.length;) {
            balancesBefore[i] =
                store.balanceOf({terminal: address(this), projectId: beneficiaryProjectId, token: contexts[i].token});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Credit every beneficiary accounting context whose balance grew during routing.
    /// @dev Returns only the amount actually credited in the source token. Cross-token credits are still
    /// recorded to their own `_feeFreeSurplusOf[B][token]` buckets, but they do not prove source-token fee
    /// binding for the reclaim and therefore do not offset the caller's source-token safety check.
    function _creditGrowingBeneficiaryContexts(
        IJBTerminalStore store,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        uint256 beneficiaryProjectId,
        address tokenToReclaim,
        JBAccountingContext[] memory contexts,
        uint256[] memory balancesBefore
    )
        private
        returns (uint256 creditedSourceTokenAmount)
    {
        for (uint256 i; i < contexts.length;) {
            uint256 balanceAfter =
                store.balanceOf({terminal: address(this), projectId: beneficiaryProjectId, token: contexts[i].token});

            if (balanceAfter > balancesBefore[i]) {
                uint256 balanceDelta = balanceAfter - balancesBefore[i];

                unchecked {
                    feeFreeSurplusOf[beneficiaryProjectId][contexts[i].token] += balanceDelta;
                }

                _capFeeFreeSurplus({
                    store: store,
                    feeFreeSurplusOf: feeFreeSurplusOf,
                    projectId: beneficiaryProjectId,
                    token: contexts[i].token
                });

                if (contexts[i].token == tokenToReclaim) {
                    unchecked {
                        creditedSourceTokenAmount += balanceDelta;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        // No direct revert here: full same-terminal hook forwarding can fee-bind the whole reclaim without
        // a retained balance delta. Callers compare this return value against the reclaim they need bound.
    }

    /// @notice Private mirror of `destinationUsesDataHookForPay` used internally by routing functions.
    /// Avoids the external-call dispatch overhead when the call is already inside this library.
    function _destinationUsesDataHookForPay(IJBDirectory directory, uint256 destProjectId) private view returns (bool) {
        (, JBRulesetMetadata memory destMetadata) =
            IJBController(address(directory.controllerOf(destProjectId))).currentRulesetOf(destProjectId);
        return destMetadata.useDataHookForPay && destMetadata.dataHook != address(0);
    }

    /// @notice Cap `_feeFreeSurplusOf[projectId][token]` at the current store balance for the project.
    /// Storage-ref variant of `JBMultiTerminal._capFeeFreeSurplus`.
    /// @dev The cap maintains the invariant `_feeFreeSurplusOf <= STORE.balanceOf(projectId, token)`.
    /// Without it, round-trip prevention would over-charge on the next zero-tax cashout (the cashout
    /// fee would apply to phantom amounts beyond the actual recorded balance).
    function _capFeeFreeSurplus(
        IJBTerminalStore store,
        mapping(uint256 => mapping(address => uint256)) storage feeFreeSurplusOf,
        uint256 projectId,
        address token
    )
        private
    {
        uint256 feeFreeSurplus = feeFreeSurplusOf[projectId][token];
        if (feeFreeSurplus == 0) return;

        uint256 remainingBalance = store.balanceOf({terminal: address(this), projectId: projectId, token: token});
        if (feeFreeSurplus > remainingBalance) {
            feeFreeSurplusOf[projectId][token] = remainingBalance;
        }
    }

    /// @notice Either push to the held-fees queue (lazy fee — claimable for `_FEE_HOLDING_SECONDS` via
    /// `addToBalanceOf` with `shouldReturnHeldFees: true`) or process the fee immediately via
    /// `JBHeldFeesLib.processFee`. Storage-ref variant of `JBMultiTerminal._takeFeeFrom`.
    /// @dev Held-queue push stores the GROSS `amount` — the fee is re-derived at process / return time so
    /// rounding stays consistent. The immediate path doesn't touch `heldFeesOf` (or
    /// `_nextHeldFeeIndexOf`), so this function only takes `heldFeesOf` as a storage ref.
    /// @return feeAmount The standard fee on `amount`. Returned regardless of branch so callers can
    /// subtract it from a net amount on the immediate-process path.
    function _takeFeeFrom(
        Deps memory deps,
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bool shouldHoldFees
    )
        private
        returns (uint256 feeAmount)
    {
        feeAmount = JBFees.standardFeeAmountFrom(amount);

        if (shouldHoldFees) {
            // Held fee: push to the per-(project,token) queue with the unlock-timestamp 28 days out. The
            // fee project (#1) can later claim these via `processHeldFeesOf`; the project itself can
            // reclaim the implied fee by topping up via `addToBalanceOf` with `shouldReturnHeldFees: true`
            // within the lock window.
            heldFeesOf[projectId][token].push(
                JBFee({
                    amount: amount,
                    beneficiary: beneficiary,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    unlockTimestamp: uint48(block.timestamp + _FEE_HOLDING_SECONDS)
                })
            );
            emit IJBFeeTerminal.HoldFee({
                projectId: projectId,
                token: token,
                amount: amount,
                fee: JBConstants.FEE,
                beneficiary: beneficiary,
                caller: msg.sender
            });
        } else {
            // Immediate fee: route to the fee beneficiary project's primary terminal for `token`. The
            // library wraps the routing in a try/catch — if the fee terminal rejects, the fee is credited
            // back to the source project's balance (forgiven, not retried).
            IJBTerminal feeTerminal =
                deps.directory.primaryTerminalOf({projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID, token: token});
            JBHeldFeesLib.processFee({
                store: deps.store,
                projectId: projectId,
                token: token,
                amount: feeAmount,
                beneficiary: beneficiary,
                feeTerminal: feeTerminal,
                wasHeld: false
            });
        }
    }

    /// @notice Add routed funds to a destination project, using direct store accounting for same-terminal
    /// deliveries and a temporary allowance / value transfer for cross-terminal deliveries.
    function _efficientAddToBalance(
        IJBTerminalStore store,
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        bytes calldata metadata
    )
        private
    {
        if (terminal == IJBTerminal(address(this))) {
            emit IJBTerminal.AddToBalance({
                projectId: projectId,
                amount: amount,
                returnedFees: 0,
                memo: "",
                metadata: metadata,
                caller: address(this)
            });
            store.recordAddedBalanceFor({projectId: projectId, token: token, amount: amount});
        } else if (token == JBConstants.NATIVE_TOKEN) {
            terminal.addToBalanceOf{value: amount}({
                projectId: projectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: metadata
            });
        } else {
            IERC20(token).forceApprove({spender: address(terminal), value: amount});
            terminal.addToBalanceOf({
                projectId: projectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: metadata
            });

            uint256 allowance = IERC20(token).allowance({owner: address(this), spender: address(terminal)});
            if (allowance != 0) {
                IERC20(token).forceApprove({spender: address(terminal), value: 0});
                revert JBMultiTerminal_TemporaryAllowanceNotConsumed(token, address(terminal), allowance);
            }
        }
    }

    /// @notice Transfer terminal tokens FROM this terminal TO `to`. Cashout-side variant of
    /// `JBMultiTerminal._transferFrom` (source is always `address(this)`, so no PERMIT2 path is needed).
    function _transferOut(address payable to, address token, uint256 amount) private {
        if (token == JBConstants.NATIVE_TOKEN) {
            Address.sendValue({recipient: to, amount: amount});
        } else {
            IERC20(token).safeTransfer({to: to, value: amount});
        }
    }

    /// @notice Look up the project's accounting context for `token` and bundle the amount into a
    /// `JBTokenAmount` for forwarding to hooks. Reverts via `_accountingContextOf` if not accepted.
    function _tokenAmountOf(
        IJBTerminalStore store,
        uint256 projectId,
        address token,
        uint256 value
    )
        private
        view
        returns (JBTokenAmount memory)
    {
        JBAccountingContext memory ctx = _accountingContextOf(store, projectId, token);
        return JBTokenAmount({token: token, decimals: ctx.decimals, currency: ctx.currency, value: value});
    }

    /// @notice Read the project's accounting context for a token from the store; revert if the token is
    /// not accepted by the project on this terminal.
    function _accountingContextOf(
        IJBTerminalStore store,
        uint256 projectId,
        address token
    )
        private
        view
        returns (JBAccountingContext memory ctx)
    {
        ctx = store.accountingContextOf({terminal: address(this), projectId: projectId, token: token});
        if (ctx.token == address(0)) revert JBMultiTerminal_TokenNotAccepted(token);
    }
}
