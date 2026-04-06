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
import {JBMetadataResolver} from "./libraries/JBMetadataResolver.sol";
import {JBPayoutSplitGroupLib} from "./libraries/JBPayoutSplitGroupLib.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "./structs/JBAfterPayRecordedContext.sol";
import {JBAfterCashOutRecordedContext} from "./structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "./structs/JBCashOutHookSpecification.sol";
import {JBFee} from "./structs/JBFee.sol";
import {JBPayHookSpecification} from "./structs/JBPayHookSpecification.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";
import {JBSingleAllowance} from "./structs/JBSingleAllowance.sol";
import {JBSplit} from "./structs/JBSplit.sol";
import {JBSplitHookContext} from "./structs/JBSplitHookContext.sol";
import {JBTokenAmount} from "./structs/JBTokenAmount.sol";

/// @notice `JBMultiTerminal` manages native/ERC-20 payments, cash outs, and surplus allowance usage for any number of
/// projects. Terminals are the entry point for operations involving inflows and outflows of funds.
contract JBMultiTerminal is JBPermissioned, ERC2771Context, IJBMultiTerminal {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBMultiTerminal_FeeTerminalNotFound(address token);
    error JBMultiTerminal_MintNotAllowed();
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

    /// @notice The contract that stores addresses that shouldn't incur fees when being paid towards or from.
    IJBFeelessAddresses public immutable override FEELESS_ADDRESSES;

    /// @notice The permit2 utility.
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

    /// @notice Fees that are being held for each project.
    /// @dev Projects can temporarily hold fees and unlock them later by adding funds to the project's balance.
    /// @dev Held fees can be processed at any time by this terminal's owner.
    /// @custom:param projectId The ID of the project that is holding fees.
    /// @custom:param token The token that the fees are held in.
    mapping(uint256 projectId => mapping(address token => JBFee[])) internal _heldFeesOf;

    /// @notice The next index to use when processing a next held fee.
    /// @custom:param projectId The ID of the project that is holding fees.
    /// @custom:param token The token that the fees are held in.
    mapping(uint256 projectId => mapping(address token => uint256)) internal _nextHeldFeeIndexOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param feelessAddresses A contract that stores addresses that shouldn't incur fees when being paid towards or
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

    /// @notice Adds accounting contexts for a project to this terminal so the project can begin accepting the tokens in
    /// those contexts.
    /// @dev Only a project's owner, an operator with the `ADD_ACCOUNTING_CONTEXTS` permission from that owner, or a
    /// project's controller can add accounting contexts for the project.
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
        for (uint256 i; i < accountingContexts.length; i++) {
            // slither-disable-next-line reentrancy-events
            emit SetAccountingContext({projectId: projectId, context: accountingContexts[i], caller: _msgSender()});
        }
    }

    /// @notice Adds funds to a project's balance without minting tokens.
    /// @dev Adding to balance can unlock held fees if `shouldUnlockHeldFees` is true.
    /// @param projectId The ID of the project to add funds to the balance of.
    /// @param amount The amount of tokens to add to the balance, as a fixed point number with the same number of
    /// decimals as this terminal. If this is a native token terminal, this is ignored and `msg.value` is used instead.
    /// @param token The token being added to the balance.
    /// @param shouldReturnHeldFees A flag indicating if held fees should be returned based on the amount being added.
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
            amount: _acceptFundsFor(projectId, token, amount, metadata),
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Holders can cash out a project's tokens to reclaim some of that project's surplus tokens, or to trigger
    /// rules determined by the current ruleset's data hook and cash out hook.
    /// @dev Only a token's holder or an operator with the `CASH_OUT_TOKENS` permission from that holder can cash out
    /// those tokens.
    /// @param holder The account whose tokens are being cashed out.
    /// @param projectId The ID of the project the project tokens belong to.
    /// @param cashOutCount The number of project tokens to cash out and burn, as a fixed point number with 18
    /// decimals.
    /// @param tokenToReclaim The token being reclaimed.
    /// @param minTokensReclaimed The minimum number of terminal tokens expected in return, as a fixed point number with
    /// the same number of decimals as this terminal. If the amount of tokens minted for the beneficiary would be less
    /// than this amount, the cash out is reverted.
    /// @param beneficiary The address to send the cashed out terminal tokens to, and to pass along to the ruleset's
    /// data hook and cash out hook if applicable.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and cash out hook if
    /// applicable.
    /// @return reclaimAmount The amount of terminal tokens that the project tokens were cashed out for, as a fixed
    /// point
    /// number with 18 decimals.
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
    /// @param token The address of the token being paid to the split.
    /// @param amount The total amount being paid to the split, as a fixed point number with the same number of
    /// decimals as this terminal.
    /// @return netPayoutAmount The amount sent to the split after subtracting fees.
    function executePayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        address originalMessageSender
    )
        external
        returns (uint256 netPayoutAmount)
    {
        // NOTICE: May only be called by this terminal itself.
        require(msg.sender == address(this));

        // By default, the net payout amount is the full amount. This will be adjusted if fees are taken.
        netPayoutAmount = amount;

        // If there's a split hook set, transfer to its `process` function.
        if (split.hook != IJBSplitHook(address(0))) {
            // Make sure that the address supports the split hook interface.
            if (!split.hook.supportsInterface(type(IJBSplitHook).interfaceId)) {
                revert JBMultiTerminal_SplitHookInvalid(split.hook);
            }

            // This payout is eligible for a fee since the funds are leaving this contract and the split hook isn't a
            // feeless address.
            if (!_isFeeless(address(split.hook))) {
                netPayoutAmount -= JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: FEE});
            }

            // Create the context to send to the split hook.
            JBSplitHookContext memory context = JBSplitHookContext({
                token: token,
                amount: netPayoutAmount,
                decimals: STORE.accountingContextOf({terminal: address(this), projectId: projectId, token: token})
                .decimals,
                projectId: projectId,
                groupId: uint256(uint160(token)),
                split: split
            });

            // Trigger any inherited pre-transfer logic.
            // Get a reference to the amount being paid in `msg.value`.
            uint256 payValue = _beforeTransferTo({to: address(split.hook), token: token, amount: netPayoutAmount});

            // If this terminal's token is the native token, send it in `msg.value`.
            split.hook.processSplitWith{value: payValue}(context);

            // Revoke the temporary pull allowance now that the hook call has finished.
            _afterTransferTo({to: address(split.hook), token: token});

            // Otherwise, if a project is specified, make a payment to it.
        } else if (split.projectId != 0) {
            // Get a reference to the terminal being used.
            IJBTerminal terminal = _primaryTerminalOf({projectId: split.projectId, token: token});

            // The project must have a terminal to send funds to.
            if (terminal == IJBTerminal(address(0))) {
                revert JBMultiTerminal_RecipientProjectTerminalNotFound(split.projectId, token);
            }

            // Fees apply to fund egress, not intra-terminal accounting. When both projects share this terminal,
            // funds stay within the contract (addToBalance or pay) so no fee is charged. This is intentional:
            // the fee model taxes value leaving the protocol ecosystem, not internal rebalancing.
            // This payout is eligible for a fee if the funds are leaving this contract and the receiving terminal isn't
            // a feeless address.
            if (terminal != this && !_isFeeless(address(terminal))) {
                netPayoutAmount -= JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: FEE});
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
                    revert JBMultiTerminal_MintNotAllowed();
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
                // slither-disable-next-line reentrancy-eth
                _capFeeFreeSurplus({projectId: split.projectId, token: token});
            }
        } else {
            // If there's a beneficiary, send the funds directly to the beneficiary.
            // If there isn't a beneficiary, send the funds to the  `_msgSender()`.
            address payable recipient =
                split.beneficiary != address(0) ? split.beneficiary : payable(originalMessageSender);

            // This payout is eligible for a fee since the funds are leaving this contract and the recipient isn't a
            // feeless address.
            if (!_isFeeless(recipient)) {
                netPayoutAmount -= JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: FEE});
            }

            // If there's a beneficiary, send the funds directly to the beneficiary. Otherwise send to the
            // `_msgSender()`.
            _transferFrom({from: address(this), to: recipient, token: token, amount: netPayoutAmount});
        }
    }

    /// @notice Process a specified amount of fees for a project.
    /// @dev Only accepts calls from this terminal itself.
    /// @param projectId The ID of the project paying the fee.
    /// @param token The token the fee is being paid in.
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
            revert JBMultiTerminal_FeeTerminalNotFound(token);
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
    /// @param projectId The ID of the project being migrated.
    /// @param token The address of the token being migrated.
    /// @param to The terminal contract being migrated to, which will receive the project's funds and operations.
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
        // slither-disable-next-line reentrancy-events
        balance = STORE.recordTerminalMigration({projectId: projectId, token: token});

        emit MigrateTerminal({projectId: projectId, token: token, to: to, amount: balance, caller: _msgSender()});

        // Transfer the balance if needed.
        if (balance != 0) {
            // Migration to a non-feeless terminal incurs the standard 2.5% fee, same as any other fund egress.
            // This also settles any fee-free surplus liability that would otherwise be lost on the new terminal.
            uint256 feeAmount;
            if (!_isFeeless(address(to)) && projectId != _FEE_BENEFICIARY_PROJECT_ID) {
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

    /// @notice Pay a project with tokens.
    /// @param projectId The ID of the project being paid.
    /// @param amount The amount of terminal tokens being received, as a fixed point number with the same number of
    /// decimals as this terminal. If this terminal's token is native, this is ignored and `msg.value` is used in its
    /// place.
    /// @param token The token being paid.
    /// @param beneficiary The address to mint tokens to, and pass along to the ruleset's data hook and pay hook if
    /// applicable.
    /// @param minReturnedTokens The minimum number of project tokens expected in return for this payment, as a fixed
    /// point number with the same number of decimals as this terminal. If the amount of tokens minted for the
    /// beneficiary would be less than this amount, the payment is reverted.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to pass along to the emitted event, as well as the data hook and pay hook if applicable.
    /// @return beneficiaryTokenCount The number of tokens minted to the beneficiary, as a fixed point number with 18
    /// decimals.
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

        // Pay the project.
        _pay({
            projectId: projectId,
            token: token,
            amount: _acceptFundsFor(projectId, token, amount, metadata),
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

    /// @notice Process any fees that are being held for the project.
    /// @dev Reentrancy safety: the loop re-reads `_nextHeldFeeIndexOf` from storage each iteration and advances the
    /// index before the external `_processFee` call, so a reentrant call cannot double-process the same fee entry.
    /// @dev Held fees after migration: held fees remain in this terminal after `migrateBalanceOf` because their backing
    /// tokens are not part of `balanceOf` — they were already deducted from the recorded balance during the payout
    /// that
    /// created them. The actual fee-backing tokens remain in this terminal's token holdings. If `_processFee` reverts
    /// (e.g. the fee terminal rejects the payment), the catch block calls `_recordAddedBalanceFor` to credit the fee
    /// amount back to the project. This credit is backed by the tokens that failed to transfer out. No phantom balance
    /// is created because the tokens never left.
    /// @dev The index-increment-before-`_processFee` pattern is intentional: locked (not-yet-unlocked) fees are skipped
    /// via the `unlockTimestamp` check, and advancing the index before the external call prevents reentrancy from
    /// reprocessing the same fee entry.
    /// @param projectId The ID of the project to process held fees for.
    /// @param token The token to process held fees for.
    /// @param count The number of fees to process.
    function processHeldFeesOf(uint256 projectId, address token, uint256 count) external override {
        // Keep a reference to the terminal that'll receive the fees.
        IJBTerminal feeTerminal = _primaryTerminalOf({projectId: _FEE_BENEFICIARY_PROJECT_ID, token: token});

        // Process each fee. Re-read the index and array length from storage each iteration to account for reentrant
        // calls that may have already advanced the index or cleaned up the array.
        for (uint256 i; i < count; i++) {
            // Read the current index from storage (not a cached value) to prevent reentrancy from
            // causing double-processing.
            uint256 currentIndex = _nextHeldFeeIndexOf[projectId][token];

            // If all fees have been processed, break to cleanup.
            if (currentIndex >= _heldFeesOf[projectId][token].length) break;

            // Keep a reference to the held fee being iterated on.
            JBFee memory heldFee = _heldFeesOf[projectId][token][currentIndex];

            // Can't process fees that aren't yet unlocked. Fees unlock sequentially in the array, so nothing left to do
            // if the current fee isn't yet unlocked.
            if (heldFee.unlockTimestamp > block.timestamp) break;

            // Delete the entry and advance the index *before* the external call. This is intentional:
            // 1. It prevents reentrancy from reprocessing the same fee.
            // 2. If `_processFee` fails (try-catch), the fee amount is returned to the project's balance via
            //    `_recordAddedBalanceFor` — the fee is forgiven rather than retried. This is a deliberate design choice:
            //    projects should not have funds permanently stuck because the fee route is misconfigured or reverting.
            //    A `FeeReverted` event is emitted so the forgiveness is observable off-chain.
            delete _heldFeesOf[projectId][token][currentIndex];
            _nextHeldFeeIndexOf[projectId][token] = currentIndex + 1;

            // Process the fee.
            // slither-disable-next-line reentrancy-no-eth
            _processFee({
                projectId: projectId,
                token: token,
                amount: JBFees.feeAmountFrom({amountBeforeFee: heldFee.amount, feePercent: FEE}),
                beneficiary: heldFee.beneficiary,
                feeTerminal: feeTerminal,
                wasHeld: true
            });
        }

        // If all held fees have been processed, reset the array and index entirely to bound storage growth.
        if (
            _nextHeldFeeIndexOf[projectId][token] >= _heldFeesOf[projectId][token].length
                && _heldFeesOf[projectId][token].length > 0
        ) {
            delete _heldFeesOf[projectId][token];
            delete _nextHeldFeeIndexOf[projectId][token];
        }
    }

    /// @notice Sends payouts to a project's current payout split group, according to its ruleset, up to its current
    /// payout limit.
    /// @dev If the percentages of the splits in the project's payout split group do not add up to 100%, the remainder
    /// is sent to the project's owner.
    /// @dev Anyone can send payouts on a project's behalf. Projects can include a wildcard split (a split with no
    /// `hook`, `projectId`, or `beneficiary`) to send funds to the `_msgSender()` which calls this function. This can
    /// be used to incentivize calling this function.
    /// @dev payouts sent to addresses which aren't feeless incur the protocol fee.
    /// @dev Payouts a projects don't incur fees if its terminal is feeless.
    /// @param projectId The ID of the project having its payouts sent.
    /// @param token The token being sent.
    /// @param amount The total number of terminal tokens to send, as a fixed point number with same number of decimals
    /// as this terminal.
    /// @param currency The expected currency of the payouts being sent. Must match the currency of one of the
    /// project's current ruleset's payout limits.
    /// @param minTokensPaidOut The minimum number of terminal tokens that the `amount` should be worth (if expressed
    /// in terms of this terminal's currency), as a fixed point number with the same number of decimals as this
    /// terminal. If the amount of tokens paid out would be less than this amount, the send is reverted.
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

    /// @notice Allows a project to pay out funds from its surplus up to the current surplus allowance.
    /// @dev Only a project's owner or an operator with the `USE_ALLOWANCE` permission from that owner can use the
    /// surplus allowance.
    /// @dev Incurs the protocol fee unless the caller is a feeless address.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param token The token being paid out from the surplus.
    /// @param amount The amount of terminal tokens to use from the project's current surplus allowance, as a fixed
    /// point number with the same amount of decimals as this terminal.
    /// @param currency The expected currency of the amount being paid out. Must match the currency of one of the
    /// project's current ruleset's surplus allowances.
    /// @param minTokensPaidOut The minimum number of terminal tokens that should be returned from the surplus allowance
    /// (excluding fees), as a fixed point number with 18 decimals. If the amount of surplus used would be less than
    /// this amount, the transaction is reverted.
    /// @param beneficiary The address to send the surplus funds to.
    /// @param feeBeneficiary The address to send the tokens resulting from paying the fee.
    /// @param memo A memo to pass along to the emitted event.
    /// @return netAmountPaidOut The number of tokens that were sent to the beneficiary, as a fixed point number with
    /// the same amount of decimals as the terminal.
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

    /// @notice A project's accounting context for a token.
    /// @dev See the `JBAccountingContext` struct for more information.
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

    /// @notice The tokens accepted by a project.
    /// @param projectId The ID of the project to get the accepted tokens of.
    /// @return tokenContexts The accounting contexts of the accepted tokens.
    function accountingContextsOf(uint256 projectId) external view override returns (JBAccountingContext[] memory) {
        return STORE.accountingContextsOf({terminal: address(this), projectId: projectId});
    }

    /// @notice Gets the current surplus amount in this terminal for a project, in terms of a given currency.
    /// @dev If `tokens` is empty, includes all tokens the project accepts (as returned by `accountingContextsOf(...)`).
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

    /// @notice Fees that are being held for a project.
    /// @dev Projects can temporarily hold fees and unlock them later by adding funds to the project's balance.
    /// @dev Held fees can be processed at any time by this terminal's owner.
    /// @param projectId The ID of the project that is holding fees.
    /// @param token The token that the fees are held in.
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
        for (uint256 i; i < count; i++) {
            heldFees[i] = _heldFeesOf[projectId][token][startIndex + i];
        }
    }

    /// @notice Simulates cashing out project tokens from this terminal without modifying state.
    /// @param holder The address whose tokens are being cashed out.
    /// @param projectId The ID of the project whose tokens are being cashed out.
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
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) =
            STORE.previewCashOutFrom({
                terminal: address(this),
                holder: holder,
                projectId: projectId,
                cashOutCount: cashOutCount,
                tokenToReclaim: tokenToReclaim,
                beneficiaryIsFeeless: _isFeeless(beneficiary),
                metadata: metadata
            });
    }

    /// @notice Simulates paying a project through this terminal without modifying state.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in.
    /// @param amount The amount of tokens being paid.
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
    /// @param projectId The ID of the project that the transfer is being accepted for.
    /// @param token The token being accepted.
    /// @param amount The number of tokens being accepted.
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
                revert JBMultiTerminal_PermitAllowanceNotEnough(amount, allowance.amount);
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
                // slither-disable-next-line reentrancy-events
                emit Permit2AllowanceFailed(token, _msgSender(), reason);
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
    /// @param token The address of the token being added to the project's balance.
    /// @param amount The amount of tokens to add as a fixed point number with the same number of decimals as this
    /// terminal. If this is a native token terminal, this is ignored and `msg.value` is used instead.
    /// @param shouldReturnHeldFees A flag indicating if held fees should be returned based on the amount being added.
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
    /// @param token The token being transferred.
    /// @param amount The number of tokens being transferred, as a fixed point number with the same number of decimals
    /// as this terminal.
    /// @return payValue The value to attach to the transaction being sent.
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
            // slither-disable-next-line reentrancy-no-eth,reentrancy-eth,reentrancy-benign
            _feeFreeSurplusOf[projectId][token] = remainingBalance;
        }
    }

    /// @notice Holders can cash out their tokens to reclaim some of a project's surplus, or to trigger rules determined
    /// by
    /// the project's current ruleset's data hook.
    /// @dev Only a token holder or an operator with the `CASH_OUT_TOKENS` permission from that holder can cash out
    /// those
    /// tokens.
    /// @param holder The account cashing out tokens.
    /// @param projectId The ID of the project whose tokens are being cashed out.
    /// @param cashOutCount The number of project tokens to cash out, as a fixed point number with 18 decimals.
    /// @param tokenToReclaim The address of the token which is being cashed out.
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

        // Record the cash out.
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = STORE.recordCashOutFor({
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: _isFeeless(beneficiary),
            metadata: metadata
        });

        // Burn the project tokens.
        if (cashOutCount != 0) {
            _controllerOf(projectId)
                .burnTokensOf({holder: holder, projectId: projectId, tokenCount: cashOutCount, memo: ""});
        }

        // Keep a reference to the amount being reclaimed that is subject to fees.
        uint256 amountEligibleForFees;

        // Send the reclaimed funds to the beneficiary.
        if (reclaimAmount != 0) {
            // Determine if a fee should be taken. Fees are not taken if the beneficiary is feeless.
            if (!_isFeeless(beneficiary)) {
                if (cashOutTaxRate != 0) {
                    // Non-zero tax: fees apply to the full reclaim amount.
                    amountEligibleForFees += reclaimAmount;
                    reclaimAmount -= JBFees.feeAmountFrom({amountBeforeFee: reclaimAmount, feePercent: FEE});
                } else {
                    // Zero tax: fees apply only up to the fee-free surplus (round-trip prevention).
                    uint256 feeFreeSurplus = _feeFreeSurplusOf[projectId][tokenToReclaim];
                    if (feeFreeSurplus != 0) {
                        uint256 feeableAmount = reclaimAmount < feeFreeSurplus ? reclaimAmount : feeFreeSurplus;
                        // slither-disable-next-line reentrancy-no-eth,reentrancy-eth,reentrancy-benign
                        _feeFreeSurplusOf[projectId][tokenToReclaim] = feeFreeSurplus - feeableAmount;
                        amountEligibleForFees += feeableAmount;
                        reclaimAmount -= JBFees.feeAmountFrom({amountBeforeFee: feeableAmount, feePercent: FEE});
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
        // slither-disable-next-line reentrancy-eth
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
    /// @param projectId The ID of the project being funded.
    /// @param token The token being used.
    /// @param amount The amount being funded, as a fixed point number with the amount of decimals that the terminal's
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
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in.
    /// @param amount The amount being paid, as a fixed point number with the amount of decimals that the terminal's
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
            // slither-disable-next-line reentrancy-events
            uint256 payValue = _beforeTransferTo({to: address(terminal), token: token, amount: amount});

            // Send the fee.
            // If this terminal's token is ETH, send it in msg.value.
            // slither-disable-next-line unused-return
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
    /// @param projectId The ID of the project being funded.
    /// @param token The token being used.
    /// @param amount The amount being funded.
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
        // slither-disable-next-line reentrancy-events
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
    /// @param projectId The ID of the project being cashed out from.
    /// @param beneficiaryReclaimAmount The number of tokens that are being cashed out from the project.
    /// @param holder The address that holds the tokens being cashed out.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param metadata Bytes to send along to the emitted event and cash out hooks as applicable.
    /// @param ruleset The ruleset the cash out is being made during as a `JBRuleset` struct.
    /// @param cashOutTaxRate The cash out tax rate influencing the reclaim amount.
    /// @param beneficiary The address which will receive any terminal tokens that are cashed out.
    /// @param specifications The hook specifications being fulfilled.
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

        // slither-disable-next-line calls-loop
        for (uint256 i; i < specifications.length; i++) {
            // Set the specification being iterated on.
            JBCashOutHookSpecification memory specification = specifications[i];

            // A noop specification is informational only and doesn't trigger the hook.
            if (specification.noop) continue;

            // Get the fee for the specified amount.
            uint256 specificationAmountFee = _isFeeless(address(specification.hook))
                ? 0
                : JBFees.feeAmountFrom({amountBeforeFee: specification.amount, feePercent: FEE});

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
            // slither-disable-next-line reentrancy-events
            uint256 payValue = _beforeTransferTo({
                to: address(specification.hook), token: beneficiaryReclaimAmount.token, amount: specification.amount
            });

            // Fulfill the specification.
            // slither-disable-next-line reentrancy-events,calls-loop
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
        }
    }

    /// @notice Fulfills a list of pay hook specifications.
    /// @param projectId The ID of the project being paid.
    /// @param specifications The pay hook specifications to be fulfilled.
    /// @param tokenAmount The amount of tokens that the project was paid.
    /// @param payer The address that sent the payment.
    /// @param ruleset The ruleset the payment is being accepted during.
    /// @param beneficiary The address which will receive any tokens that the payment yields.
    /// @param newlyIssuedTokenCount The amount of tokens that are being issued and sent to the beneificary.
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
        // slither-disable-next-line calls-loop
        for (uint256 i; i < specifications.length; i++) {
            // Set the specification being iterated on.
            JBPayHookSpecification memory specification = specifications[i];

            // A noop specification is informational only and doesn't trigger the hook.
            if (specification.noop) continue;

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
            // slither-disable-next-line reentrancy-events
            uint256 payValue = _beforeTransferTo({
                to: address(specification.hook), token: tokenAmount.token, amount: specification.amount
            });

            // Fulfill the specification.
            // slither-disable-next-line reentrancy-events,calls-loop
            specification.hook.afterPayRecordedWith{value: payValue}(context);

            // Revoke the temporary pull allowance now that the hook call has finished.
            _afterTransferTo({to: address(specification.hook), token: tokenAmount.token});

            emit HookAfterRecordPay({
                hook: specification.hook,
                context: context,
                specificationAmount: specification.amount,
                caller: _msgSender()
            });
        }
    }

    /// @notice Pay a project with tokens.
    /// @param projectId The ID of the project being paid.
    /// @param token The address of the token which the project is being paid with.
    /// @param amount The amount of terminal tokens being received, as a fixed point number with the same number of
    /// decimals as this terminal. If this terminal's token is the native token, `amount` is ignored and `msg.value` is
    /// used in its place.
    /// @param payer The address making the payment.
    /// @param beneficiary The address to mint tokens to, and pass along to the ruleset's data hook and pay hook if
    /// applicable.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and pay hook if applicable.
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
    {
        // Keep a reference to the token amount to forward to the store.
        JBTokenAmount memory tokenAmount = _tokenAmountOf({projectId: projectId, token: token, value: amount});

        // Record the payment.
        // Keep a reference to the ruleset the payment is being made during.
        // Keep a reference to the pay hook specifications.
        // Keep a reference to the token count that'll be minted as a result of the payment.
        // slither-disable-next-line reentrancy-events
        (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications) = STORE.recordPaymentFrom({
            payer: payer, amount: tokenAmount, projectId: projectId, beneficiary: beneficiary, metadata: metadata
        });

        // Keep a reference to the number of tokens issued for the beneficiary.
        uint256 newlyIssuedTokenCount;

        // Mint tokens if needed.
        if (tokenCount != 0) {
            // Set the token count to be the number of tokens minted for the beneficiary instead of the total
            // amount.
            // slither-disable-next-line reentrancy-events
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
    /// @param token The token the fee is being paid in.
    /// @param amount The fee amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address which will receive any platform tokens minted.
    /// @param feeTerminal The terminal that'll receive the fee.
    /// @param wasHeld A flag indicating if the fee being processed was being held by this terminal.
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
        // slither-disable-next-line reentrancy-events,calls-loop
        try this.executeProcessFee({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary, feeTerminal: feeTerminal
        }) {
            emit ProcessFee({
                projectId: projectId,
                token: token,
                amount: amount,
                wasHeld: wasHeld,
                beneficiary: beneficiary,
                caller: _msgSender()
            });
        } catch (bytes memory reason) {
            // Fee processing failed — intentionally forgive the fee and return the amount to the project.
            // The held-fee entry (if any) was already deleted by `processHeldFeesOf` before this call, so there is no
            // retry path. This is by design: a broken or misconfigured fee route should not permanently lock project
            // funds. The `FeeReverted` event makes this observable off-chain.
            emit FeeReverted({
                projectId: projectId,
                token: token,
                feeProjectId: _FEE_BENEFICIARY_PROJECT_ID,
                amount: amount,
                reason: reason,
                caller: _msgSender()
            });

            _recordAddedBalanceFor({projectId: projectId, token: token, amount: amount});
        }
    }

    /// @notice Records an added balance for a project.
    /// @param projectId The ID of the project to record the added balance for.
    /// @param token The token to record the added balance for.
    /// @param amount The amount of the token to record, as a fixed point number with the same number of decimals as
    /// this
    /// terminal.
    function _recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) internal {
        // slither-disable-next-line calls-loop
        STORE.recordAddedBalanceFor({projectId: projectId, token: token, amount: amount});
    }

    /// @notice Returns held fees to the project who paid them based on the specified amount.
    /// @param projectId The project held fees are being returned to.
    /// @param token The token that the held fees are in.
    /// @param amount The amount to base the calculation on, as a fixed point number with the same number of decimals
    /// as this terminal.
    /// @return returnedFees The amount of held fees that were returned, as a fixed point number with the same number of
    /// decimals as this terminal
    function _returnHeldFees(uint256 projectId, address token, uint256 amount) internal returns (uint256 returnedFees) {
        // Keep a reference to the start index.
        uint256 startIndex = _nextHeldFeeIndexOf[projectId][token];

        // Get a reference to the project's held fees.
        uint256 numberOfHeldFees = _heldFeesOf[projectId][token].length;

        // If the start index is greater than or equal to the number of held fees, return 0.
        if (startIndex >= numberOfHeldFees) return 0;

        // Get a reference to the leftover amount once all fees have been settled.
        uint256 leftoverAmount = amount;

        // Keep a reference to the number of iterations to perform.
        uint256 count = numberOfHeldFees - startIndex;

        // Keep a reference to the new start index.
        uint256 newStartIndex = startIndex;

        // Process each fee.
        for (uint256 i; i < count; i++) {
            // Save the fee being iterated on.
            JBFee memory heldFee = _heldFeesOf[projectId][token][startIndex + i];

            // slither-disable-next-line incorrect-equality
            if (leftoverAmount == 0) {
                break;
            } else {
                // Notice here we take `feeAmountFrom` on the stored `.amount`.
                uint256 feeAmount = JBFees.feeAmountFrom({amountBeforeFee: heldFee.amount, feePercent: FEE});

                // Keep a reference to the amount from which the fee was taken.
                uint256 amountPaidOut = heldFee.amount - feeAmount;

                if (leftoverAmount >= amountPaidOut) {
                    unchecked {
                        leftoverAmount -= amountPaidOut;
                        returnedFees += feeAmount;
                    }

                    // Move the start index forward to the held fee after the current one.
                    newStartIndex = startIndex + i + 1;
                } else {
                    // And here we overwrite with `feeAmountResultingIn` the `leftoverAmount`
                    feeAmount = JBFees.feeAmountResultingIn({amountAfterFee: leftoverAmount, feePercent: FEE});

                    // Get fee from `leftoverAmount`.
                    unchecked {
                        _heldFeesOf[projectId][token][startIndex + i].amount -= (leftoverAmount + feeAmount);
                        returnedFees += feeAmount;
                    }
                    leftoverAmount = 0;
                }
            }
        }

        // Update the next held fee index.
        if (startIndex != newStartIndex) _nextHeldFeeIndexOf[projectId][token] = newStartIndex;

        emit ReturnHeldFees({
            projectId: projectId,
            token: token,
            amount: amount,
            returnedFees: returnedFees,
            leftoverAmount: leftoverAmount,
            caller: _msgSender()
        });
    }

    /// @notice Sends payouts to a project's payout split group using the specified ruleset.
    /// @param projectId The ID of the project to send the payouts of.
    /// @param token The token being paid out.
    /// @param amount The number of terminal tokens to pay out, as a fixed point number with same number of decimals as
    /// this terminal.
    /// @param currency The expected currency of the amount being paid out. Must match the currency of one of the
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
        // Keep a reference to the ruleset.
        JBRuleset memory ruleset;

        // Record the payout.
        (ruleset, amountPaidOut) =
            STORE.recordPayoutFor({projectId: projectId, token: token, amount: amount, currency: currency});

        // Cap fee-free surplus at remaining balance. Non-fee-free funds leave first.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-eth,reentrancy-benign
        _capFeeFreeSurplus({projectId: projectId, token: token});

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
            caller: _msgSender()
        });

        // Send any leftover funds to the project owner and update the fee tracking accordingly.
        if (leftoverPayoutAmount != 0) {
            // Keep a reference to the fee for the leftover payout amount.
            uint256 fee = _isFeeless(projectOwner)
                ? 0
                : JBFees.feeAmountFrom({amountBeforeFee: leftoverPayoutAmount, feePercent: FEE});

            // Failed owner transfer consumes the payout limit by design. Same pattern as split payouts:
            // the try-catch prevents revert, failed amount is returned to project balance, and the owner can retry
            // via addToBalanceOf or in the next cycle.
            try this.executeTransferTo({addr: projectOwner, token: token, amount: leftoverPayoutAmount - fee}) {
                if (fee > 0) {
                    amountEligibleForFees += leftoverPayoutAmount;
                    leftoverPayoutAmount -= fee;
                }
            } catch (bytes memory reason) {
                // slither-disable-next-line reentrancy-events
                emit PayoutTransferReverted({
                    projectId: projectId,
                    addr: projectOwner,
                    token: token,
                    amount: leftoverPayoutAmount - fee,
                    fee: fee,
                    reason: reason,
                    caller: _msgSender()
                });

                // Add balance back to the project.
                _recordAddedBalanceFor({projectId: projectId, token: token, amount: leftoverPayoutAmount});
            }
        }

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
            caller: _msgSender()
        });
    }

    /// @notice Takes a fee into the platform's project (with the `_FEE_BENEFICIARY_PROJECT_ID`).
    /// @param projectId The ID of the project paying the fee.
    /// @param token The address of the token that the fee is being paid in.
    /// @param amount The fee's token amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address to mint the platform's project's tokens for.
    /// @param shouldHoldFees If fees should be tracked and held instead of being exercised immediately.
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
        feeAmount = JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: FEE});

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
    /// @param token The token being transfered.
    /// @param amount The number of tokens being transferred, as a fixed point number with the same number of decimals
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
    /// @param token The token being paid out from the surplus.
    /// @param amount The amount of terminal tokens to use from the project's current surplus allowance, as a fixed
    /// point number with the same amount of decimals as this terminal.
    /// @param currency The expected currency of the amount being paid out. Must match the currency of one of the
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
        // slither-disable-next-line reentrancy-no-eth,reentrancy-eth,reentrancy-benign
        _capFeeFreeSurplus({projectId: projectId, token: token});

        // Take a fee from the `amountPaidOut`, if needed.
        // The net amount is the final amount withdrawn after the fee has been taken.
        // slither-disable-next-line reentrancy-events
        netAmountPaidOut = amountPaidOut
            - (_isFeeless(owner) || _isFeeless(beneficiary)
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
        // slither-disable-next-line calls-loop
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
    /// @return A flag indicating if the address should not incur fees.
    function _isFeeless(address addr) internal view returns (bool) {
        return FEELESS_ADDRESSES.isFeeless(addr);
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
    /// @param token The token being paid.
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
}
