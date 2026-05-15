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
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBFees} from "./libraries/JBFees.sol";
import {JBHeldFeesLib} from "./libraries/JBHeldFeesLib.sol";
import {JBMetadataResolver} from "./libraries/JBMetadataResolver.sol";
import {JBPayoutSplitGroupLib} from "./libraries/JBPayoutSplitGroupLib.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "./structs/JBAfterPayRecordedContext.sol";
import {JBAfterCashOutRecordedContext} from "./structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "./structs/JBCashOutHookSpecification.sol";
import {JBCashOutToProjectContext} from "./structs/JBCashOutToProjectContext.sol";
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

    error JBMultiTerminal_BeneficiaryProjectDoesNotAllowFeeFreeInflows(uint256 projectId);
    error JBMultiTerminal_BeneficiaryProjectTokenNotSpecified();
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
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice This terminal's fee (as a fraction out of `JBConstants.MAX_FEE`).
    /// @dev Fees are charged on payouts to addresses and surplus allowance usage, as well as cash outs while the
    /// cash out tax rate is less than 100%.
    uint256 public constant override FEE = 25; // 2.5%

    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice Project ID #1 receives fees. It should be the first project launched during the deployment process.
    uint256 internal constant _FEE_BENEFICIARY_PROJECT_ID = 1;

    /// @notice The number of seconds fees can be held for.
    uint256 internal constant _FEE_HOLDING_SECONDS = 2_419_200; // 28 days

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

    /// @notice Burn `holder`'s project tokens, route the reclaim into `beneficiaryProjectId` via a declared
    /// destination terminal, and credit `_feeFreeSurplusOf[B]` by the actual `STORE.balanceOf` delta that lands
    /// back on this terminal under B's name. Source-side cashout fee is skipped; round-trip prevention is
    /// enforced by the delivery proof and slippage check.
    /// @dev Same-terminal (`destinationTerminal == this`), router-with-swap (router pays B with a different
    /// token on this terminal), or any composition that ends with B's `STORE.balanceOf` on this terminal
    /// increasing is supported. If less than `routing.minDeliveredToB` physically lands back, the entire call
    /// reverts — no fee leak vector exists because the cashout itself is unwound.
    /// @dev `B`'s current ruleset must have `allowCrossProjectFeeFreeInflows` set, otherwise the call reverts.
    /// This protects B's holders from having other projects' deferred cashout fees attached to B's
    /// `_feeFreeSurplusOf` without explicit consent.
    /// @param holder The account whose project tokens are being burned.
    /// @param projectId The ID of the source project being cashed out from.
    /// @param cashOutCount The number of source-project tokens to burn, as a fixed point number with 18 decimals.
    /// @param tokenToReclaim The terminal token reclaimed from the source project's surplus.
    /// @param beneficiaryProjectId The destination project receiving the reclaim.
    /// @param beneficiary The address that receives the newly minted destination-project tokens.
    /// @param minTokensOut The minimum number of destination-project tokens that must be minted, otherwise revert.
    /// @param cashOutMetadata Bytes forwarded to the source project's data hook and any cashout hook specifications.
    /// @param payMetadata Bytes forwarded to the destination project's pay flow.
    /// @param routing Where to send the reclaim, what token to expect back at B, and the minimum delivery floor.
    /// @return reclaimAmount The gross reclaim amount returned by the store before being sent to the destination
    /// terminal. @return beneficiaryTokenCount The number of destination-project tokens minted to `beneficiary`.
    /// @return deliveredToB The actual `STORE.balanceOf` delta on `(this, beneficiaryProjectId,
    /// routing.tokenForBeneficiaryProject)` after the routing — i.e. how much landed back on this terminal
    /// under B's name.
    function cashOutAsPaymentToProjectOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 beneficiaryProjectId,
        address beneficiary,
        uint256 minTokensOut,
        bytes calldata cashOutMetadata,
        bytes calldata payMetadata,
        JBCashOutToProjectContext calldata routing
    )
        external
        override
        returns (uint256 reclaimAmount, uint256 beneficiaryTokenCount, uint256 deliveredToB)
    {
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.CASH_OUT_TOKENS});

        // The caller must declare which token they expect to land back at B on this terminal — the bucket
        // the delivery delta is measured against, and the slot `_feeFreeSurplusOf` is credited into.
        if (routing.tokenForBeneficiaryProject == address(0)) {
            revert JBMultiTerminal_BeneficiaryProjectTokenNotSpecified();
        }

        // Require B's current ruleset to opt in. Without this gate, any A token holder could attach A's
        // deferred cashout fee to B's `_feeFreeSurplusOf`, externalizing the fee burden onto B's other
        // holders at B's next zero-tax cashout.
        {
            (, JBRulesetMetadata memory bMetadata) =
                _controllerOf(beneficiaryProjectId).currentRulesetOf(beneficiaryProjectId);
            if (!bMetadata.allowCrossProjectFeeFreeInflows) {
                revert JBMultiTerminal_BeneficiaryProjectDoesNotAllowFeeFreeInflows(beneficiaryProjectId);
            }
        }

        // Burn A's tokens, run cashout-side hooks, route the reclaim, and credit B's fee-free surplus.
        (reclaimAmount, beneficiaryTokenCount, deliveredToB) = _cashOutAsPaymentToProject({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryProjectId: beneficiaryProjectId,
            beneficiary: beneficiary,
            cashOutMetadata: cashOutMetadata,
            payMetadata: payMetadata,
            routing: routing
        });

        // Delivery floor: how much physically landed back at B on this terminal. Protects against a
        // misrouting destination terminal — if this fails, the burn is also unwound.
        _checkMin({value: deliveredToB, min: routing.minDeliveredToB});

        // Mint floor: how many destination-project tokens were issued for the inbound pay. Independent
        // from delivery because B's data hook can affect the mint ratio.
        _checkMin({value: beneficiaryTokenCount, min: minTokensOut});
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
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.CASH_OUT_TOKENS});

        reclaimAmount = _cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiary: beneficiary,
            metadata: metadata
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

            // Fees apply to fund egress, not intra-terminal accounting. When both projects share this terminal,
            // funds stay within the contract (addToBalance or pay) so no fee is charged. This is intentional:
            // the fee model taxes value leaving the protocol ecosystem, not internal rebalancing.
            // This payout is eligible for a fee if the funds are leaving this contract and the receiving terminal isn't
            // a feeless address.
            if (terminal != this && !_isFeeless({addr: address(terminal), projectId: projectId})) {
                unchecked {
                    netPayoutAmount -= _feeAmountFrom(amount);
                }
                feeEligibleAmount = amount;
            }

            // Track the fee-free payout amount. During cashout at zero tax rate, fees apply
            // only up to this accumulated amount, preventing round-trip fee bypass.
            if (terminal == this) {
                _feeFreeSurplusOf[split.projectId][token] += netPayoutAmount;
            }

            // Send the `projectId` in the metadata as a referral.
            bytes memory metadata = bytes(abi.encodePacked(projectId));

            // Add to balance if preferred.
            if (split.preferAddToBalance) {
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

                // Keep a reference to the beneficiary of the payment.
                address beneficiary = split.beneficiary != address(0) ? split.beneficiary : originalMessageSender;

                _efficientPay({
                    terminal: terminal,
                    projectId: split.projectId,
                    token: token,
                    amount: netPayoutAmount,
                    beneficiary: beneficiary,
                    metadata: metadata
                });

                // Cap fee-free surplus at remaining balance.
                // Why: _feeFreeSurplusOf was incremented by the full netPayoutAmount above, but if the
                // destination project's data hook forwarded part of the payment to pay hooks, the store
                // only recorded a partial balance increase. Without this cap, _feeFreeSurplusOf can exceed
                // STORE.balanceOf, causing users to be overcharged fees on zero-tax cashouts.
                _capFeeFreeSurplus({projectId: split.projectId, token: token});
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
            projectId: _FEE_BENEFICIARY_PROJECT_ID,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata
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

        // The terminal being migrated to must accept the same token as this terminal.
        if (to.accountingContextForTokenOf({projectId: projectId, token: token}).currency == 0) {
            revert JBMultiTerminal_TerminalTokensIncompatible({projectId: projectId, token: token, terminal: to});
        }

        // Clear fee-free surplus tracking — the fee-free liability is settled by the migration fee below.
        delete _feeFreeSurplusOf[projectId][token];

        // Terminal migration intentionally does not transfer held fees. Held fees belong to the
        // fee beneficiary (project #1), not the migrating project. They unlock after 28 days regardless of terminal.
        // After migration, `processHeldFeesOf()` on this terminal still works — it reads from `_heldFeesOf` and
        // sends fees to the fee project terminal. The migrated project's balance on this terminal is zero, but held
        // fees are backed by the terminal's own token balance (not the project's recorded balance).
        // Record the migration in the store.
        balance = STORE.recordTerminalMigration({projectId: projectId, token: token});

        emit MigrateTerminal({projectId: projectId, token: token, to: to, amount: balance, caller: _msgSender()});

        // Transfer the balance if needed.
        if (balance != 0) {
            // Migration to a non-feeless terminal incurs the standard 2.5% fee, same as any other fund egress.
            // This also settles any fee-free surplus liability that would otherwise be lost on the new terminal.
            uint256 feeAmount;
            if (!_isFeeless({addr: address(to), projectId: projectId}) && projectId != _FEE_BENEFICIARY_PROJECT_ID) {
                feeAmount = _takeFeeFrom({
                    projectId: projectId,
                    token: token,
                    amount: balance,
                    beneficiary: payable(_ownerOf(projectId)),
                    shouldHoldFees: false
                });
            }

            // Transfer the balance minus the fee to the new terminal.
            uint256 migrationAmount = balance - feeAmount;

            _externalAddToBalance({
                terminal: to, projectId: projectId, token: token, amount: migrationAmount, metadata: bytes("")
            });
        }
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

        // Pay the project.
        _pay({
            projectId: projectId,
            token: token,
            amount: acceptedAmount,
            payer: _msgSender(),
            beneficiary: beneficiary,
            memo: memo,
            metadata: metadata
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

    /// @notice Cashout from project A and route the reclaim into project B via a declared destination
    /// terminal, in a single atomic step.
    /// @dev Source-side cashout fee is skipped. The equivalent fee is bound on B's side by crediting
    /// `_feeFreeSurplusOf[B][routing.tokenForBeneficiaryProject]` with the `STORE.balanceOf` delta measured
    /// after the routing — i.e. exactly what physically landed back on this terminal under B's name. The
    /// external entrypoint reverts if delivery falls below `routing.minDeliveredToB`, so the skipped
    /// source-side fee can never become a leak.
    /// @dev Cashout-side hook specifications run additively. Hook fees on A's side are still collected via
    /// `_takeFeeFrom`; only the beneficiary portion is feeless and routed.
    /// @param holder The account whose source-project tokens are being burned.
    /// @param projectId The ID of the source project being cashed out from.
    /// @param cashOutCount The number of source-project tokens to burn.
    /// @param tokenToReclaim The terminal token reclaimed from the source project's surplus.
    /// @param beneficiaryProjectId The destination project receiving the reclaim.
    /// @param beneficiary The address that receives the newly minted destination-project tokens.
    /// @param cashOutMetadata Bytes forwarded to the source project's data hook and any cashout hook specs.
    /// @param payMetadata Bytes forwarded to the destination project's pay flow.
    /// @param routing Where to send the reclaim, what token to expect back at B, the minimum delivery floor.
    /// @return reclaimAmount The gross reclaim amount returned by the store.
    /// @return beneficiaryTokenCount The number of destination-project tokens minted to `beneficiary`.
    /// @return deliveredToB The `STORE.balanceOf` delta on `(this, beneficiaryProjectId,
    /// routing.tokenForBeneficiaryProject)` — what landed back on this terminal under B's name. Becomes the
    /// `_feeFreeSurplusOf[B]` credit.
    function _cashOutAsPaymentToProject(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 beneficiaryProjectId,
        address beneficiary,
        bytes memory cashOutMetadata,
        bytes memory payMetadata,
        JBCashOutToProjectContext memory routing
    )
        internal
        returns (uint256 reclaimAmount, uint256 beneficiaryTokenCount, uint256 deliveredToB)
    {
        // Keep a reference to the ruleset the cash out is being made during.
        JBRuleset memory ruleset;

        // Keep a reference to the cash out tax rate being used.
        uint256 cashOutTaxRate;

        // Keep a reference to the cash out hook specifications.
        JBCashOutHookSpecification[] memory hookSpecifications;

        // Record the cash out and burn the project tokens.
        // The store sees `beneficiaryIsFeeless: true` — the equivalent fee is bound on B's side via the
        // `_feeFreeSurplusOf[B]` credit computed from the delivery delta below. The external entrypoint
        // reverts the entire call if delivery falls short, so this can never become a leak.
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = _recordAndBurnCashOut({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: true,
            metadata: cashOutMetadata
        });

        emit CashOutTokens({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: projectId,
            holder: holder,
            beneficiary: beneficiary,
            cashOutCount: cashOutCount,
            cashOutTaxRate: cashOutTaxRate,
            reclaimAmount: reclaimAmount,
            metadata: cashOutMetadata,
            caller: _msgSender()
        });

        // Keep a reference to the amount being reclaimed that is subject to fees.
        // Only hook-spec amounts are fee-eligible here; the beneficiary portion is intentionally feeless.
        uint256 amountEligibleForFees;

        // If the data hook returned cash out hook specifications, fulfill them.
        // Hook fees still apply (those funds leave the protocol to external hooks). Hook context sees
        // `address(this)` as the beneficiary since the terminal is custodying the reclaim mid-flow.
        if (hookSpecifications.length != 0) {
            amountEligibleForFees = _fulfillCashOutHookSpecificationsFor({
                projectId: projectId,
                beneficiaryReclaimAmount: _tokenAmountOf({
                    projectId: projectId, token: tokenToReclaim, value: reclaimAmount
                }),
                holder: holder,
                cashOutCount: cashOutCount,
                metadata: cashOutMetadata,
                ruleset: ruleset,
                cashOutTaxRate: cashOutTaxRate,
                beneficiary: payable(address(this)),
                specifications: hookSpecifications
            });
        }

        // Cap A's fee-free surplus at remaining balance after the outflow.
        // Same invariant as `_cashOutTokensOf`: every cashout path keeps `_feeFreeSurplusOf[A]` consistent
        // with the post-outflow balance so later zero-tax cashouts from A don't fee phantom amounts.
        _capFeeFreeSurplus({projectId: projectId, token: tokenToReclaim});

        // Take the fee on the hook amounts.
        if (amountEligibleForFees != 0) {
            _takeFeeFrom({
                projectId: projectId,
                token: tokenToReclaim,
                amount: amountEligibleForFees,
                beneficiary: beneficiary,
                shouldHoldFees: false
            });
        }

        // Nothing to route if the data hook returned zero reclaim — `deliveredToB` stays at zero, which the
        // external entrypoint compares against `minDeliveredToB`.
        if (reclaimAmount == 0) return (0, 0, 0);

        // Route the reclaim into B and measure delivery. Split off into a helper to keep this function under
        // the via-IR stack-too-deep ceiling.
        (beneficiaryTokenCount, deliveredToB) = _routeReclaimToBeneficiaryProject({
            tokenToReclaim: tokenToReclaim,
            reclaimAmount: reclaimAmount,
            beneficiaryProjectId: beneficiaryProjectId,
            beneficiary: beneficiary,
            payMetadata: payMetadata,
            routing: routing
        });
    }

    /// @notice Holders can cash out their tokens to reclaim some of a project's surplus, or to trigger rules determined
    /// by
    /// the project's current ruleset's data hook.
    /// @dev Only a token holder or an operator with the `CASH_OUT_TOKENS` permission from that holder can cash out
    /// those
    /// tokens.
    /// @param holder The account cashing out tokens.
    /// @param projectId The ID of the project cashing out tokens.
    /// @param cashOutCount The number of project tokens to cash out, as a fixed point number with 18 decimals.
    /// @param tokenToReclaim The address of the token to reclaim.
    /// @param beneficiary The address to send the reclaimed terminal tokens to.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and cash out hook if
    /// applicable.
    /// @return reclaimAmount The number of terminal tokens reclaimed for the `beneficiary`, as a fixed point number
    /// with 18 decimals.
    function _cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable beneficiary,
        bytes memory metadata
    )
        internal
        returns (uint256 reclaimAmount)
    {
        // Keep a reference to the ruleset the cash out is being made during.
        JBRuleset memory ruleset;

        // Keep a reference to the cash out hook specifications.
        JBCashOutHookSpecification[] memory hookSpecifications;

        // Keep a reference to the cash out tax rate being used.
        uint256 cashOutTaxRate;

        // Cache whether the beneficiary is feeless.
        bool beneficiaryIsFeeless = _isFeeless({addr: beneficiary, projectId: projectId});

        // Record the cash out and burn the project tokens.
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = _recordAndBurnCashOut({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });

        // Keep a reference to the amount being reclaimed that is subject to fees.
        uint256 amountEligibleForFees;

        // Send the reclaimed funds to the beneficiary.
        if (reclaimAmount != 0) {
            // Determine if a fee should be taken. Fees are not taken if the beneficiary is feeless.
            if (!beneficiaryIsFeeless) {
                if (cashOutTaxRate != 0) {
                    // Non-zero tax: fees apply to the full reclaim amount.
                    amountEligibleForFees += reclaimAmount;
                    unchecked {
                        reclaimAmount -= _feeAmountFrom(reclaimAmount);
                    }
                } else {
                    // Zero tax: fees apply only up to the fee-free surplus (round-trip prevention).
                    uint256 feeFreeSurplus = _feeFreeSurplusOf[projectId][tokenToReclaim];
                    if (feeFreeSurplus != 0) {
                        uint256 feeableAmount = reclaimAmount < feeFreeSurplus ? reclaimAmount : feeFreeSurplus;
                        unchecked {
                            _feeFreeSurplusOf[projectId][tokenToReclaim] = feeFreeSurplus - feeableAmount;
                        }
                        amountEligibleForFees += feeableAmount;
                        unchecked {
                            reclaimAmount -= _feeAmountFrom(feeableAmount);
                        }
                    }
                }
            }

            // Subtract the fee from the reclaim amount.
            if (reclaimAmount != 0) {
                _transferFrom({from: address(this), to: beneficiary, token: tokenToReclaim, amount: reclaimAmount});
            }
        }

        // If the data hook returned cash out hook specifications, fulfill them.
        if (hookSpecifications.length != 0) {
            // Fulfill the cash out hook specifications.
            amountEligibleForFees += _fulfillCashOutHookSpecificationsFor({
                projectId: projectId,
                holder: holder,
                cashOutCount: cashOutCount,
                ruleset: ruleset,
                cashOutTaxRate: cashOutTaxRate,
                beneficiary: beneficiary,
                beneficiaryReclaimAmount: _tokenAmountOf({
                    projectId: projectId, token: tokenToReclaim, value: reclaimAmount
                }),
                specifications: hookSpecifications,
                metadata: metadata
            });
        }

        // Cap fee-free surplus at remaining balance.
        // Why: this single call replaces per-branch calls so that EVERY cashout path (non-zero tax,
        // zero tax, and feeless beneficiary) gets the cap. Without it, the zero-tax path would use
        // a stale _feeFreeSurplusOf that may exceed STORE.balanceOf (e.g. if pay hooks reduced the
        // balance during a prior inbound payout), overcharging fees on round-trip prevention.
        // Placed after hook fulfillment so any further balance reductions from cashout hooks are
        // also accounted for.
        _capFeeFreeSurplus({projectId: projectId, token: tokenToReclaim});

        // Take the fee from all outbound reclaimings.
        if (amountEligibleForFees != 0) {
            _takeFeeFrom({
                projectId: projectId,
                token: tokenToReclaim,
                amount: amountEligibleForFees,
                beneficiary: beneficiary,
                shouldHoldFees: false
            });
        }

        emit CashOutTokens({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: projectId,
            holder: holder,
            beneficiary: beneficiary,
            cashOutCount: cashOutCount,
            cashOutTaxRate: cashOutTaxRate,
            reclaimAmount: reclaimAmount,
            metadata: metadata,
            caller: _msgSender()
        });
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

    /// @notice Pay a project either by calling this terminal's internal `pay` function or by calling the recipient
    /// terminal's `pay` function.
    /// @param terminal The terminal on which the project is expecting to receive payments.
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with.
    /// @param amount The amount to pay, as a fixed point number with the amount of decimals that the terminal's
    /// accounting context specifies.
    /// @param beneficiary The address to receive any platform tokens minted.
    /// @param metadata Additional metadata to include with the payment.
    function _efficientPay(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes memory metadata
    )
        internal
    {
        if (terminal == IJBTerminal(address(this))) {
            _pay({
                projectId: projectId,
                token: token,
                amount: amount,
                payer: address(this),
                beneficiary: beneficiary,
                memo: "",
                metadata: metadata
            });
        } else {
            // Trigger any inherited pre-transfer logic.
            // Keep a reference to the amount that'll be paid as a `msg.value`.
            uint256 payValue = _beforeTransferTo({to: address(terminal), token: token, amount: amount});

            // Send the fee.
            // If this terminal's token is ETH, send it in msg.value.
            terminal.pay{value: payValue}({
                projectId: projectId,
                token: token,
                amount: amount,
                beneficiary: beneficiary,
                minReturnedTokens: 0,
                memo: "",
                metadata: metadata
            });

            // Revoke the temporary pull allowance now that the recipient terminal call has finished.
            _afterTransferTo({to: address(terminal), token: token});
        }
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

    /// @notice Fulfills a list of cash out hook specifications.
    /// @param projectId The ID of the project to cash out from.
    /// @param beneficiaryReclaimAmount The number of tokens to cash out from the project.
    /// @param holder The address holding the tokens to cash out.
    /// @param cashOutCount The number of tokens to cash out.
    /// @param metadata Bytes to send along to the emitted event and cash out hooks as applicable.
    /// @param ruleset The ruleset active during this cash out as a `JBRuleset` struct.
    /// @param cashOutTaxRate The cash out tax rate influencing the reclaim amount, out of
    /// `JBConstants.MAX_CASH_OUT_TAX_RATE`. @param beneficiary The address which will receive any terminal tokens that
    /// are cashed out.
    /// @param specifications The hook specifications to fulfill.
    /// @return amountEligibleForFees The amount of funds which were allocated to cash out hooks and are eligible for
    /// fees.
    function _fulfillCashOutHookSpecificationsFor(
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
        internal
        returns (uint256 amountEligibleForFees)
    {
        // Keep a reference to cash out context for the cash out hooks.
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
            // Set the specification being iterated on.
            JBCashOutHookSpecification memory specification = specifications[i];

            // A noop specification is informational only and doesn't trigger the hook.
            if (specification.noop) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Get the fee for the specified amount.
            uint256 specificationAmountFee = _isFeeless({addr: address(specification.hook), projectId: projectId})
                ? 0
                : _feeAmountFrom(specification.amount);

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
                caller: _msgSender()
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Fulfills a list of pay hook specifications.
    /// @param projectId The ID of the project to pay.
    /// @param specifications The pay hook specifications to be fulfilled.
    /// @param tokenAmount The amount of tokens that the project was paid.
    /// @param payer The address that sent the payment.
    /// @param ruleset The ruleset active during this payment.
    /// @param beneficiary The address which will receive any tokens that the payment yields.
    /// @param newlyIssuedTokenCount The number of tokens issued and sent to the beneficiary.
    /// @param metadata Bytes to send along to the emitted event and pay hooks as applicable.
    function _fulfillPayHookSpecificationsFor(
        uint256 projectId,
        JBPayHookSpecification[] memory specifications,
        JBTokenAmount memory tokenAmount,
        address payer,
        JBRuleset memory ruleset,
        address beneficiary,
        uint256 newlyIssuedTokenCount,
        bytes memory metadata
    )
        internal
    {
        // Keep a reference to payment context for the pay hooks.
        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: ruleset.id,
            amount: tokenAmount,
            forwardedAmount: tokenAmount,
            weight: ruleset.weight,
            newlyIssuedTokenCount: newlyIssuedTokenCount,
            beneficiary: beneficiary,
            hookMetadata: bytes(""),
            payerMetadata: metadata
        });

        // Fulfill each specification through their pay hooks.
        for (uint256 i; i < specifications.length;) {
            // Set the specification being iterated on.
            JBPayHookSpecification memory specification = specifications[i];

            // A noop specification is informational only and doesn't trigger the hook.
            if (specification.noop) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Pass the correct token `forwardedAmount` to the hook.
            context.forwardedAmount = JBTokenAmount({
                value: specification.amount,
                token: tokenAmount.token,
                decimals: tokenAmount.decimals,
                currency: tokenAmount.currency
            });

            // Pass the correct metadata from the data hook's specification.
            context.hookMetadata = specification.metadata;

            // Trigger any inherited pre-transfer logic.
            // Keep a reference to the amount that'll be paid as a `msg.value`.
            uint256 payValue = _beforeTransferTo({
                to: address(specification.hook), token: tokenAmount.token, amount: specification.amount
            });

            // Fulfill the specification.
            specification.hook.afterPayRecordedWith{value: payValue}(context);

            // Revoke the temporary pull allowance now that the hook call has finished.
            _afterTransferTo({to: address(specification.hook), token: tokenAmount.token});

            emit HookAfterRecordPay({
                hook: specification.hook,
                context: context,
                specificationAmount: specification.amount,
                caller: _msgSender()
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal implementation of payment logic. Records the payment in the store, mints tokens via the
    /// controller, and fulfills any pay hook specifications from the data hook.
    /// @param projectId The ID of the project to pay.
    /// @param token The address of the token to pay the project with.
    /// @param amount The amount of tokens to send, as a fixed point number with the same number of
    /// decimals as the token's accounting context. If this terminal's token is the native token, `amount` is ignored
    /// and `msg.value` is used in its place.
    /// @param payer The address making the payment.
    /// @param beneficiary The address to mint tokens to, and pass along to the ruleset's data hook and pay hook if
    /// applicable.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and pay hook if applicable.
    /// @return newlyIssuedTokenCount The number of project tokens minted to `beneficiary` as a result of this payment.
    function _pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address payer,
        address beneficiary,
        string memory memo,
        bytes memory metadata
    )
        internal
        returns (uint256 newlyIssuedTokenCount)
    {
        // Keep a reference to the token amount to forward to the store.
        JBTokenAmount memory tokenAmount = _tokenAmountOf({projectId: projectId, token: token, value: amount});

        // Record the payment.
        // Keep a reference to the ruleset the payment is being made during.
        // Keep a reference to the pay hook specifications.
        // Keep a reference to the token count that'll be minted as a result of the payment.
        (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications) = STORE.recordPaymentFrom({
            payer: payer, amount: tokenAmount, projectId: projectId, beneficiary: beneficiary, metadata: metadata
        });

        // Mint tokens if needed.
        if (tokenCount != 0) {
            // Set the token count to be the number of tokens minted for the beneficiary instead of the total
            // amount.
            newlyIssuedTokenCount = _controllerOf(projectId)
                .mintTokensOf({
                projectId: projectId,
                tokenCount: tokenCount,
                beneficiary: beneficiary,
                memo: "",
                useReservedPercent: true
            });
        }

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

        // If the data hook returned pay hook specifications, fulfill them.
        if (hookSpecifications.length != 0) {
            _fulfillPayHookSpecificationsFor({
                projectId: projectId,
                specifications: hookSpecifications,
                tokenAmount: tokenAmount,
                payer: payer,
                ruleset: ruleset,
                beneficiary: beneficiary,
                newlyIssuedTokenCount: newlyIssuedTokenCount,
                metadata: metadata
            });
        }
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

    /// @notice Records a cash out in the terminal store and burns the holder's project tokens.
    /// @dev Shared between `_cashOutTokensOf` and `_cashOutAsPaymentToProject`. The two flows differ in what
    /// happens AFTER the burn (where the reclaim goes, how fees are taken), but the record-and-burn step is
    /// identical.
    /// @param holder The account whose project tokens are being burned.
    /// @param projectId The ID of the project the project tokens belong to.
    /// @param cashOutCount The number of project tokens to burn.
    /// @param tokenToReclaim The terminal token to reclaim from the project's surplus.
    /// @param beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address (passed through
    /// to the data hook context via the store).
    /// @param metadata Bytes to send along to the data hook.
    /// @return ruleset The ruleset the cash out is being made during.
    /// @return reclaimAmount The amount of terminal tokens to be reclaimed.
    /// @return cashOutTaxRate The cash out tax rate being used.
    /// @return hookSpecifications The cash out hook specifications returned by the data hook.
    function _recordAndBurnCashOut(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
        bytes memory metadata
    )
        internal
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Cache the controller to avoid a redundant external call (also used inside STORE.recordCashOutFor).
        IJBController controller = _controllerOf(projectId);

        // Record the cash out.
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = STORE.recordCashOutFor({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });

        // Burn the project tokens.
        if (cashOutCount != 0) {
            controller.burnTokensOf({holder: holder, projectId: projectId, tokenCount: cashOutCount, memo: ""});
        }
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

    /// @notice Routes the cashout reclaim to the destination terminal and credits `_feeFreeSurplusOf[B]` by
    /// the `STORE.balanceOf` delta that lands back on this terminal under B's name.
    /// @dev Same-terminal short-circuits to `_pay` (no transfer needed since the funds are already custodied
    /// here). Cross-terminal goes through the destination's `pay()` entrypoint with the standard
    /// `_beforeTransferTo`/`_afterTransferTo` plumbing. The delta is measured against B's bucket for
    /// `routing.tokenForBeneficiaryProject`, which may differ from `tokenToReclaim` (e.g. a router that swaps
    /// before paying B).
    /// @param tokenToReclaim The token reclaimed from the source project.
    /// @param reclaimAmount The amount of `tokenToReclaim` being routed.
    /// @param beneficiaryProjectId The destination project.
    /// @param beneficiary The address that receives the newly minted destination-project tokens.
    /// @param payMetadata Bytes forwarded to the destination project's pay flow.
    /// @param routing Caller-declared routing: destination terminal, expected return token, delivery floor.
    /// @return beneficiaryTokenCount The number of destination-project tokens minted to `beneficiary`.
    /// @return deliveredToB The `STORE.balanceOf` delta on `(this, beneficiaryProjectId,
    /// routing.tokenForBeneficiaryProject)`.
    function _routeReclaimToBeneficiaryProject(
        address tokenToReclaim,
        uint256 reclaimAmount,
        uint256 beneficiaryProjectId,
        address beneficiary,
        bytes memory payMetadata,
        JBCashOutToProjectContext memory routing
    )
        internal
        returns (uint256 beneficiaryTokenCount, uint256 deliveredToB)
    {
        // Resolve the destination terminal. Caller's explicit override wins; otherwise default to B's primary
        // terminal for the reclaim token.
        IJBTerminal destinationTerminal = routing.destinationTerminal != IJBTerminal(address(0))
            ? routing.destinationTerminal
            : DIRECTORY.primaryTerminalOf({projectId: beneficiaryProjectId, token: tokenToReclaim});

        if (address(destinationTerminal) == address(0)) {
            revert JBMultiTerminal_RecipientProjectTerminalNotFound({
                projectId: beneficiaryProjectId, token: tokenToReclaim
            });
        }

        // Snapshot B's balance before the routing. The delta measured after the call is the delivery proof.
        // Why this is a safe oracle: `STORE.balanceOf(this, B, X)` only increases via real `recordPaymentFrom`
        // or `recordAddedBalanceFor` for B — funds can't be faked in.
        uint256 balanceBefore = STORE.balanceOf({
            terminal: address(this), projectId: beneficiaryProjectId, token: routing.tokenForBeneficiaryProject
        });

        // Pay project B. Same-terminal: internal `_pay` (no transferIn — funds already custodied here).
        if (destinationTerminal == IJBTerminal(address(this))) {
            beneficiaryTokenCount = _pay({
                projectId: beneficiaryProjectId,
                token: tokenToReclaim,
                amount: reclaimAmount,
                payer: _msgSender(),
                beneficiary: beneficiary,
                memo: "",
                metadata: payMetadata
            });
        } else {
            // Cross-terminal: standard pre/post transfer + external `pay()`. We pass `minReturnedTokens: 0`
            // because OUR slippage gate is on the delivered-back delta in the external entrypoint, not on
            // the destination's mint count.
            uint256 payValue =
                _beforeTransferTo({to: address(destinationTerminal), token: tokenToReclaim, amount: reclaimAmount});

            beneficiaryTokenCount = destinationTerminal.pay{value: payValue}({
                projectId: beneficiaryProjectId,
                token: tokenToReclaim,
                amount: reclaimAmount,
                beneficiary: beneficiary,
                minReturnedTokens: 0,
                memo: "",
                metadata: payMetadata
            });

            _afterTransferTo({to: address(destinationTerminal), token: tokenToReclaim});
        }

        // Measure delivery and credit fee-free surplus on B.
        uint256 balanceAfter = STORE.balanceOf({
            terminal: address(this), projectId: beneficiaryProjectId, token: routing.tokenForBeneficiaryProject
        });

        unchecked {
            deliveredToB = balanceAfter - balanceBefore;
            _feeFreeSurplusOf[beneficiaryProjectId][routing.tokenForBeneficiaryProject] += deliveredToB;
        }

        // Cap B's credit at remaining balance. Mirrors the same invariant as in `_cashOutTokensOf` — B's data
        // hook or pay hooks during the routing step might have moved funds out of B's bucket before we
        // measure, so the credit must never claim more than B actually holds.
        _capFeeFreeSurplus({projectId: beneficiaryProjectId, token: routing.tokenForBeneficiaryProject});
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

    /// @notice Takes a fee into the platform's project (with the `_FEE_BENEFICIARY_PROJECT_ID`).
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
                fee: FEE,
                beneficiary: beneficiary,
                caller: _msgSender()
            });
        } else {
            // Get the terminal that'll receive the fee if one wasn't provided.
            IJBTerminal feeTerminal = _primaryTerminalOf({projectId: _FEE_BENEFICIARY_PROJECT_ID, token: token});

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
    /// @dev Only a project's owner or an operator with the `USE_ALLOWANCE` permission from that owner can use the
    /// surplus allowance.
    /// @dev Incurs the protocol fee unless the caller is a feeless address.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param owner The project's owner.
    /// @param token The token to pay out from the surplus.
    /// @param amount The amount of terminal tokens to use from the project's current surplus allowance, as a fixed
    /// point number with the same number of decimals as the token's accounting context.
    /// @param currency The expected currency of the amount to pay out. Must match the currency of one of the
    /// project's current ruleset's surplus allowances.
    /// @param beneficiary The address to send the funds to.
    /// @param feeBeneficiary The address to send the tokens resulting from paying the fee.
    /// @param memo A memo to pass along to the emitted event.
    /// @return netAmountPaidOut The amount of tokens paid out.
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
        // Keep a reference to the ruleset.
        JBRuleset memory ruleset;

        // Keep a reference to the amount paid out before fees.
        uint256 amountPaidOut;

        // Record the use of the allowance.
        (ruleset, amountPaidOut) =
            STORE.recordUsedAllowanceOf({projectId: projectId, token: token, amount: amount, currency: currency});

        // Cap fee-free surplus at remaining balance. Non-fee-free funds leave first.
        _capFeeFreeSurplus({projectId: projectId, token: token});

        // Take a fee from the `amountPaidOut`, if needed.
        // The net amount is the final amount withdrawn after the fee has been taken.
        netAmountPaidOut = amountPaidOut
            - (_isFeeless({addr: owner, projectId: projectId}) || _isFeeless({addr: beneficiary, projectId: projectId})
                    ? 0
                    : _takeFeeFrom({
                        projectId: projectId,
                        token: token,
                        amount: amountPaidOut,
                        // The project owner will receive tokens minted by paying the platform fee.
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

        // Transfer any remaining balance to the beneficiary.
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
        return JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: FEE});
    }
}
