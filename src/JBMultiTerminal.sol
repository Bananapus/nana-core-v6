// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBCashOutTerminal} from "./interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "./interfaces/IJBController.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "./interfaces/IJBFeelessAddresses.sol";
import {IJBFeeTerminal} from "./interfaces/IJBFeeTerminal.sol";
import {IJBMultiTerminal} from "./interfaces/IJBMultiTerminal.sol";
import {IJBPayoutTerminal} from "./interfaces/IJBPayoutTerminal.sol";
import {IJBPermissioned} from "./interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "./interfaces/IJBPermitTerminal.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBSplitHook} from "./interfaces/IJBSplitHook.sol";
import {IJBSplits} from "./interfaces/IJBSplits.sol";
import {IJBTerminal} from "./interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "./interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "./interfaces/IJBTokens.sol";
import {JBPayType} from "./enums/JBPayType.sol";
import {JBCashOutOpsLib} from "./libraries/JBCashOutOpsLib.sol";
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBFees} from "./libraries/JBFees.sol";
import {JBHeldFeesLib} from "./libraries/JBHeldFeesLib.sol";
import {JBMetadataResolver} from "./libraries/JBMetadataResolver.sol";
import {JBPayHookSpecsLib} from "./libraries/JBPayHookSpecsLib.sol";
import {JBPayoutSplitGroupLib} from "./libraries/JBPayoutSplitGroupLib.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "./structs/JBAfterPayRecordedContext.sol";
import {JBCashOutHookSpecification} from "./structs/JBCashOutHookSpecification.sol";
import {JBFee} from "./structs/JBFee.sol";
import {JBPayHookSpecification} from "./structs/JBPayHookSpecification.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";
import {JBRulesetMetadata} from "./structs/JBRulesetMetadata.sol";
import {JBSingleAllowance} from "./structs/JBSingleAllowance.sol";
import {JBSplit} from "./structs/JBSplit.sol";
import {JBSplitHookContext} from "./structs/JBSplitHookContext.sol";
import {JBTokenAmount} from "./structs/JBTokenAmount.sol";

/// @notice The main entry point for all money movement in Juicebox. Handles payments (ETH or ERC-20), cash outs
/// (burning tokens to reclaim funds), payouts (distributing funds to splits), and surplus allowance withdrawals.
/// Charges a 2.5% protocol fee on outflows (held for 28 days before processing). Supports Permit2 for gasless
/// ERC-20 approvals.
/// @dev Each project can have multiple terminals for different tokens. The terminal delegates accounting to
/// `JBTerminalStore` and splits distribution to `JBSplits`. Fees are sent to project #1 (the fee beneficiary).
/// All external hook calls (pay hooks, cash-out hooks, split hooks) are wrapped in try-catch to prevent griefing.
contract JBMultiTerminal is JBPermissioned, ERC2771Context, IJBMultiTerminal {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBMultiTerminal_BeneficiaryProjectFeeFreeInflowsPaused(uint256 projectId);
    error JBMultiTerminal_BeneficiaryProjectHasNoAccountingContexts(uint256 projectId);
    error JBMultiTerminal_BeneficiaryProjectNotPaid(uint256 projectId);
    error JBMultiTerminal_FeeTerminalNotFound(address token);
    error JBMultiTerminal_MintNotAllowed(uint256 projectId, uint256 splitProjectId, address terminal);
    error JBMultiTerminal_NoMsgValueAllowed(uint256 value);
    error JBMultiTerminal_OverflowAlert(uint256 value, uint256 limit);
    error JBMultiTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);
    error JBMultiTerminal_RecipientProjectTerminalNotFound(uint256 projectId, address token);
    error JBMultiTerminal_SplitHookInvalid(IJBSplitHook hook);
    error JBMultiTerminal_TerminalTokensIncompatible(uint256 projectId, address token, IJBTerminal terminal);
    error JBMultiTerminal_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);
    error JBMultiTerminal_TokenNotAccepted(address token);
    error JBMultiTerminal_UnderMin(uint256 value, uint256 min);

    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The number of seconds fees can be held for.
    uint256 internal constant _FEE_HOLDING_SECONDS = 2_419_200; // 28 days

    //*********************************************************************//
    // ----------------------------- structs ----------------------------- //
    //*********************************************************************//

    struct PayHookForwarding {
        uint256 feeEligible;
        uint256 feeExempt;
    }

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for PROJECTS.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The contract that stores addresses that shouldn't incur fees when paid towards or from.
    IJBFeelessAddresses public immutable override FEELESS_ADDRESSES;

    /// @notice The Permit2 contract used for token approvals and transfers.
    IPermit2 public immutable override PERMIT2;

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The contract that stores splits for each project.
    IJBSplits public immutable override SPLITS;

    /// @notice The contract that stores and manages the terminal's data.
    IJBTerminalStore public immutable override STORE;

    /// @notice The contract storing and managing project rulesets.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The cumulative amount of fee-free intra-terminal payouts a project has received for a given token.
    /// @dev Incremented each time a fee-free payout lands (same terminal, no fee charged). During cashout with
    /// `cashOutTaxRate == 0`, fees are applied only up to this amount, then decremented. This prevents a round-trip
    /// fee bypass (intra-terminal payout → zero-tax cashout) while scoping the fee precisely to the fee-free inflow
    /// — legitimate cashouts beyond this amount remain fee-free.
    /// @dev Lifecycle: incremented on fee-free intra-terminal payouts. After any outflow (payouts, useAllowanceOf,
    /// non-zero-tax or feeless cashouts), capped at remaining balance — non-fee-free funds are considered to leave
    /// first, preserving the fee-free counter. Consumed during zero-tax cashouts. Cleared on terminal migration.
    /// @dev Persists across rulesets — projects switching from zero-tax to non-zero-tax carry forward any
    /// unconsumed balance. There is no admin function to reset it.
    /// @custom:param projectId The ID of the project that received the payout.
    /// @custom:param token The token that was received.
    mapping(uint256 projectId => mapping(address token => uint256)) internal _feeFreeSurplusOf;

    /// @notice Fees currently held for each project.
    /// @dev Projects can temporarily hold fees and unlock them later by adding funds to the project's balance.
    /// @dev Held fees can be processed at any time by this terminal's owner.
    /// @custom:param projectId The ID of the project holding fees.
    /// @custom:param token The token the fees are held in.
    mapping(uint256 projectId => mapping(address token => JBFee[])) internal _heldFeesOf;

    /// @notice The next index to use when processing a next held fee.
    /// @custom:param projectId The ID of the project holding fees.
    /// @custom:param token The token the fees are held in.
    mapping(uint256 projectId => mapping(address token => uint256)) internal _nextHeldFeeIndexOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param feelessAddresses A contract that stores addresses that shouldn't incur fees when paid towards or
    /// from.
    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param splits A contract that stores splits for each project.
    /// @param store A contract that stores the terminal's data.
    /// @param permit2 A permit2 utility.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        IJBFeelessAddresses feelessAddresses,
        IJBPermissions permissions,
        IJBProjects projects,
        IJBSplits splits,
        IJBTerminalStore store,
        IJBTokens tokens,
        IPermit2 permit2,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = store.DIRECTORY();
        FEELESS_ADDRESSES = feelessAddresses;
        PROJECTS = projects;
        SPLITS = splits;
        STORE = store;
        TOKENS = tokens;
        PERMIT2 = permit2;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Registers new tokens that this terminal can accept for a project. Once a token's accounting context is
    /// added, the project can receive payments in that token.
    /// @dev Only the project's owner, an operator with `ADD_ACCOUNTING_CONTEXTS` permission, or the project's
    /// controller can call this.
    /// @param projectId The ID of the project having to add accounting contexts for.
    /// @param accountingContexts The accounting contexts to add.
    function addAccountingContextsFor(
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: _ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.ADD_ACCOUNTING_CONTEXTS,
            alsoGrantAccessIf: _msgSender() == address(_controllerOf(projectId))
        });

        // Record all accounting contexts in the store (validates each and reverts if invalid).
        STORE.recordAccountingContextOf({projectId: projectId, contexts: accountingContexts});

        // Emit an event for each accounting context.
        for (uint256 i; i < accountingContexts.length;) {
            emit SetAccountingContext({projectId: projectId, context: accountingContexts[i], caller: _msgSender()});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Adds funds (terminal tokens) to a project's balance without minting project tokens. Useful for topping
    /// up a project or returning funds. Can also unlock previously held fees by returning them to the project's
    /// balance.
    /// @dev If `shouldReturnHeldFees` is true, the added amount offsets held fees proportionally.
    /// @param projectId The ID of the project to add funds to the balance of.
    /// @param token The terminal token being added (the ERC-20, or `JBConstants.NATIVE_TOKEN` for native).
    /// @param amount The amount of the terminal `token` to add, as a fixed point number with the same number of
    /// decimals as the token's accounting context. If `token` is the native token, this argument is ignored and
    /// `msg.value` is used instead.
    /// @param shouldReturnHeldFees If true, return held fees proportional to the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Extra data to pass along to the emitted event.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
    {
        // Add to balance.
        _addToBalanceOf({
            projectId: projectId,
            token: token,
            amount: _acceptFundsFor({projectId: projectId, token: token, amount: amount, metadata: metadata}),
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Burn project tokens to reclaim a share of the project's surplus (held as a terminal token). The
    /// project's current ruleset determines the reclaimed amount, plus any data hook or cash out hook behavior.
    /// @dev Only the project token holder, or an operator with `CASH_OUT_TOKENS` permission from that holder, can call
    /// this.
    /// @dev Two distinct tokens are involved: **project tokens** (`cashOutCount`) are burned from `holder`, and
    /// **terminal tokens** (`tokenToReclaim`) are sent to `beneficiary` in exchange.
    /// @param holder The account whose project tokens are being burned.
    /// @param projectId The ID of the project the project tokens belong to.
    /// @param cashOutCount The number of project tokens to burn, as a fixed point number with 18 decimals.
    /// @param tokenToReclaim The terminal token to reclaim from the project's surplus.
    /// @param minTokensReclaimed The minimum number of terminal tokens that must be returned to `beneficiary` for the
    /// call to succeed, as a fixed point number with the same number of decimals as the terminal token's accounting
    /// context. If fewer terminal tokens would be reclaimed, the cash out is reverted.
    /// @param beneficiary The address to send the reclaimed terminal tokens to, and to pass along to the ruleset's
    /// data hook and cash out hook if applicable.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and cash out hook if
    /// applicable.
    /// @return reclaimAmount The amount of **terminal tokens** sent to `beneficiary` in exchange for the burned project
    /// tokens, as a fixed point number with the same number of decimals as the terminal token's accounting context.
    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        override
        returns (uint256 reclaimAmount)
    {
        _requireCashOutPermissionFrom({holder: holder, projectId: projectId});

        // Build the lib's arg structs field-by-field so the call site stays under solc 0.8.28's non-via-ir
        // Yul stack ceiling (the equivalent nested struct literals overflow it).
        JBCashOutOpsLib.Deps memory deps = _libDeps();

        JBCashOutOpsLib.CashOutArgs memory args;
        args.holder = holder;
        args.projectId = projectId;
        args.cashOutCount = cashOutCount;
        args.tokenToReclaim = tokenToReclaim;
        args.beneficiary = beneficiary;
        args.metadata = metadata;

        reclaimAmount = JBCashOutOpsLib.cashOutTokensOf({
            deps: deps, feeFreeSurplusOf: _feeFreeSurplusOf, heldFeesOf: _heldFeesOf, args: args
        });

        // The amount being reclaimed must be at least as much as was expected.
        _checkMin({value: reclaimAmount, min: minTokensReclaimed});
    }

    /// @notice Executes a payout to a split.
    /// @dev Only accepts calls from this terminal itself.
    /// @param split The split to pay.
    /// @param projectId The ID of the project the split belongs to.
    /// @param token The address of the token to pay to the split.
    /// @param amount The total amount to pay to the split, as a fixed point number with the same number of
    /// decimals as the token's accounting context.
    /// @return netPayoutAmount The amount sent to the split after subtracting fees.
    function executePayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        address originalMessageSender
    )
        external
        returns (uint256 netPayoutAmount, uint256 feeEligibleAmount)
    {
        // NOTICE: May only be called by this terminal itself.
        require(msg.sender == address(this));

        // By default, the net payout amount is the full amount. This will be adjusted if fees are taken.
        netPayoutAmount = amount;

        // If there's a split hook set, transfer to its `process` function.
        if (split.hook != IJBSplitHook(address(0))) {
            // Make sure that the address supports the split hook interface.
            if (!split.hook.supportsInterface(type(IJBSplitHook).interfaceId)) {
                revert JBMultiTerminal_SplitHookInvalid({hook: split.hook});
            }

            if (!_isFeeless({addr: address(split.hook), projectId: projectId})) {
                unchecked {
                    netPayoutAmount -= _feeAmountFrom(amount);
                }
            }

            // Delegate the partial-pull-aware hook invocation to the library so this branch stays compact.
            // The library builds the hook context internally and infers fee-eligibility from
            // `netPayoutAmount < amount` (`true` only when a fee was deducted above).
            (netPayoutAmount, feeEligibleAmount) = JBPayoutSplitGroupLib.invokeSplitHookWithPartial({
                split: split,
                projectId: projectId,
                token: token,
                amount: amount,
                netPayoutAmount: netPayoutAmount,
                store: STORE
            });

            // Otherwise, if a project is specified, make a payment to it.
        } else if (split.projectId != 0) {
            // Get a reference to the terminal being used.
            IJBTerminal terminal = _primaryTerminalOf({projectId: split.projectId, token: token});

            // The project must have a terminal to send funds to.
            if (terminal == IJBTerminal(address(0))) {
                revert JBMultiTerminal_RecipientProjectTerminalNotFound({projectId: split.projectId, token: token});
            }

            // Fees apply to fund egress, not intra-terminal accounting. When both projects share this
            // terminal, funds stay within the contract (`addToBalance` or `pay`) so no fee is charged on
            // the retained portion. Cross-terminal pays incur the standard 2.5% fee here. For the
            // same-terminal pay path, the destination's data hook can still divert a subset of the inbound
            // pay to external pay hooks — that's protocol egress and pays a source fee inline (see
            // `_payProjectSplitWithSourceFeeBinding`), but it's bound INSIDE the pay sub-branch so the
            // self-pay revert (`MintNotAllowed`) below fires first when `split.projectId == projectId`.
            if (terminal != this && !_isFeeless({addr: address(terminal), projectId: projectId})) {
                unchecked {
                    netPayoutAmount -= _feeAmountFrom(amount);
                }
                feeEligibleAmount = amount;
            }

            // Send the `projectId` in the metadata as a referral.
            bytes memory metadata = bytes(abi.encodePacked(projectId));

            // Add to balance if preferred.
            if (split.preferAddToBalance) {
                // Same-terminal addToBalance has no data-hook / pay-hook route, so the full `netPayoutAmount`
                // is retained as fee-free surplus on the destination. Cross-terminal addToBalance is not
                // credited (deferred-fee mechanism is scoped to this terminal).
                if (terminal == this) {
                    _feeFreeSurplusOf[split.projectId][token] += netPayoutAmount;
                }
                _efficientAddToBalance({
                    terminal: terminal,
                    projectId: split.projectId,
                    token: token,
                    amount: netPayoutAmount,
                    metadata: metadata
                });
            } else {
                // Revert if this is a self-referencing payout (project paying itself via a split).
                // Same-project pay splits would mint tokens against existing balance without new funds entering.
                // Projects that want to mint should do so explicitly via the controller.
                // Cross-project pay splits on the same terminal are allowed (different project receives the funds).
                // The try-catch in the split group lib catches this revert and restores the balance.
                if (terminal == this && split.projectId == projectId) {
                    revert JBMultiTerminal_MintNotAllowed({
                        projectId: projectId, splitProjectId: split.projectId, terminal: address(terminal)
                    });
                }

                feeEligibleAmount = _payProjectSplitWithSourceFeeBinding({
                    terminal: terminal,
                    sourceProjectId: projectId,
                    split: split,
                    token: token,
                    grossAmount: amount,
                    netAmount: netPayoutAmount,
                    originalMessageSender: originalMessageSender,
                    metadata: metadata
                });
            }
        } else {
            // If there's a beneficiary, send the funds directly to the beneficiary.
            // If there isn't a beneficiary, send the funds to the  `_msgSender()`.
            address payable recipient =
                split.beneficiary != address(0) ? split.beneficiary : payable(originalMessageSender);

            // This payout is eligible for a fee since the funds are leaving this contract and the recipient isn't a
            // feeless address.
            if (!_isFeeless({addr: recipient, projectId: projectId})) {
                unchecked {
                    netPayoutAmount -= _feeAmountFrom(amount);
                }
                feeEligibleAmount = amount;
            }

            // If there's a beneficiary, send the funds directly to the beneficiary. Otherwise send to the
            // `_msgSender()`.
            _transferFrom({from: address(this), to: recipient, token: token, amount: netPayoutAmount});
        }
    }

    /// @notice Process a specified amount of fees for a project.
    /// @dev Only accepts calls from this terminal itself.
    /// @param projectId The ID of the project paying the fee.
    /// @param token The token the fee is paid in.
    /// @param amount The fee amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address to mint tokens to (from the project which receives fees), and pass along to the
    /// ruleset's data hook and pay hook if applicable.
    /// @param feeTerminal The terminal that'll receive the fees.
    function executeProcessFee(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        IJBTerminal feeTerminal
    )
        external
    {
        // NOTICE: May only be called by this terminal itself.
        require(msg.sender == address(this));

        if (address(feeTerminal) == address(0)) {
            revert JBMultiTerminal_FeeTerminalNotFound({token: token});
        }

        // Send the projectId in the metadata.
        bytes memory metadata = bytes(abi.encodePacked(projectId));

        _efficientPay({
            terminal: feeTerminal,
            projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID,
            token: token,
            amount: amount,
            payer: address(this),
            beneficiary: beneficiary,
            metadata: metadata,
            withholdFeeForSourceProjectId: 0
        });
    }

    /// @notice Transfer funds to an address.
    /// @dev Only accepts calls from this terminal itself.
    /// @param addr The address to transfer funds to.
    /// @param token The token to transfer.
    /// @param amount The amount of tokens to transfer.
    function executeTransferTo(address payable addr, address token, uint256 amount) external {
        // NOTICE: May only be called by this terminal itself.
        require(msg.sender == address(this));

        _transferFrom({from: address(this), to: addr, token: token, amount: amount});
    }

    /// @notice Callback wrapper around the internal `_efficientPay`. Called by `JBCashOutOpsLib`'s routing
    /// functions to dispatch the same-terminal-internal vs cross-terminal-external pay path while staying
    /// inside the library's DELEGATECALL context.
    /// @dev Auth: only callable by this terminal itself. The library calls
    /// `IJBCashOutOpsExecutor(address(this)).executeEfficientPay(...)`; under DELEGATECALL `address(this)`
    /// is the terminal, so the external call produces `msg.sender == address(terminal)` and passes the
    /// check. Same auth pattern as `executePayout` / `executeProcessFee`.
    /// @param terminal The destination terminal (same as `address(this)` or a cross-terminal).
    /// @param projectId Destination project being paid.
    /// @param token Terminal token being paid.
    /// @param amount Amount being paid.
    /// @param payer The payer to record on the destination's data-hook context (carried through from the
    /// original caller so `_msgSender()` semantics survive the DELEGATECALL).
    /// @param beneficiary Beneficiary of the resulting project-token mint.
    /// @param metadata Bytes forwarded to the destination's data hook.
    /// @param withholdFeeForSourceProjectId Source project ID for per-spec source-fee withholding (`0` =
    /// no withholding; only effective for same-terminal pays).
    /// @return newlyIssuedTokenCount Destination-project tokens minted to `beneficiary`.
    /// @return hookForwardGrossFeeEligible Sum of non-feeless non-noop pay-hook spec amounts whose source
    /// fee was withheld (always `0` for cross-terminal pays).
    /// @return hookForwardGrossFeeExempt Sum of feeless pay-hook spec amounts while source-fee binding is on.
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
        returns (uint256 newlyIssuedTokenCount, uint256 hookForwardGrossFeeEligible, uint256 hookForwardGrossFeeExempt)
    {
        require(msg.sender == address(this));
        return _efficientPay({
            terminal: terminal,
            projectId: projectId,
            token: token,
            amount: amount,
            payer: payer,
            beneficiary: beneficiary,
            metadata: metadata,
            withholdFeeForSourceProjectId: withholdFeeForSourceProjectId
        });
    }

    /// @notice Migrate a project's funds and operations to a new terminal that accepts the same token type.
    /// @dev Only a project's owner or an operator with the `MIGRATE_TERMINAL` permission from that owner can migrate
    /// the project's terminal.
    /// @param projectId The ID of the project to migrate.
    /// @param token The address of the token to migrate.
    /// @param to The terminal to migrate to, which will receive the project's funds and operations.
    /// @return balance The amount of funds that were migrated, as a fixed point number with the same amount of decimals
    /// as this terminal.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        override
        returns (uint256 balance)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.MIGRATE_TERMINAL
        });

        JBCashOutOpsLib.Deps memory deps = _libDeps();

        balance = JBCashOutOpsLib.migrateBalanceOf({
            deps: deps,
            feeFreeSurplusOf: _feeFreeSurplusOf,
            heldFeesOf: _heldFeesOf,
            projectId: projectId,
            token: token,
            to: to
        });
    }

    /// @notice Pay a project with a payment token. The project's ruleset determines how many project tokens the
    /// beneficiary receives, plus any data hook or pay hook behavior.
    /// @dev Two distinct tokens are involved: the **payment token** (`token`, e.g. ETH or an ERC-20) flows from the
    /// payer into the terminal, and **project tokens** (the project's own ERC-20 / credit balance) are minted to the
    /// `beneficiary` according to the ruleset's weight.
    /// @param projectId The ID of the project to pay.
    /// @param token The payment token to pay with (the ERC-20, or `JBConstants.NATIVE_TOKEN` for native).
    /// @param amount The amount of the payment `token` to send, as a fixed point number with the same number of
    /// decimals as the token's accounting context. If `token` is the native token, this argument is ignored and
    /// `msg.value` is used in its place.
    /// @param beneficiary The address to mint project tokens to, and to pass along to the ruleset's data hook and pay
    /// hook if applicable.
    /// @param minReturnedTokens The minimum number of project tokens the beneficiary must receive for the payment to
    /// succeed, as a fixed point number with 18 decimals. If fewer project tokens would be minted, the payment is
    /// reverted.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to pass along to the emitted event, as well as the data hook and pay hook if applicable.
    /// @return beneficiaryTokenCount The number of **project tokens** minted to `beneficiary`, as a fixed point number
    /// with 18 decimals.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
        returns (uint256 beneficiaryTokenCount)
    {
        // Get a reference to the beneficiary's balance before the payment.
        uint256 beneficiaryBalanceBefore = TOKENS.totalBalanceOf({holder: beneficiary, projectId: projectId});

        // Accept the funds.
        uint256 acceptedAmount =
            _acceptFundsFor({projectId: projectId, token: token, amount: amount, metadata: metadata});

        // Pay the project. Public-pay path: no source-fee withholding (payer is the user, not an
        // internal protocol transfer with a skipped source-side fee to bind).
        _pay({
            projectId: projectId,
            token: token,
            amount: acceptedAmount,
            payer: _msgSender(),
            beneficiary: beneficiary,
            memo: memo,
            metadata: metadata,
            withholdFeeForSourceProjectId: 0
        });

        // Get a reference to the beneficiary's balance after the payment.
        uint256 beneficiaryBalanceAfter = TOKENS.totalBalanceOf({holder: beneficiary, projectId: projectId});

        // Set the beneficiary token count.
        if (beneficiaryBalanceAfter > beneficiaryBalanceBefore) {
            beneficiaryTokenCount = beneficiaryBalanceAfter - beneficiaryBalanceBefore;
        }

        // The token count for the beneficiary must be greater than or equal to the specified minimum.
        _checkMin({value: beneficiaryTokenCount, min: minReturnedTokens});
    }

    /// @notice Atomically cash out `holder`'s tokens of `projectId` and deliver the reclaim into
    /// `beneficiaryProjectId`. Replaces the prior `payAfterCashOutTokensOf` / `addToBalanceAfterCashOutTokensOf`
    /// pair; the `payType` flag selects between mint-on-delivery (`Full`) and credit-only-delivery
    /// (`DonationOnly`).
    /// @dev Same-terminal retained delivery is credited as destination fee-free surplus. External/router
    /// delivery cannot prove source-token retained backing here, so it pays the source cashout fee up
    /// front and routes only the net amount. For the `Full` variant, if the destination's ruleset routes
    /// pays through a data hook AND the destination terminal is THIS terminal, any pay-hook divert pays
    /// its source fee inline via `JBPayHookSpecsLib.fulfill` per-spec withholding (see
    /// `_routeReclaimAsPayViaLib`).
    /// @dev Held-fee return on the destination side is NOT available through this entry — callers wanting
    /// held-fee unlock must use the direct `addToBalanceOf` with `shouldReturnHeldFees: true`.
    /// @dev The destination's current ruleset can set `pauseCrossProjectFeeFreeInflows` to opt out
    /// (reverts). Same-terminal routes revert if no delivery is fee-bound or retained; external routes
    /// avoid that leak by charging the source fee before the router hop.
    /// @param holder The account whose source-project tokens are being burned.
    /// @param projectId The ID of the source project being cashed out from.
    /// @param cashOutCount The number of source-project tokens to burn.
    /// @param tokenToReclaim The terminal token reclaimed from the source project's surplus.
    /// @param beneficiaryProjectId The destination project receiving the reclaim.
    /// @param beneficiary For `Full`, the address that receives newly-minted destination-project tokens;
    /// for `DonationOnly`, ignored (the caller `_msgSender()` is recorded in the `CashOutTokens` event
    /// slot to keep an audit trail).
    /// @param minTokensOut For `Full`, the minimum destination-token mint required; reverts if unmet.
    /// Ignored for `DonationOnly` (no mint to slippage-check).
    /// @param cashOutMetadata Forwarded to the source project's data hook and any cashout hook specs.
    /// @param deliveryMetadata Forwarded to the destination project's pay flow (`Full`) or the emitted
    /// `AddToBalance` event (`DonationOnly`).
    /// @param payType Variant selector (`Full` mints destination tokens, `DonationOnly` adds to balance).
    /// @return reclaimAmount The gross reclaim amount returned by the source store (pre-routing).
    /// @return beneficiaryTokenCount Destination-project tokens minted to `beneficiary` (always `0` for
    /// `DonationOnly`).
    function cashOutAndDeliver(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 beneficiaryProjectId,
        address beneficiary,
        uint256 minTokensOut,
        bytes calldata cashOutMetadata,
        bytes calldata deliveryMetadata,
        JBPayType payType
    )
        external
        override
        returns (uint256 reclaimAmount, uint256 beneficiaryTokenCount)
    {
        _requireCashOutPermissionFrom({holder: holder, projectId: projectId});
        _requireBeneficiaryAcceptsFeeFreeInflows(beneficiaryProjectId);

        // Burn source-project tokens, run cashout-side hooks, take hook fees, cap source fee-free surplus
        // via the library. Helper-wrapped to keep `cashOutAndDeliver`'s stack frame under solc 0.8.28's
        // non-via-ir Yul ceiling (the struct construction + 10 user-facing params would otherwise overflow).
        reclaimAmount = _executeCrossProjectCashOutViaLib({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            eventBeneficiary: payType == JBPayType.Full ? beneficiary : _msgSender(),
            cashOutMetadata: cashOutMetadata
        });

        if (reclaimAmount == 0) return (0, 0);

        if (payType == JBPayType.Full) {
            beneficiaryTokenCount = _routeReclaimAsPayViaLib({
                tokenToReclaim: tokenToReclaim,
                reclaimAmount: reclaimAmount,
                sourceProjectId: projectId,
                beneficiaryProjectId: beneficiaryProjectId,
                beneficiary: beneficiary,
                payMetadata: deliveryMetadata
            });
            _checkMin({value: beneficiaryTokenCount, min: minTokensOut});
        } else {
            _routeReclaimAsAddToBalanceViaLib({
                tokenToReclaim: tokenToReclaim,
                reclaimAmount: reclaimAmount,
                sourceProjectId: projectId,
                beneficiaryProjectId: beneficiaryProjectId,
                addToBalanceMetadata: deliveryMetadata
            });
        }
    }

    /// @notice Build the `JBCashOutOpsLib.RouteAsPayArgs` struct and delegate to the library's pay-routing
    /// function. Extracted from `cashOutAndDeliver` to keep that entry under solc 0.8.28's non-via-ir Yul
    /// stack ceiling.
    /// @param tokenToReclaim Source token being routed.
    /// @param reclaimAmount Gross reclaim from the source store.
    /// @param sourceProjectId Source project (used for per-spec source-fee withholding inside the lib).
    /// @param beneficiaryProjectId Destination project.
    /// @param beneficiary Destination-project beneficiary for the mint.
    /// @param payMetadata Bytes forwarded to the destination's pay flow.
    /// @return beneficiaryTokenCount Destination tokens minted to `beneficiary`.
    function _routeReclaimAsPayViaLib(
        address tokenToReclaim,
        uint256 reclaimAmount,
        uint256 sourceProjectId,
        uint256 beneficiaryProjectId,
        address beneficiary,
        bytes calldata payMetadata
    )
        private
        returns (uint256 beneficiaryTokenCount)
    {
        JBCashOutOpsLib.RouteAsPayArgs memory rArgs;
        rArgs.tokenToReclaim = tokenToReclaim;
        rArgs.reclaimAmount = reclaimAmount;
        rArgs.sourceProjectId = sourceProjectId;
        rArgs.beneficiaryProjectId = beneficiaryProjectId;
        rArgs.beneficiary = beneficiary;
        // Carry the original caller through the DELEGATECALL so the destination's pay flow sees the right
        // `payer` for its data-hook context.
        rArgs.payer = _msgSender();
        rArgs.payMetadata = payMetadata;

        beneficiaryTokenCount = JBCashOutOpsLib.routeReclaimToBeneficiaryProject({
            deps: _libDeps(), feeFreeSurplusOf: _feeFreeSurplusOf, heldFeesOf: _heldFeesOf, args: rArgs
        });
    }

    /// @notice Delegate to the library's addToBalance-routing function. Extracted alongside
    /// `_routeReclaimAsPayViaLib` for the same stack-shape reason.
    /// @param tokenToReclaim Source token being routed.
    /// @param reclaimAmount Gross reclaim from the source store.
    /// @param sourceProjectId Source project paying any external-router source fee.
    /// @param beneficiaryProjectId Destination project.
    /// @param addToBalanceMetadata Bytes forwarded to the emitted `AddToBalance` event on the destination.
    function _routeReclaimAsAddToBalanceViaLib(
        address tokenToReclaim,
        uint256 reclaimAmount,
        uint256 sourceProjectId,
        uint256 beneficiaryProjectId,
        bytes calldata addToBalanceMetadata
    )
        private
    {
        JBCashOutOpsLib.routeReclaimAsAddToBalance({
            deps: _libDeps(),
            feeFreeSurplusOf: _feeFreeSurplusOf,
            heldFeesOf: _heldFeesOf,
            sourceProjectId: sourceProjectId,
            beneficiaryProjectId: beneficiaryProjectId,
            tokenToReclaim: tokenToReclaim,
            reclaimAmount: reclaimAmount,
            addToBalanceMetadata: addToBalanceMetadata
        });
    }

    /// @notice Processes held fees for a project, sending them to the protocol's fee project. Fees are held for 28 days
    /// after a payout — processing them finalizes the fee payment.
    /// @dev Only processes fees whose `unlockTimestamp` has passed. Stops early if it encounters a still-locked fee.
    /// @dev Reentrancy-safe: re-reads `_nextHeldFeeIndexOf` from storage each iteration and advances the index before
    /// the external `_processFee` call, preventing double-processing.
    /// @dev If `_processFee` reverts (fee terminal rejects), the fee amount is returned to the project's balance
    /// (forgiven, not retried). A `FeeReverted` event is emitted for off-chain observability.
    /// @param projectId The ID of the project to process held fees for.
    /// @param token The token to process held fees for.
    /// @param count The number of fees to process.
    function processHeldFeesOf(uint256 projectId, address token, uint256 count) external override {
        JBHeldFeesLib.processHeldFees({
            heldFeesOf: _heldFeesOf,
            nextHeldFeeIndexOf: _nextHeldFeeIndexOf,
            directory: DIRECTORY,
            store: STORE,
            projectId: projectId,
            token: token,
            count: count
        });
    }

    /// @notice Distributes funds from a project's balance to its payout split recipients, up to the current ruleset's
    /// payout limit. Anyone can call this on behalf of any project.
    /// @dev If splits don't add up to 100%, the remainder goes to the project owner. A wildcard split (no hook,
    /// projectId, or beneficiary) sends its share to `msg.sender` — useful for incentivizing the call.
    /// @dev Payouts to non-feeless addresses incur the 2.5% protocol fee. Projects whose terminal is feeless are
    /// exempt.
    /// @param projectId The ID of the project having its payouts sent.
    /// @param token The token to send.
    /// @param amount The total number of terminal tokens to send, as a fixed point number with the same number of
    /// decimals as the token's accounting context.
    /// @param currency The expected currency of the payouts. Must match the currency of one of the
    /// project's current ruleset's payout limits.
    /// @param minTokensPaidOut The minimum number of terminal tokens that the `amount` should be worth (if expressed
    /// in terms of the token's accounting context currency), as a fixed point number with the same number of decimals
    /// as the token's accounting context. If the amount of tokens paid out would be less than this amount, the send is
    /// reverted.
    /// @return amountPaidOut The total amount paid out.
    function sendPayoutsOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        uint256 minTokensPaidOut
    )
        external
        override
        returns (uint256 amountPaidOut)
    {
        amountPaidOut = _sendPayoutsOf({projectId: projectId, token: token, amount: amount, currency: currency});

        // The amount being paid out must be at least as much as was expected.
        _checkMin({value: amountPaidOut, min: minTokensPaidOut});
    }

    /// @notice Withdraws funds from a project's surplus (beyond what's needed for payouts) up to the current ruleset's
    /// surplus allowance. Sent directly to a beneficiary address rather than through splits.
    /// @dev Only the project's owner or an operator with `USE_ALLOWANCE` permission can call this.
    /// @dev Incurs the 2.5% protocol fee unless the caller is a feeless address. The fee is charged in the terminal
    /// token (`token`); the fee project mints **project tokens** in return and sends them to `feeBeneficiary`.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param token The terminal token to pay out from the surplus.
    /// @param amount The amount of terminal `token` to use from the project's current surplus allowance, as a fixed
    /// point number with the same number of decimals as the token's accounting context.
    /// @param currency The expected currency of `amount`. Must match the currency of one of the project's current
    /// ruleset's surplus allowances.
    /// @param minTokensPaidOut The minimum number of terminal tokens that must be returned from the surplus allowance
    /// (excluding fees), as a fixed point number with the same number of decimals as the terminal token's accounting
    /// context. If less would be paid out, the transaction is reverted.
    /// @param beneficiary The address to send the reclaimed terminal tokens to.
    /// @param feeBeneficiary The address that receives the **project tokens** minted by the fee project in exchange
    /// for the protocol fee paid in terminal tokens.
    /// @param memo A memo to pass along to the emitted event.
    /// @return netAmountPaidOut The number of **terminal tokens** sent to `beneficiary`, net of the protocol fee, as a
    /// fixed point number with the same number of decimals as the terminal token's accounting context.
    function useAllowanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        uint256 minTokensPaidOut,
        address payable beneficiary,
        address payable feeBeneficiary,
        string calldata memo
    )
        external
        override
        returns (uint256 netAmountPaidOut)
    {
        // Keep a reference to the project's owner.
        address owner = _ownerOf(projectId);

        // Enforce permissions.
        _requirePermissionFrom({account: owner, projectId: projectId, permissionId: JBPermissionIds.USE_ALLOWANCE});

        netAmountPaidOut = _useAllowanceOf({
            projectId: projectId,
            owner: owner,
            token: token,
            amount: amount,
            currency: currency,
            beneficiary: beneficiary,
            feeBeneficiary: feeBeneficiary,
            memo: memo
        });

        // The amount being withdrawn must be at least as much as was expected.
        _checkMin({value: netAmountPaidOut, min: minTokensPaidOut});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns the accounting context (decimals, currency) for a specific token that a project accepts.
    /// @param projectId The ID of the project to get token accounting context of.
    /// @param token The token to check the accounting context of.
    /// @return The token's accounting context for the token.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        return STORE.accountingContextOf({terminal: address(this), projectId: projectId, token: token});
    }

    /// @notice Returns accounting contexts for all tokens a project currently accepts through this terminal.
    /// @param projectId The ID of the project to get the accepted tokens of.
    /// @return tokenContexts The accounting contexts of the accepted tokens.
    function accountingContextsOf(uint256 projectId) external view override returns (JBAccountingContext[] memory) {
        return STORE.accountingContextsOf({terminal: address(this), projectId: projectId});
    }

    /// @notice Returns the project's current surplus in this terminal, converted to a specified currency. The surplus
    /// is the balance minus what's needed for payout limits.
    /// @dev If `tokens` is empty, includes all tokens the project accepts.
    /// @param projectId The ID of the project to get the current surplus of.
    /// @param tokens The tokens to include in the surplus calculation. If empty, all tokens are included.
    /// @param decimals The number of decimals to include in the fixed point returned value.
    /// @param currency The currency to express the returned value in terms of.
    /// @return The current surplus amount the project has in this terminal, in terms of `currency` and with the
    /// specified number of decimals.
    function currentSurplusOf(
        uint256 projectId,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256)
    {
        IJBTerminal[] memory self = new IJBTerminal[](1);
        self[0] = IJBTerminal(address(this));
        return STORE.currentSurplusOf({
            projectId: projectId, terminals: self, tokens: tokens, decimals: decimals, currency: currency
        });
    }

    /// @notice Returns the fees currently held for a project. Fees are held for 28 days after a payout before
    /// they can be processed (sent to the fee project).
    /// @dev Held fees can be returned to the project by calling `addToBalanceOf` with `shouldReturnHeldFees = true`
    /// before the 28-day lock expires.
    /// @param projectId The ID of the project holding fees.
    /// @param token The token the fees are held in.
    /// @param count The maximum number of held fees to return.
    /// @return heldFees The held fees.
    function heldFeesOf(
        uint256 projectId,
        address token,
        uint256 count
    )
        external
        view
        override
        returns (JBFee[] memory heldFees)
    {
        // Keep a reference to the start index.
        uint256 startIndex = _nextHeldFeeIndexOf[projectId][token];

        // Get a reference to the number of held fees.
        uint256 numberOfHeldFees = _heldFeesOf[projectId][token].length;

        // If the start index is greater than or equal to the number of held fees, return 0.
        if (startIndex >= numberOfHeldFees) return new JBFee[](0);

        // If the start index plus the count is greater than the number of fees, set the count to the number of fees
        if (startIndex + count > numberOfHeldFees) count = numberOfHeldFees - startIndex;

        // Create a new array to hold the fees.
        heldFees = new JBFee[](count);

        // Copy the fees into the array.
        for (uint256 i; i < count;) {
            heldFees[i] = _heldFeesOf[projectId][token][startIndex + i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Simulates a cash out without modifying state — use this to preview how many tokens a holder would
    /// reclaim.
    /// @param holder The address cashing out tokens.
    /// @param projectId The ID of the project cashing out tokens.
    /// @param cashOutCount The number of project tokens to cash out.
    /// @param tokenToReclaim The token to reclaim from the project's surplus.
    /// @param beneficiary The address that would receive the reclaimed tokens.
    /// @param metadata Extra data to send to the data hook and cash out hooks.
    /// @return ruleset The project's current ruleset.
    /// @return reclaimAmount The amount of tokens that would be reclaimed from the project's surplus.
    /// @return cashOutTaxRate The cash out tax rate that would be applied.
    /// @return hookSpecifications Any cash out hook specifications from the data hook.
    function previewCashOutFrom(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        view
        override
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        bool feeless = _isFeeless({addr: beneficiary, projectId: projectId});
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = STORE.previewCashOutFrom({
            terminal: address(this),
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: feeless,
            metadata: metadata
        });
    }

    /// @notice Simulates a payment without modifying state — use this to preview how many project tokens a payer
    /// would
    /// receive.
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with.
    /// @param amount The amount of tokens to pay.
    /// @param beneficiary The address to mint project tokens to.
    /// @param metadata Extra data to pass along to the data hook and pay hooks.
    /// @return ruleset The project's current ruleset.
    /// @return beneficiaryTokenCount The number of project tokens that would be minted for the beneficiary.
    /// @return reservedTokenCount The number of project tokens that would be reserved.
    /// @return hookSpecifications Any pay hook specifications from the data hook.
    function previewPayFor(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        override
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        // Keep a reference to the token count returned by the store preview.
        uint256 tokenCount;

        // Preview the payment through the store.
        (ruleset, tokenCount, hookSpecifications) = STORE.previewPayFrom({
            terminal: address(this),
            payer: _msgSender(),
            amount: _tokenAmountOf({projectId: projectId, token: token, value: amount}),
            projectId: projectId,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Split the token count into beneficiary and reserved portions using the controller preview.
        (beneficiaryTokenCount, reservedTokenCount) = _controllerOf(projectId)
            .previewMintOf({projectId: projectId, tokenCount: tokenCount, useReservedPercent: true});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBMultiTerminal).interfaceId || interfaceId == type(IJBPermissioned).interfaceId
            || interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBCashOutTerminal).interfaceId
            || interfaceId == type(IJBPayoutTerminal).interfaceId || interfaceId == type(IJBPermitTerminal).interfaceId
            || interfaceId == type(IJBFeeTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accepts an incoming token.
    /// @param projectId The ID of the project to accept the transfer for.
    /// @param token The token to accept.
    /// @param amount The number of tokens to accept.
    /// @param metadata The metadata in which permit2 context is provided.
    /// @return amount The number of tokens which have been accepted.
    function _acceptFundsFor(
        uint256 projectId,
        address token,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        returns (uint256)
    {
        // Make sure the project has an accounting context for the token being paid.
        _accountingContextOf({projectId: projectId, token: token});

        // If the terminal's token is the native token, override `amount` with `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // If the terminal's token is not native, revert if there is a non-zero `msg.value`.
        if (msg.value != 0) revert JBMultiTerminal_NoMsgValueAllowed(msg.value);

        // Unpack the allowance to use, if any, given by the frontend.
        (bool exists, bytes memory parsedMetadata) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("permit2"), metadata: metadata});

        // Check if the metadata contains permit data.
        if (exists) {
            // Keep a reference to the allowance context parsed from the metadata.
            (JBSingleAllowance memory allowance) = abi.decode(parsedMetadata, (JBSingleAllowance));

            // Make sure the permit allowance is enough for this payment. If not we revert early.
            if (amount > allowance.amount) {
                revert JBMultiTerminal_PermitAllowanceNotEnough({amount: amount, allowance: allowance.amount});
            }

            // Keep a reference to the permit rules.
            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token, amount: allowance.amount, expiration: allowance.expiration, nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            // Set the allowance to `spend` tokens for the user.
            try PERMIT2.permit({owner: _msgSender(), permitSingle: permitSingle, signature: allowance.signature}) {}
            catch (bytes memory reason) {
                emit Permit2AllowanceFailed({token: token, owner: _msgSender(), reason: reason});
            }
        }

        // Get a reference to the balance before receiving tokens.
        uint256 balanceBefore = _balanceOf(token);

        // Transfer tokens to this terminal from the msg sender.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        // The amount should reflect the change in balance.
        return _balanceOf(token) - balanceBefore;
    }

    /// @notice Adds funds to a project's balance without minting tokens.
    /// @param projectId The ID of the project to add funds to the balance of.
    /// @param token The address of the token to add to the project's balance.
    /// @param amount The amount of tokens to add as a fixed point number with the same number of decimals as this
    /// terminal. If this is a native token terminal, this is ignored and `msg.value` is used instead.
    /// @param shouldReturnHeldFees If true, return held fees proportional to the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Extra data to pass along to the emitted event.
    function _addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string memory memo,
        bytes memory metadata
    )
        internal
    {
        // Return held fees if desired. This mechanism means projects don't pay fees multiple times when funds go out of
        // and back into the protocol.
        uint256 returnedFees =
            shouldReturnHeldFees ? _returnHeldFees({projectId: projectId, token: token, amount: amount}) : 0;

        emit AddToBalance({
            projectId: projectId,
            amount: amount,
            returnedFees: returnedFees,
            memo: memo,
            metadata: metadata,
            caller: _msgSender()
        });

        // Record the added funds with any returned fees.
        _recordAddedBalanceFor({projectId: projectId, token: token, amount: amount + returnedFees});
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    /// @param to The address the transfer is going to.
    /// @param token The token to transfer.
    /// @param amount The number of tokens to transfer, as a fixed point number with the same number of decimals
    /// as this terminal.
    /// @return payValue The value to attach to the transaction.
    function _beforeTransferTo(address to, address token, uint256 amount) internal returns (uint256) {
        // If the token is the native token, no allowance needed, and the full amount should be used as the payValue.
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        // Otherwise, set the allowance, and the payValue should be 0.
        IERC20(token).forceApprove({spender: to, value: amount});
        return 0;
    }

    /// @notice Cap fee-free surplus at the project's remaining balance after an outflow.
    /// @dev Non-fee-free funds are considered to leave first. Fee-free surplus only decreases when the remaining
    /// balance can no longer support it. This prevents attackers from using outflows to drain the fee-free counter
    /// and then cashing out without incurring fees.
    /// @param projectId The ID of the project.
    /// @param token The token whose fee-free surplus to cap.
    function _capFeeFreeSurplus(uint256 projectId, address token) internal {
        // Get the current fee-free surplus for this project/token pair.
        uint256 feeFreeSurplus = _feeFreeSurplusOf[projectId][token];

        // Nothing to cap if there's no fee-free surplus tracked.
        if (feeFreeSurplus == 0) return;

        // Get the project's remaining balance (already decremented by the store's record call).
        uint256 remainingBalance = STORE.balanceOf({terminal: address(this), projectId: projectId, token: token});

        // Cap fee-free surplus at the remaining balance.
        if (feeFreeSurplus > remainingBalance) {
            _feeFreeSurplusOf[projectId][token] = remainingBalance;
        }
    }

    /// @notice `executePayout`'s same-terminal cross-project pay sub-branch, factored out so the
    /// entrypoint stays under solc 0.8.28's non-via-ir Yul stack ceiling.
    /// @dev For same-terminal pays we pass `sourceProjectId` through `_efficientPay` → `_pay` →
    /// `JBPayHookSpecsLib.fulfill`, which per-spec withholds the source fee from each non-feeless non-noop
    /// pay-hook divert and returns the gross. We credit only the RETAINED portion (`amount -
    /// hookForwardGross`) to the destination's `_feeFreeSurplusOf` — the hook-forwarded gross already paid
    /// source fee inline, so re-counting it as fee-free would let the destination cash it out fee-free and
    /// undo the inline charge. The returned `feeEligible` is the hook-forwarded gross, which the
    /// aggregated `_takeFeeFrom` in `_sendPayoutsOf` charges against the source project (honoring source
    /// ruleset's `holdFees()`).
    /// @dev Cross-terminal pays pass `0` for `withholdFeeForSourceProjectId` (the destination terminal
    /// owns its own fee model on inbound pays — we can't intercept its internal hook payments from here)
    /// and `feeEligible` stays `0`.
    /// @param terminal Destination terminal (this terminal or a cross-terminal).
    /// @param sourceProjectId Source project — the project whose payout cycle is funding this split.
    /// @param split Destination project split to pay.
    /// @param token Terminal token being paid.
    /// @param grossAmount Pre-fee split amount. Returned for non-feeless cross-terminal pays.
    /// @param netAmount Post-cross-terminal-fee amount (== `netPayoutAmount` in the caller).
    /// @param originalMessageSender Original payout caller, used as the beneficiary fallback.
    /// @param metadata Pay metadata (the source project ID as a referral).
    /// @return feeEligible Hook-forwarded gross, surfaced to the caller for the aggregated `_takeFeeFrom`.
    function _payProjectSplitWithSourceFeeBinding(
        IJBTerminal terminal,
        uint256 sourceProjectId,
        JBSplit calldata split,
        address token,
        uint256 grossAmount,
        uint256 netAmount,
        address originalMessageSender,
        bytes memory metadata
    )
        private
        returns (uint256 feeEligible)
    {
        // Cache the same-terminal predicate — the inline ternary on the call site below would otherwise
        // blow solc 0.8.28's non-via-ir Yul stack ceiling for this branch.
        bool sameTerminal = terminal == IJBTerminal(address(this));
        uint256 withhold = sameTerminal ? sourceProjectId : 0;
        uint256 destProjectId = split.projectId;
        address beneficiary = split.beneficiary != address(0) ? split.beneficiary : originalMessageSender;

        uint256 balanceBefore;
        if (sameTerminal) {
            balanceBefore = STORE.balanceOf({terminal: address(this), projectId: destProjectId, token: token});
        }

        // Library callback into the terminal's `_efficientPay`. Same-terminal pays go through `_pay` →
        // `JBPayHookSpecsLib.fulfill` with per-spec withholding; cross-terminal pays go through external
        // `terminal.pay()` and the withholding is silently ignored (returns `hookForwardGross == 0`).
        (, uint256 hookForwardGross,) = _efficientPay({
            terminal: terminal,
            projectId: destProjectId,
            token: token,
            amount: netAmount,
            payer: address(this),
            beneficiary: beneficiary,
            metadata: metadata,
            withholdFeeForSourceProjectId: withhold
        });

        // Cross-terminal pays: nothing more to do here — the destination terminal handles its own fees on
        // the inbound pay, and there's no `_feeFreeSurplusOf` credit because the destination's recorded
        // balance grew on the OTHER terminal, not this one. Report fee eligibility only when this terminal
        // actually deducted a source fee before routing.
        if (!sameTerminal) return netAmount < grossAmount ? grossAmount : 0;

        _creditFeeFreeSurplusDelta({projectId: destProjectId, token: token, balanceBefore: balanceBefore});

        // Surface the hook-forwarded gross as fee-eligible against the source project. The aggregated
        // `_takeFeeFrom` in `_sendPayoutsOf` honors source ruleset's `holdFees()` flag, matching the fee
        // policy of ordinary cross-terminal payouts.
        feeEligible = hookForwardGross;
    }

    /// @notice Credit `_feeFreeSurplusOf` by the actual balance delta recorded for a same-terminal pay.
    function _creditFeeFreeSurplusDelta(uint256 projectId, address token, uint256 balanceBefore) private {
        uint256 balanceAfter = STORE.balanceOf({terminal: address(this), projectId: projectId, token: token});
        if (balanceAfter > balanceBefore) {
            unchecked {
                _feeFreeSurplusOf[projectId][token] += balanceAfter - balanceBefore;
            }
        }
        _capFeeFreeSurplus({projectId: projectId, token: token});
    }

    /// @notice Revert if a value is less than the specified minimum.
    /// @param value The value to compare against the minimum.
    /// @param min The minimum acceptable value.
    function _checkMin(uint256 value, uint256 min) internal pure {
        if (value < min) revert JBMultiTerminal_UnderMin(value, min);
    }

    /// @notice Fund a project either by calling this terminal's internal `addToBalance` function or by calling the
    /// recipient terminal's `addToBalance` function.
    /// @param terminal The terminal on which the project is expecting to receive funds.
    /// @param projectId The ID of the project to fund.
    /// @param token The token to use.
    /// @param amount The amount to fund, as a fixed point number with the amount of decimals that the terminal's
    /// accounting context specifies.
    /// @param metadata Additional metadata to include with the payment.
    function _efficientAddToBalance(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        bytes memory metadata
    )
        internal
    {
        // Use the local internal path when staying on this terminal. Otherwise use the efficient external equivalent,
        // which forwards value directly after granting a temporary pull allowance.
        if (terminal == IJBTerminal(address(this))) {
            _addToBalanceOf({
                projectId: projectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: metadata
            });
        } else {
            _externalAddToBalance({
                terminal: terminal, projectId: projectId, token: token, amount: amount, metadata: metadata
            });
        }
    }

    /// @notice Pay a project on either this terminal or a recipient terminal, dispatching the
    /// same-terminal-internal vs cross-terminal-external path.
    /// @dev Same-terminal path: delegates to internal `_pay` and propagates
    /// `withholdFeeForSourceProjectId` through to `JBPayHookSpecsLib.fulfill` for per-spec source-fee
    /// withholding. Cross-terminal path: external `terminal.pay()` with the standard pre-/post-transfer
    /// allowance dance; `withholdFeeForSourceProjectId` is silently ignored (the destination terminal owns
    /// its own fee model on inbound pays — we can't intercept its hook payments from here) and the
    /// returned `hookForwardGrossFeeEligible` stays at the default `0`.
    /// @param terminal Destination terminal.
    /// @param projectId Destination project.
    /// @param token Payment token.
    /// @param amount Payment amount.
    /// @param payer Payer recorded on the destination's data-hook context (carried through from the
    /// original caller, important for cross-project flows under DELEGATECALL).
    /// @param beneficiary Beneficiary of the resulting project-token mint.
    /// @param metadata Bytes forwarded to the destination's data hook / pay hooks.
    /// @param withholdFeeForSourceProjectId Source project ID for per-spec source-fee withholding
    /// (same-terminal pays only; `0` to disable).
    /// @return newlyIssuedTokenCount Destination-project tokens minted to `beneficiary`.
    /// @return hookForwardGrossFeeEligible Sum of non-feeless non-noop pay-hook spec amounts whose source
    /// fee was withheld on the same-terminal path; always `0` for cross-terminal pays.
    /// @return hookForwardGrossFeeExempt Sum of feeless pay-hook spec amounts while source-fee binding is on.
    function _efficientPay(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        address payer,
        address beneficiary,
        bytes memory metadata,
        uint256 withholdFeeForSourceProjectId
    )
        internal
        returns (uint256 newlyIssuedTokenCount, uint256 hookForwardGrossFeeEligible, uint256 hookForwardGrossFeeExempt)
    {
        if (terminal == IJBTerminal(address(this))) {
            PayHookForwarding memory hookForwarding;
            (newlyIssuedTokenCount, hookForwarding) = _pay({
                projectId: projectId,
                token: token,
                amount: amount,
                payer: payer,
                beneficiary: beneficiary,
                memo: "",
                metadata: metadata,
                withholdFeeForSourceProjectId: withholdFeeForSourceProjectId
            });
            return (newlyIssuedTokenCount, hookForwarding.feeEligible, hookForwarding.feeExempt);
        }

        // Cross-terminal: standard pre/post transfer + external `pay()`. The destination terminal owns its
        // own fee model on inbound pays; the `withholdFeeForSourceProjectId` is silently ignored here and
        // `hookForwardGrossFeeEligible` stays at the default `0`.
        uint256 payValue = _beforeTransferTo({to: address(terminal), token: token, amount: amount});

        newlyIssuedTokenCount = terminal.pay{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        _afterTransferTo({to: address(terminal), token: token});
    }

    /// @notice Fund a project on another terminal by granting a temporary pull allowance for this call only.
    /// @param terminal The recipient terminal.
    /// @param projectId The ID of the project to fund.
    /// @param token The token to use.
    /// @param amount The amount to fund.
    /// @param metadata Additional metadata to include with the payment.
    function _externalAddToBalance(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        bytes memory metadata
    )
        internal
    {
        // Trigger any inherited pre-transfer logic.
        // Keep a reference to the amount that'll be paid as a `msg.value`.
        uint256 payValue = _beforeTransferTo({to: address(terminal), token: token, amount: amount});

        // Add to balance on the recipient terminal.
        // If this terminal's token is the native token, send it in `msg.value`.
        terminal.addToBalanceOf{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: metadata
        });

        // Revoke the temporary pull allowance now that the recipient terminal call has finished.
        _afterTransferTo({to: address(terminal), token: token});
    }

    /// @notice Internal implementation of payment logic. Records the payment in the store, mints project
    /// tokens via the controller, emits `Pay`, and fulfills any pay hook specifications from the data hook.
    /// @dev When `withholdFeeForSourceProjectId != 0`, `JBPayHookSpecsLib.fulfill` per-spec withholds the
    /// standard fee from each non-feeless non-noop pay-hook divert and returns the gross — the caller (an
    /// internal fee-skipped funding path: `executePayout` same-terminal pay split or
    /// `JBCashOutOpsLib.routeReclaimToBeneficiaryProject` cashout-pay routing) charges that fee against
    /// the source project. The public `pay` entrypoint passes `0` and gets the legacy pass-through (no
    /// withholding, no source-fee charge).
    /// @param projectId Destination project being paid.
    /// @param token Payment token (`JBConstants.NATIVE_TOKEN` for ETH).
    /// @param amount Payment amount (post-`_acceptFundsFor` for the public path).
    /// @param payer The payer of the inbound payment (set on the data-hook context).
    /// @param beneficiary Address receiving the resulting project-token mint.
    /// @param memo Memo string emitted in `Pay`.
    /// @param metadata Bytes forwarded to the data hook + pay hooks.
    /// @param withholdFeeForSourceProjectId Source project ID for per-spec source-fee withholding; `0`
    /// disables withholding (public-pay path).
    /// @return newlyIssuedTokenCount Project tokens minted to `beneficiary` (post-reserved-share).
    /// @return hookForwarding Hook forwarding accounting: `feeEligible` is charged to the source project,
    /// while `feeExempt` is feeless/bound but not charged.
    function _pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address payer,
        address beneficiary,
        string memory memo,
        bytes memory metadata,
        uint256 withholdFeeForSourceProjectId
    )
        internal
        returns (uint256 newlyIssuedTokenCount, PayHookForwarding memory hookForwarding)
    {
        // Keep a reference to the token amount to forward to the store.
        JBTokenAmount memory tokenAmount = _tokenAmountOf({projectId: projectId, token: token, value: amount});

        // Record + mint via a private helper so this function fits under solc 0.8.28's non-via-ir Yul
        // stack ceiling after the source-fee-withholding plumbing was added.
        JBRuleset memory ruleset;
        JBPayHookSpecification[] memory hookSpecifications;
        (ruleset, hookSpecifications, newlyIssuedTokenCount) = _recordAndMintForPay({
            projectId: projectId, tokenAmount: tokenAmount, payer: payer, beneficiary: beneficiary, metadata: metadata
        });

        _emitPayEvent({
            ruleset: ruleset,
            projectId: projectId,
            payer: payer,
            beneficiary: beneficiary,
            amount: amount,
            newlyIssuedTokenCount: newlyIssuedTokenCount,
            memo: memo,
            metadata: metadata
        });

        // Pay-hook fulfillment via the external library (DELEGATECALL preserves terminal storage). When
        // `withholdFeeForSourceProjectId != 0` the library per-spec withholds the source fee from each
        // non-feeless non-noop hook and returns the gross — caller charges that fee against the source.
        if (hookSpecifications.length != 0) {
            hookForwarding = _fulfillPayHooksViaLib({
                projectId: projectId,
                tokenAmount: tokenAmount,
                payer: payer,
                rulesetId: ruleset.id,
                rulesetWeight: ruleset.weight,
                beneficiary: beneficiary,
                newlyIssuedTokenCount: newlyIssuedTokenCount,
                metadata: metadata,
                hookSpecifications: hookSpecifications,
                withholdFeeForSourceProjectId: withholdFeeForSourceProjectId
            });
        }
    }

    /// @notice Emit the `Pay` event. Extracted into a helper so `_pay` doesn't hold the 10-arg emit
    /// setup in its stack frame alongside its many locals (solc 0.8.28 non-via-ir stack shape).
    /// @param ruleset Ruleset active during the payment (event uses `id` + `cycleNumber`).
    /// @param projectId Project being paid.
    /// @param payer Payer (event slot).
    /// @param beneficiary Beneficiary of the resulting token mint.
    /// @param amount Gross payment amount.
    /// @param newlyIssuedTokenCount Project tokens minted to `beneficiary`.
    /// @param memo Memo string.
    /// @param metadata Bytes forwarded to the data hook / pay hook.
    function _emitPayEvent(
        JBRuleset memory ruleset,
        uint256 projectId,
        address payer,
        address beneficiary,
        uint256 amount,
        uint256 newlyIssuedTokenCount,
        string memory memo,
        bytes memory metadata
    )
        private
    {
        emit Pay({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: projectId,
            payer: payer,
            beneficiary: beneficiary,
            amount: amount,
            newlyIssuedTokenCount: newlyIssuedTokenCount,
            memo: memo,
            metadata: metadata,
            caller: _msgSender()
        });
    }

    /// @notice Record the payment in the store and mint any project tokens the controller would issue.
    /// Extracted from `_pay` to keep its stack frame under solc 0.8.28's non-via-ir Yul ceiling.
    /// @param projectId Project being paid.
    /// @param tokenAmount Bundled token amount (token, value, decimals, currency).
    /// @param payer Address making the payment (forwarded into the data-hook context).
    /// @param beneficiary Address receiving the minted project tokens.
    /// @param metadata Bytes forwarded to the data hook.
    /// @return ruleset Ruleset active during the payment.
    /// @return hookSpecifications Pay hook specs returned by the data hook (may be empty).
    /// @return newlyIssuedTokenCount Project tokens actually minted to `beneficiary` (post-reserved-share).
    function _recordAndMintForPay(
        uint256 projectId,
        JBTokenAmount memory tokenAmount,
        address payer,
        address beneficiary,
        bytes memory metadata
    )
        private
        returns (
            JBRuleset memory ruleset,
            JBPayHookSpecification[] memory hookSpecifications,
            uint256 newlyIssuedTokenCount
        )
    {
        uint256 tokenCount;
        (ruleset, tokenCount, hookSpecifications) = STORE.recordPaymentFrom({
            payer: payer, amount: tokenAmount, projectId: projectId, beneficiary: beneficiary, metadata: metadata
        });
        // Token count from the store is the gross amount the project tokens would be valued at; the
        // controller's `mintTokensOf` applies the reserved-percent split and returns the beneficiary's
        // post-reserved share.
        if (tokenCount != 0) {
            newlyIssuedTokenCount = _controllerOf(projectId)
                .mintTokensOf({
                projectId: projectId,
                tokenCount: tokenCount,
                beneficiary: beneficiary,
                memo: "",
                useReservedPercent: true
            });
        }
    }

    /// @notice Build the `JBAfterPayRecordedContext` field-by-field and forward to `JBPayHookSpecsLib.fulfill`.
    /// Extracted from `_pay` to keep its stack frame under solc 0.8.28's non-via-ir Yul ceiling.
    /// @param projectId Project being paid.
    /// @param tokenAmount Bundled token amount (passed to the hook context).
    /// @param payer Payer of the inbound payment.
    /// @param rulesetId ID of the active ruleset.
    /// @param rulesetWeight Weight of the active ruleset (for the hook context).
    /// @param beneficiary Beneficiary of the resulting mint.
    /// @param newlyIssuedTokenCount Project tokens already minted to `beneficiary`.
    /// @param metadata Bytes forwarded as the data-hook payer metadata.
    /// @param hookSpecifications Pay hook specs to fulfill.
    /// @param withholdFeeForSourceProjectId Source project ID for per-spec source-fee withholding (0 = off).
    /// @return hookForwarding Hook forwarding accounting: `feeEligible` is charged to the source project,
    /// while `feeExempt` is feeless/bound but not charged.
    function _fulfillPayHooksViaLib(
        uint256 projectId,
        JBTokenAmount memory tokenAmount,
        address payer,
        uint256 rulesetId,
        uint256 rulesetWeight,
        address beneficiary,
        uint256 newlyIssuedTokenCount,
        bytes memory metadata,
        JBPayHookSpecification[] memory hookSpecifications,
        uint256 withholdFeeForSourceProjectId
    )
        private
        returns (PayHookForwarding memory hookForwarding)
    {
        JBAfterPayRecordedContext memory ctx;
        ctx.payer = payer;
        ctx.projectId = projectId;
        ctx.rulesetId = rulesetId;
        ctx.amount = tokenAmount;
        ctx.forwardedAmount = tokenAmount;
        ctx.weight = rulesetWeight;
        ctx.newlyIssuedTokenCount = newlyIssuedTokenCount;
        ctx.beneficiary = beneficiary;
        ctx.payerMetadata = metadata;
        (hookForwarding.feeEligible, hookForwarding.feeExempt) = JBPayHookSpecsLib.fulfill({
            context: ctx,
            specifications: hookSpecifications,
            feelessAddresses: FEELESS_ADDRESSES,
            withholdFeeForSourceProjectId: withholdFeeForSourceProjectId
        });
    }

    /// @notice Process a fee of the specified amount from a project.
    /// @param projectId The ID of the project paying the fee.
    /// @param token The token the fee is paid in.
    /// @param amount The fee amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address which will receive any platform tokens minted.
    /// @param feeTerminal The terminal that'll receive the fee.
    /// @param wasHeld A flag indicating if the fee to process was held by this terminal.
    function _processFee(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        IJBTerminal feeTerminal,
        bool wasHeld
    )
        internal
    {
        JBHeldFeesLib.processFee({
            store: STORE,
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            feeTerminal: feeTerminal,
            wasHeld: wasHeld
        });
    }

    /// @notice Records an added balance for a project.
    /// @param projectId The ID of the project to record the added balance for.
    /// @param token The token to record the added balance for.
    /// @param amount The amount of the token to record, as a fixed point number with the same number of decimals as
    /// this
    /// terminal.
    function _recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) internal {
        STORE.recordAddedBalanceFor({projectId: projectId, token: token, amount: amount});
    }

    /// @notice Returns held fees to the project who paid them based on the specified amount.
    /// @dev Partial replenishments use the raw floor calculation so repaying a dust amount cannot both credit the
    /// payer project and leave the fee project owed the 1-unit minimum fee.
    /// @param projectId The project to return held fees to.
    /// @param token The token that the held fees are in.
    /// @param amount The amount to base the calculation on, as a fixed point number with the same number of decimals
    /// as the token's accounting context.
    /// @return returnedFees The amount of held fees that were returned, as a fixed point number with the same number of
    /// decimals as the token's accounting context.
    function _returnHeldFees(uint256 projectId, address token, uint256 amount) internal returns (uint256 returnedFees) {
        returnedFees = JBHeldFeesLib.returnHeldFees({
            heldFeesOf: _heldFeesOf,
            nextHeldFeeIndexOf: _nextHeldFeeIndexOf,
            projectId: projectId,
            token: token,
            amount: amount
        });
    }

    /// @notice Build the `JBCashOutOpsLib.CrossProjectCashOutArgs` struct and call the library's
    /// `executeCrossProjectCashOut`. Extracted from `cashOutAndDeliver` so its stack frame stays under
    /// solc 0.8.28's non-via-ir Yul ceiling.
    /// @param holder Account whose source-project tokens are being burned.
    /// @param projectId Source project being cashed out from.
    /// @param cashOutCount Number of source-project tokens to burn.
    /// @param tokenToReclaim Terminal token reclaimed from the source surplus.
    /// @param eventBeneficiary Address recorded in the `CashOutTokens` event slot.
    /// @param cashOutMetadata Bytes forwarded to the source data hook and any cashout hook specs.
    /// @return reclaimAmount Gross reclaim returned by the source store (pre-routing).
    function _executeCrossProjectCashOutViaLib(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address eventBeneficiary,
        bytes calldata cashOutMetadata
    )
        private
        returns (uint256 reclaimAmount)
    {
        JBCashOutOpsLib.CrossProjectCashOutArgs memory cArgs;
        cArgs.holder = holder;
        cArgs.projectId = projectId;
        cArgs.cashOutCount = cashOutCount;
        cArgs.tokenToReclaim = tokenToReclaim;
        cArgs.beneficiary = eventBeneficiary;
        cArgs.cashOutMetadata = cashOutMetadata;

        reclaimAmount = JBCashOutOpsLib.executeCrossProjectCashOut({
            deps: _libDeps(), feeFreeSurplusOf: _feeFreeSurplusOf, heldFeesOf: _heldFeesOf, args: cArgs
        });
    }

    /// @notice Sends payouts to a project's payout split group using the specified ruleset.
    /// @param projectId The ID of the project to send the payouts of.
    /// @param token The token to pay out.
    /// @param amount The number of terminal tokens to pay out, as a fixed point number with the same number of decimals
    /// as the token's accounting context.
    /// @param currency The expected currency of the amount to pay out. Must match the currency of one of the
    /// project's current ruleset's payout limits.
    /// @return amountPaidOut The total amount that was paid out.
    function _sendPayoutsOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency
    )
        internal
        returns (uint256 amountPaidOut)
    {
        // Cache the message sender.
        address sender = _msgSender();

        // Keep a reference to the ruleset.
        JBRuleset memory ruleset;

        // Record the payout.
        (ruleset, amountPaidOut) =
            STORE.recordPayoutFor({projectId: projectId, token: token, amount: amount, currency: currency});

        // If nothing to pay out (e.g. payout limit already used or not configured), return early.
        if (amountPaidOut == 0) return amountPaidOut;

        // Get a reference to the project's owner.
        // The owner will receive tokens minted by paying the platform fee and receive any leftover funds not sent to
        // payout splits.
        address payable projectOwner = payable(_ownerOf(projectId));

        // If the ruleset requires privileged payout distribution, ensure the caller has the permission.
        if (ruleset.ownerMustSendPayouts()) {
            // Enforce permissions.
            _requirePermissionFrom({
                account: projectOwner, projectId: projectId, permissionId: JBPermissionIds.SEND_PAYOUTS
            });
        }

        // Send payouts to the splits and get a reference to the amount left over after the splits have been paid.
        // Also get a reference to the amount which was paid out to splits that is eligible for fees.
        (uint256 leftoverPayoutAmount, uint256 amountEligibleForFees) = JBPayoutSplitGroupLib.sendPayoutsToSplitGroupOf({
            splits: SPLITS,
            store: STORE,
            projectId: projectId,
            token: token,
            rulesetId: ruleset.id,
            amount: amountPaidOut,
            caller: sender
        });

        // Send any leftover funds to the project owner and update the fee tracking accordingly.
        if (leftoverPayoutAmount != 0) {
            // Keep a reference to the fee for the leftover payout amount.
            uint256 fee =
                _isFeeless({addr: projectOwner, projectId: projectId}) ? 0 : _feeAmountFrom(leftoverPayoutAmount);

            uint256 netLeftoverPayoutAmount;
            unchecked {
                netLeftoverPayoutAmount = leftoverPayoutAmount - fee;
            }

            // Failed owner transfer consumes the payout limit by design. Same pattern as split payouts:
            // the try-catch prevents revert, failed amount is returned to project balance, and the owner can retry
            // via addToBalanceOf or in the next cycle.
            try this.executeTransferTo({addr: projectOwner, token: token, amount: netLeftoverPayoutAmount}) {
                if (fee > 0) {
                    amountEligibleForFees += leftoverPayoutAmount;
                    leftoverPayoutAmount = netLeftoverPayoutAmount;
                }
            } catch (bytes memory reason) {
                emit PayoutTransferReverted({
                    projectId: projectId,
                    addr: projectOwner,
                    token: token,
                    amount: netLeftoverPayoutAmount,
                    fee: fee,
                    reason: reason,
                    caller: sender
                });

                // Add balance back to the project.
                _recordAddedBalanceFor({projectId: projectId, token: token, amount: leftoverPayoutAmount});
            }
        }

        // Cap fee-free surplus at remaining balance. Non-fee-free funds leave first.
        // Placed after all payouts settle so the cap reflects post-payout state.
        _capFeeFreeSurplus({projectId: projectId, token: token});

        // Take the fee.
        uint256 feeTaken = _takeFeeFrom({
            projectId: projectId,
            token: token,
            amount: amountEligibleForFees,
            beneficiary: projectOwner,
            shouldHoldFees: ruleset.holdFees()
        });

        emit SendPayouts({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: projectId,
            projectOwner: projectOwner,
            amount: amount,
            amountPaidOut: amountPaidOut,
            fee: feeTaken,
            netLeftoverPayoutAmount: leftoverPayoutAmount,
            caller: sender
        });
    }

    /// @notice Takes a fee into the platform's project (with the `JBConstants.FEE_BENEFICIARY_PROJECT_ID`).
    /// @param projectId The ID of the project paying the fee.
    /// @param token The address of the token that the fee is paid in.
    /// @param amount The fee's token amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address to mint the platform's project's tokens for.
    /// @param shouldHoldFees If fees should be tracked and held instead of processing them immediately.
    /// @return feeAmount The amount of the fee taken.
    function _takeFeeFrom(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bool shouldHoldFees
    )
        internal
        returns (uint256 feeAmount)
    {
        // Get a reference to the fee amount.
        feeAmount = _feeAmountFrom(amount);

        if (shouldHoldFees) {
            // Store the held fee.
            _heldFeesOf[projectId][token].push(
                JBFee({
                    amount: amount,
                    beneficiary: beneficiary,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    unlockTimestamp: uint48(block.timestamp + _FEE_HOLDING_SECONDS)
                })
            );

            emit HoldFee({
                projectId: projectId,
                token: token,
                amount: amount,
                fee: JBConstants.FEE,
                beneficiary: beneficiary,
                caller: _msgSender()
            });
        } else {
            // Get the terminal that'll receive the fee if one wasn't provided.
            IJBTerminal feeTerminal =
                _primaryTerminalOf({projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID, token: token});

            // Process the fee.
            _processFee({
                projectId: projectId,
                token: token,
                amount: feeAmount,
                beneficiary: beneficiary,
                feeTerminal: feeTerminal,
                wasHeld: false
            });
        }
    }

    /// @notice Transfers tokens.
    /// @param from The address the transfer should originate from.
    /// @param to The address the transfer should go to.
    /// @param token The token to transfer.
    /// @param amount The number of tokens to transfer, as a fixed point number with the same number of decimals
    /// as this terminal.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal {
        if (from == address(this)) {
            // If the token is the native token, transfer natively.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue({recipient: to, amount: amount});

            return IERC20(token).safeTransfer({to: to, value: amount});
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance({owner: address(from), spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom({from: from, to: to, value: amount});
        }

        // Make sure the amount being paid is less than the maximum permit2 allowance.
        if (amount > type(uint160).max) revert JBMultiTerminal_OverflowAlert(amount, type(uint160).max);

        // Otherwise we attempt to use the PERMIT2 method.
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }

    /// @notice Allows a project to send out funds from its surplus up to the current surplus allowance.
    function _useAllowanceOf(
        uint256 projectId,
        address owner,
        address token,
        uint256 amount,
        uint256 currency,
        address payable beneficiary,
        address payable feeBeneficiary,
        string memory memo
    )
        internal
        returns (uint256 netAmountPaidOut)
    {
        JBRuleset memory ruleset;
        uint256 amountPaidOut;
        (ruleset, amountPaidOut) =
            STORE.recordUsedAllowanceOf({projectId: projectId, token: token, amount: amount, currency: currency});

        _capFeeFreeSurplus({projectId: projectId, token: token});

        netAmountPaidOut = amountPaidOut
            - (_isFeeless({addr: owner, projectId: projectId}) || _isFeeless({addr: beneficiary, projectId: projectId})
                    ? 0
                    : _takeFeeFrom({
                        projectId: projectId,
                        token: token,
                        amount: amountPaidOut,
                        beneficiary: feeBeneficiary,
                        shouldHoldFees: ruleset.holdFees()
                    }));

        emit UseAllowance({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: projectId,
            beneficiary: beneficiary,
            feeBeneficiary: feeBeneficiary,
            amount: amount,
            amountPaidOut: amountPaidOut,
            netAmountPaidOut: netAmountPaidOut,
            memo: memo,
            caller: _msgSender()
        });

        if (netAmountPaidOut != 0) {
            _transferFrom({from: address(this), to: beneficiary, token: token, amount: netAmountPaidOut});
        }
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Logic to be triggered after transferring tokens from this terminal.
    /// @dev Clears any allowance granted by `_beforeTransferTo` so receivers cannot retain pull access after the call.
    /// @param to The address whose temporary pull allowance should be cleared.
    /// @param token The token whose temporary allowance should be cleared.
    function _afterTransferTo(address to, address token) internal view {
        // Native-token transfers use `msg.value`, so there is no ERC-20 approval to clear.
        if (token == JBConstants.NATIVE_TOKEN) return;

        // Revert if the callee returned without consuming the full forwarded ERC-20 amount.
        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: to});
        if (allowance != 0) revert JBMultiTerminal_TemporaryAllowanceNotConsumed(token, to, allowance);
    }

    /// @notice Returns a project's accounting context for a token, reverting if it is not accepted.
    /// @param projectId The ID of the project to get the accounting context for.
    /// @param token The token to get the accounting context for.
    /// @return context The project's accounting context for the token.
    function _accountingContextOf(
        uint256 projectId,
        address token
    )
        internal
        view
        returns (JBAccountingContext memory context)
    {
        // Keep a reference to the accounting context configured for the token.
        context = STORE.accountingContextOf({terminal: address(this), projectId: projectId, token: token});

        // Revert if the token is not accepted by the project.
        if (context.token == address(0)) revert JBMultiTerminal_TokenNotAccepted(token);
    }

    /// @notice Checks this terminal's balance of a specific token.
    /// @param token The address of the token to get this terminal's balance of.
    /// @return This terminal's balance.
    function _balanceOf(address token) internal view returns (uint256) {
        // If the `token` is native, get the native token balance.
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice Build the `JBCashOutOpsLib.Deps` bundle from this terminal's immutables.
    /// @dev Centralizing this construction in one helper saved ~450 bytes vs. duplicating it at every
    /// call site (immutables aren't visible to external library code under DELEGATECALL, so every lib
    /// callsite has to pass them in). The repeated assignments at each callsite each cost ~30-40 bytes
    /// in dispatch and arg encoding; one helper amortizes that.
    /// @return deps The dependency bundle expected by every external function on `JBCashOutOpsLib`.
    function _libDeps() internal view returns (JBCashOutOpsLib.Deps memory deps) {
        deps.store = STORE;
        deps.directory = DIRECTORY;
        deps.feelessAddresses = FEELESS_ADDRESSES;
        deps.projects = PROJECTS;
    }

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Returns the current controller of a project.
    /// @param projectId The ID of the project to get the controller of.
    /// @return controller The project's controller.
    function _controllerOf(uint256 projectId) internal view returns (IJBController) {
        return IJBController(address(DIRECTORY.controllerOf(projectId)));
    }

    /// @notice Returns a flag indicating if interacting with an address should not incur fees.
    /// @param addr The address to check.
    /// @param projectId The ID of the project to check the per-project feeless status for.
    /// @return A flag indicating if the address should not incur fees (globally or for the project).
    function _isFeeless(address addr, uint256 projectId) internal view returns (bool) {
        return FEELESS_ADDRESSES.isFeelessFor({addr: addr, projectId: projectId});
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice The owner of a project.
    /// @param projectId The ID of the project to get the owner of.
    /// @return The owner of the project.
    function _ownerOf(uint256 projectId) internal view returns (address) {
        return PROJECTS.ownerOf(projectId);
    }

    /// @notice The primary terminal of a project for a token.
    /// @param projectId The ID of the project to get the primary terminal of.
    /// @param token The token to get the primary terminal of.
    /// @return The primary terminal of the project for the token.
    function _primaryTerminalOf(uint256 projectId, address token) internal view returns (IJBTerminal) {
        return DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});
    }

    /// @notice Revert if the destination project's current ruleset has opted out of cross-project fee-free
    /// inflows (`pauseCrossProjectFeeFreeInflows == true`). Shared by `payAfterCashOutTokensOf` and
    /// `addToBalanceAfterCashOutTokensOf`.
    function _requireBeneficiaryAcceptsFeeFreeInflows(uint256 beneficiaryProjectId) internal view {
        (, JBRulesetMetadata memory bMetadata) =
            _controllerOf(beneficiaryProjectId).currentRulesetOf(beneficiaryProjectId);
        if (bMetadata.pauseCrossProjectFeeFreeInflows) {
            revert JBMultiTerminal_BeneficiaryProjectFeeFreeInflowsPaused(beneficiaryProjectId);
        }
    }

    /// @notice Require the caller to have `CASH_OUT_TOKENS` permission for `holder` on `projectId`. Shared by
    /// `cashOutTokensOf`, `payAfterCashOutTokensOf`, and `addToBalanceAfterCashOutTokensOf`.
    function _requireCashOutPermissionFrom(address holder, uint256 projectId) internal view {
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.CASH_OUT_TOKENS});
    }

    /// @notice Packages a payment amount with the token's accounting context.
    /// @param projectId The ID of the project the token amount belongs to.
    /// @param token The token to pay with.
    /// @param value The token amount's value.
    /// @return tokenAmount The packaged token amount.
    function _tokenAmountOf(
        uint256 projectId,
        address token,
        uint256 value
    )
        internal
        view
        returns (JBTokenAmount memory tokenAmount)
    {
        // Keep a reference to the token's accounting context.
        JBAccountingContext memory context = _accountingContextOf({projectId: projectId, token: token});

        // Bundle the amount info into a `JBTokenAmount` struct.
        tokenAmount =
            JBTokenAmount({token: token, decimals: context.decimals, currency: context.currency, value: value});
    }

    //*********************************************************************//
    // -------------------------- private helpers ------------------------ //
    //*********************************************************************//

    /// @notice The terminal fee charged from a pre-fee `amount`.
    /// @param amount The amount before the fee is applied.
    /// @return The fee amount.
    function _feeAmountFrom(uint256 amount) private pure returns (uint256) {
        return JBFees.standardFeeAmountFrom(amount);
    }
}
