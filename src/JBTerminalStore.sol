// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBController} from "./interfaces/IJBController.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBPrices} from "./interfaces/IJBPrices.sol";
import {IJBRulesetDataHook} from "./interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "./interfaces/IJBRulesets.sol";
import {IJBTerminal} from "./interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "./interfaces/IJBTerminalStore.sol";
import {JBCashOuts} from "./libraries/JBCashOuts.sol";
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBFixedPointNumber} from "./libraries/JBFixedPointNumber.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBSurplus} from "./libraries/JBSurplus.sol";
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBBeforePayRecordedContext} from "./structs/JBBeforePayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "./structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "./structs/JBCashOutHookSpecification.sol";
import {JBCurrencyAmount} from "./structs/JBCurrencyAmount.sol";
import {JBPayHookSpecification} from "./structs/JBPayHookSpecification.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";
import {JBTokenAmount} from "./structs/JBTokenAmount.sol";

/// @notice The accounting engine behind every terminal. Records project balances, enforces payout limits and surplus
/// allowances, calculates how many tokens to mint per payment (based on the ruleset's weight and currency), and
/// determines how much a token holder receives when cashing out (via the bonding curve in `JBCashOuts`).
/// @dev Terminals call `recordPaymentFrom`, `recordPayoutFor`, `recordUsedAllowanceFrom`, and `recordCashOutFor` to
/// update state. This contract also handles data hook integration — if a ruleset specifies a data hook, it is called
/// before recording to potentially override token counts or specify pay/cash-out hooks.
contract JBTerminalStore is IJBTerminalStore {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBTerminalStore_AccountingContextAlreadySet(address token);
    error JBTerminalStore_AccountingContextDecimalsMismatch(
        address token, uint256 providedDecimals, uint256 expectedDecimals
    );
    error JBTerminalStore_AddingAccountingContextNotAllowed(uint256 projectId, uint256 rulesetId, address terminal);
    error JBTerminalStore_InadequateControllerAllowance(uint256 amount, uint256 allowance);

    error JBTerminalStore_InadequateTerminalStoreBalance(uint256 amount, uint256 balance);
    error JBTerminalStore_InsufficientTokens(uint256 count, uint256 totalSupply);
    error JBTerminalStore_InvalidAmountToForwardHook(uint256 amount, uint256 paidAmount);
    error JBTerminalStore_NoopHookSpecHasAmount(uint256 amount);
    error JBTerminalStore_RulesetNotFound(uint256 projectId);
    error JBTerminalStore_RulesetPaymentPaused(uint256 projectId, uint256 rulesetId);
    error JBTerminalStore_TerminalMigrationNotAllowed(uint256 projectId, uint256 rulesetId);
    error JBTerminalStore_Uint224Overflow(uint256 value);
    error JBTerminalStore_ZeroAccountingContextCurrency(address token);

    //*********************************************************************//
    // -------------------------- internal constants --------------------- //
    //*********************************************************************//

    /// @notice Constrains `mulDiv` operations on fixed point numbers to a maximum number of decimal points of persisted
    /// fidelity.
    uint256 internal constant _MAX_FIXED_POINT_FIDELITY = 18;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The contract that exposes price feeds.
    IJBPrices public immutable override PRICES;

    /// @notice The contract storing and managing project rulesets.
    IJBRulesets public immutable override RULESETS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice A project's balance of a specific token within a terminal.
    /// @dev The balance is represented as a fixed point number with the same amount of decimals as its relative
    /// terminal.
    /// @custom:param terminal The terminal to get the project's balance within.
    /// @custom:param projectId The ID of the project to get the balance of.
    /// @custom:param token The token to get the balance for.
    mapping(address terminal => mapping(uint256 projectId => mapping(address token => uint256)))
        public
        override balanceOf;

    /// @notice Cumulative fee payment amount credited to a referral project as a result of fee-paying calls that
    /// originated through a given terminal.
    /// @dev Written by terminals via `recordFeeReferralCreditOf`; the writing terminal is `msg.sender`, so a caller
    /// can only pollute their own bucket.
    /// @custom:param terminal The terminal that originated the fee-paying call.
    /// @custom:param referralProjectId The referral project credited.
    mapping(address terminal => mapping(uint256 referralProjectId => uint256)) public override feeVolumeByReferralOf;

    /// @notice Cumulative fee payment amount credited across all referral projects for a given terminal.
    /// @dev Updated in lockstep with `feeVolumeByReferralOf` so consumers can compute a referrer's pro-rata share
    /// in a single SLOAD pair without enumerating referrers. Used as the denominator by split hooks that distribute
    /// rewards proportional to attributed fee volume.
    /// @custom:param terminal The terminal that originated the fee-paying calls.
    mapping(address terminal => uint256) public override totalFeeVolumeOf;

    /// @notice The currency-denominated amount of funds that a project has already paid out from its payout limit
    /// during the current ruleset for each terminal, in terms of the payout limit's currency.
    /// @dev Increases as projects pay out funds.
    /// @dev The used payout limit is represented as a fixed point number with the same amount of decimals as the
    /// terminal it applies to.
    /// @custom:param terminal The terminal the payout limit applies to.
    /// @custom:param projectId The ID of the project to get the used payout limit of.
    /// @custom:param token The token the payout limit applies to in the terminal.
    /// @custom:param rulesetCycleNumber The cycle number of the ruleset the payout limit was used during.
    /// @custom:param currency The currency the payout limit is in terms of.
    mapping(
        address terminal
            => mapping(
            uint256 projectId
                => mapping(address token => mapping(uint256 rulesetCycleNumber => mapping(uint256 currency => uint256)))
        )
    )
        public
        override usedPayoutLimitOf;

    /// @notice The currency-denominated amounts of funds that a project has used from its surplus allowance during the
    /// current ruleset for each terminal, in terms of the surplus allowance's currency.
    /// @dev Increases as projects use their allowance.
    /// @dev The used surplus allowance is represented as a fixed point number with the same amount of decimals as the
    /// terminal it applies to.
    /// @dev Surplus allowance usage is keyed by `ruleset.id`, not cycle number. Implicit cycle progression
    /// (duration-based auto-cycling) does not reset allowance — this is by design. Projects must queue a new ruleset
    /// to get a fresh allowance.
    /// @custom:param terminal The terminal the surplus allowance applies to.
    /// @custom:param projectId The ID of the project to get the used surplus allowance of.
    /// @custom:param token The token the surplus allowance applies to in the terminal.
    /// @custom:param rulesetId The ID of the ruleset the surplus allowance was used during.
    /// @custom:param currency The currency the surplus allowance is in terms of.
    mapping(
        address terminal
            => mapping(
            uint256 projectId
                => mapping(address token => mapping(uint256 rulesetId => mapping(uint256 currency => uint256)))
        )
    )
        public
        override usedSurplusAllowanceOf;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The accounting context for a terminal's project token.
    /// @custom:param terminal The terminal the accounting context applies to.
    /// @custom:param projectId The ID of the project.
    /// @custom:param token The token to get the accounting context for.
    mapping(address terminal => mapping(uint256 projectId => mapping(address token => JBAccountingContext))) internal
        _accountingContextForTokenOf;

    /// @notice A list of accounting contexts for each terminal's project.
    /// @custom:param terminal The terminal the accounting contexts apply to.
    /// @custom:param projectId The ID of the project.
    mapping(address terminal => mapping(uint256 projectId => JBAccountingContext[])) internal _accountingContextsOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param prices A contract that exposes price feeds.
    /// @param rulesets A contract storing and managing project rulesets.
    constructor(IJBDirectory directory, IJBPrices prices, IJBRulesets rulesets) {
        DIRECTORY = directory;
        PRICES = prices;
        RULESETS = rulesets;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Registers which tokens a terminal can accept for a project, along with their decimal precision and
    /// currency. Called by the terminal when `addAccountingContextsFor` is invoked.
    /// @dev Uses `msg.sender` as the terminal address. Reverts if the current ruleset disallows adding contexts.
    /// @param projectId The ID of the project.
    /// @param contexts The accounting contexts to record.
    function recordAccountingContextOf(uint256 projectId, JBAccountingContext[] calldata contexts) external override {
        // Get a reference to the project's current ruleset.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Make sure that if there's a ruleset, it allows adding accounting contexts.
        if (ruleset.id != 0 && !ruleset.allowAddAccountingContext()) {
            revert JBTerminalStore_AddingAccountingContextNotAllowed({
                projectId: projectId, rulesetId: ruleset.id, terminal: msg.sender
            });
        }

        // Record each accounting context.
        for (uint256 i; i < contexts.length;) {
            JBAccountingContext calldata context = contexts[i];

            // Make sure the token accounting context isn't already set.
            if (_accountingContextForTokenOf[msg.sender][projectId][context.token].token != address(0)) {
                revert JBTerminalStore_AccountingContextAlreadySet({token: context.token});
            }

            // Keep track of a flag indicating if we know the provided decimals are incorrect.
            bool knownInvalidDecimals;
            uint256 expectedDecimals;

            // Check if the token is the native token and has the correct decimals.
            if (context.token == JBConstants.NATIVE_TOKEN && context.decimals != 18) {
                knownInvalidDecimals = true;
                expectedDecimals = 18;
            } else if (context.token != JBConstants.NATIVE_TOKEN && context.token.code.length > 0) {
                try IERC20Metadata(context.token).decimals() returns (uint8 decimals) {
                    if (context.decimals != decimals) {
                        knownInvalidDecimals = true;
                        expectedDecimals = decimals;
                    }
                } catch {
                    // The token didn't support `decimals`.
                    // @dev Non-standard ERC20s that revert on `decimals()` will bypass decimal validation.
                    // The caller is responsible for providing the correct decimals for such tokens.
                    knownInvalidDecimals = false;
                }
            }

            // Make sure the decimals are correct.
            if (knownInvalidDecimals) {
                revert JBTerminalStore_AccountingContextDecimalsMismatch({
                    token: context.token, providedDecimals: context.decimals, expectedDecimals: expectedDecimals
                });
            }

            // Make sure the currency is non-zero.
            if (context.currency == 0) revert JBTerminalStore_ZeroAccountingContextCurrency({token: context.token});

            // Store the accounting context.
            _accountingContextForTokenOf[msg.sender][projectId][context.token] = context;

            // Add the context to the list.
            _accountingContextsOf[msg.sender][projectId].push(context);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Records funds added to a project's balance.
    /// @param projectId The ID of the project which funds are added to the balance of.
    /// @param token The token to add to the balance.
    /// @param amount The amount of terminal tokens added, as a fixed point number with the same amount of decimals as
    /// its relative terminal.
    function recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) external override {
        // Increment the balance.
        balanceOf[msg.sender][projectId][token] = balanceOf[msg.sender][projectId][token] + amount;
    }

    /// @notice Records a cash out — calculates how many terminal tokens a holder receives for burning project tokens.
    /// @dev Uses the data hook if configured, otherwise applies the bonding curve formula based on cash out tax rate,
    /// surplus, and supply. The terminal calls this before actually burning tokens and transferring funds.
    /// @param holder The account that is cashing out tokens.
    /// @param projectId The ID of the project to cash out from.
    /// @param cashOutCount The number of project tokens to cash out, as supplied by the caller and later burned by the
    /// terminal, as a fixed point number with 18 decimals.
    /// @param tokenToReclaim The token to reclaim by the cash out.
    /// @param beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address. Passed through to data
    /// hooks so they can skip their own fees when value stays in the protocol (e.g. project-to-project routing).
    /// @param metadata Bytes to send to the data hook, if the project's current ruleset specifies one.
    /// @return ruleset The ruleset during the cash out was made during, as a `JBRuleset` struct. This ruleset will
    /// have a cash out tax rate provided by the cash out hook if applicable.
    /// @return reclaimAmount The amount of tokens reclaimed from the terminal, as a fixed point number with 18
    /// decimals.
    /// @return cashOutTaxRate The cash out tax rate influencing the reclaim amount.
    /// @return hookSpecifications A list of cash out hooks, including data and amounts to send to them. The terminal
    /// should fulfill these specifications.
    function recordCashOutFor(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
        bytes memory metadata
    )
        external
        override
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = _computeCashOutFrom({
            terminal: msg.sender,
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });

        // Compute the total amount to subtract from the project's balance.
        uint256 balanceDiff = reclaimAmount;

        if (hookSpecifications.length != 0) {
            uint256 numberOfSpecifications = hookSpecifications.length;
            for (uint256 i; i < numberOfSpecifications;) {
                uint256 specificationAmount = hookSpecifications[i].amount;
                if (specificationAmount != 0) {
                    balanceDiff += specificationAmount;
                }
                unchecked {
                    ++i;
                }
            }
        }

        // Cache the balance slot to avoid redundant storage reads.
        uint256 currentBalance = balanceOf[msg.sender][projectId][tokenToReclaim];

        // The amount being reclaimed must be within the project's balance.
        if (balanceDiff > currentBalance) {
            revert JBTerminalStore_InadequateTerminalStoreBalance({amount: balanceDiff, balance: currentBalance});
        }

        // Remove the reclaimed funds from the project's balance.
        if (balanceDiff != 0) {
            unchecked {
                balanceOf[msg.sender][projectId][tokenToReclaim] = currentBalance - balanceDiff;
            }
        }
    }

    /// @notice Credit a referral project with a fee payment amount routed through `msg.sender` (the calling terminal).
    /// @dev Called by `JBMultiTerminal._pay` after a payment lands on the fee project. Permissionless: writes are
    /// scoped to `msg.sender`'s slots so an arbitrary caller can only pollute their own buckets — off-chain
    /// consumers should filter on known terminal addresses. The amount is normalized to `NATIVE_TOKEN` units
    /// (18 decimals) here in the store (where `PRICES` is available) so all credits share a common denominator.
    /// @param referralProjectId The referral project to credit.
    /// @param amount The fee amount paid by the originating fee-take call (raw value, decimals, currency).
    function recordFeeReferralCreditOf(uint256 referralProjectId, JBTokenAmount calldata amount) external override {
        _creditFeeReferral({
            referralProjectId: referralProjectId,
            amount: _normalizeToNativeTokenUnits({
                value: amount.value, decimals: amount.decimals, currency: amount.currency
            })
        });
    }

    /// @notice Records a payment — calculates how many project tokens to mint based on the payment amount and the
    /// current ruleset's weight. Uses the data hook if configured, otherwise mints proportionally.
    /// @dev Called by the terminal after accepting funds. Updates the project's recorded balance.
    /// @param payer The address that made the payment to the terminal.
    /// @param amount The amount of tokens to pay. Includes the token paid, their value, the number of
    /// decimals included, and the currency of the amount.
    /// @param projectId The ID of the project to pay.
    /// @param beneficiary The address that should be the beneficiary of anything the payment yields (including project
    /// tokens minted by the payment).
    /// @param metadata Bytes to send to the data hook, if the project's current ruleset specifies one.
    /// @return ruleset The ruleset the payment was made during, as a `JBRuleset` struct.
    /// @return tokenCount The number of project tokens that were minted, as a fixed point number with 18 decimals.
    /// @return hookSpecifications A list of pay hooks, including data and amounts to send to them. The terminal should
    /// fulfill these specifications.
    function recordPaymentFrom(
        address payer,
        JBTokenAmount calldata amount,
        uint256 projectId,
        address beneficiary,
        bytes calldata metadata
    )
        external
        override
        returns (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications)
    {
        uint256 balanceDiff;
        (ruleset, tokenCount, hookSpecifications, balanceDiff) = _computePayFrom({
            terminal: msg.sender,
            payer: payer,
            amount: amount,
            projectId: projectId,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Add the correct balance difference to the token balance of the project.
        if (balanceDiff != 0) {
            // Cache the balance slot to avoid redundant storage reads.
            uint256 currentBalance = balanceOf[msg.sender][projectId][amount.token];
            balanceOf[msg.sender][projectId][amount.token] = currentBalance + balanceDiff;
        }
    }

    /// @notice Normalize a fee-token amount to `JBConstants.NATIVE_TOKEN` units at 18 decimals.
    /// @dev Two-step: first adjust decimals to 18 via `JBFixedPointNumber.adjustDecimals`, then convert currency
    /// via `PRICES.pricePerUnitOf` using the fee project's price feeds. If no price feed exists for the pair, the
    /// `try` block catches the revert and the credit is silently skipped — the payment itself still succeeds.
    /// @param value The amount in the source token's native decimals.
    /// @param decimals The source token's decimals.
    /// @param currency The source token's accounting-context currency (`uint32(uint160(token))`).
    /// @return normalized The amount expressed in `NATIVE_TOKEN` units (18 decimals), or 0 if conversion failed.
    function _normalizeToNativeTokenUnits(
        uint256 value,
        uint256 decimals,
        uint256 currency
    )
        private
        view
        returns (uint256 normalized)
    {
        // Adjust the source amount up/down to 18 decimals so all credits share a common precision.
        normalized = decimals == _MAX_FIXED_POINT_FIDELITY
            ? value
            : JBFixedPointNumber.adjustDecimals({
                value: value, decimals: decimals, targetDecimals: _MAX_FIXED_POINT_FIDELITY
            });

        if (normalized == 0 || currency == JBConstants.NATIVE_TOKEN_CURRENCY) return normalized;

        // Convert from the source currency to NATIVE_TOKEN via the fee project's price feeds. A missing feed
        // reverts inside `PRICES.pricePerUnitOf` — caught here so the payment is not blocked.
        try PRICES.pricePerUnitOf({
            projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID,
            pricingCurrency: currency,
            unitCurrency: JBConstants.NATIVE_TOKEN_CURRENCY,
            decimals: _MAX_FIXED_POINT_FIDELITY
        }) returns (
            uint256 price
        ) {
            normalized = price == 0
                ? 0
                : mulDiv({x: normalized, y: 10 ** _MAX_FIXED_POINT_FIDELITY, denominator: price});
        } catch {
            normalized = 0;
        }
    }

    /// @notice Credit a referral project with a fee payment amount. Internal counterpart of
    /// `recordFeeReferralCreditOf` — both write to the same slots and emit the same event.
    /// @dev No-op when `referralProjectId == 0` or `amount == 0`.
    /// @param referralProjectId The referral project to credit.
    /// @param amount The fee amount to credit.
    function _creditFeeReferral(uint256 referralProjectId, uint256 amount) private {
        if (referralProjectId == 0 || amount == 0) return;

        feeVolumeByReferralOf[msg.sender][referralProjectId] += amount;
        uint256 newTotal = totalFeeVolumeOf[msg.sender] + amount;
        totalFeeVolumeOf[msg.sender] = newTotal;

        emit ReferralCredit({
            terminal: msg.sender, referralProjectId: referralProjectId, amount: amount, newTotal: newTotal
        });
    }

    /// @notice Records a payout — decrements the project's balance and enforces the payout limit. Called by the
    /// terminal during `sendPayoutsOf`.
    /// @dev Reverts if the total payouts for this cycle would exceed the ruleset's payout limit. The balance is
    /// decremented before validation (safe because the entire tx reverts atomically on failure).
    /// @param projectId The ID of the project that is paying out funds.
    /// @param token The token to pay out.
    /// @param amount The amount to pay out (use from the payout limit), as a fixed point number.
    /// @param currency The currency of the `amount`. This must match the project's current ruleset's currency.
    /// @return ruleset The ruleset the payout was made during, as a `JBRuleset` struct.
    /// @return amountPaidOut The amount of terminal tokens paid out, as a fixed point number with the same amount of
    /// decimals as its relative terminal.
    function recordPayoutFor(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency
    )
        external
        override
        returns (JBRuleset memory ruleset, uint256 amountPaidOut)
    {
        // Look up the accounting context from storage.
        JBAccountingContext memory accountingContext = _accountingContextForTokenOf[msg.sender][projectId][token];

        // Get a reference to the project's current ruleset.
        ruleset = RULESETS.currentOf(projectId);

        // Get the payout limit for this currency.
        uint256 payoutLimit = IJBController(address(DIRECTORY.controllerOf(projectId))).FUND_ACCESS_LIMITS()
            .payoutLimitOf({
            projectId: projectId, rulesetId: ruleset.id, terminal: msg.sender, token: token, currency: currency
        });

        // Get the already-used payout limit for this cycle.
        uint256 usedPayoutLimit = usedPayoutLimitOf[msg.sender][projectId][token][ruleset.cycleNumber][currency];

        // Cap the amount to the remaining payout limit instead of reverting.
        uint256 remainingPayoutLimit = payoutLimit > usedPayoutLimit ? payoutLimit - usedPayoutLimit : 0;
        if (amount > remainingPayoutLimit) {
            amount = remainingPayoutLimit;
        }

        // If nothing can be paid out, return early with zero.
        if (amount == 0) {
            return (ruleset, 0);
        }

        // Convert the amount to the balance's currency.
        amountPaidOut = (currency == accountingContext.currency)
            ? amount
            : mulDiv({
                x: amount,
                y: 10 ** _MAX_FIXED_POINT_FIDELITY, // Use `_MAX_FIXED_POINT_FIDELITY` to keep as much of the
                // `_amount`'s fidelity as possible when converting.
                denominator: PRICES.pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: currency,
                    unitCurrency: accountingContext.currency,
                    decimals: _MAX_FIXED_POINT_FIDELITY
                })
            });

        // If cross-currency conversion rounded to zero, return without consuming any payout limit. Otherwise a
        // permissionless caller could repeatedly request sub-unit payouts to drain the cycle's payout limit
        // without moving any funds.
        if (amountPaidOut == 0) {
            return (ruleset, 0);
        }

        // Cache the balance slot to avoid redundant storage reads.
        uint256 currentBalance = balanceOf[msg.sender][projectId][token];

        // The amount being paid out must be available.
        if (amountPaidOut > currentBalance) {
            revert JBTerminalStore_InadequateTerminalStoreBalance({amount: amountPaidOut, balance: currentBalance});
        }

        // Removed the paid out funds from the project's token balance.
        unchecked {
            balanceOf[msg.sender][projectId][token] = currentBalance - amountPaidOut;
        }

        // Store the new used payout limit.
        usedPayoutLimitOf[msg.sender][projectId][token][ruleset.cycleNumber][currency] = usedPayoutLimit + amount;
    }

    /// @notice Records a terminal migration — zeros out the project's balance and returns the amount moved to
    /// the new terminal. The current ruleset must allow terminal migration.
    /// @param projectId The ID of the project to migrate.
    /// @param token The token to migrate.
    /// @return balance The project's current balance (the amount that will migrate), as a fixed point number with the
    /// same amount of decimals as its relative terminal.
    function recordTerminalMigration(uint256 projectId, address token) external override returns (uint256 balance) {
        // Get a reference to the project's current ruleset.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Terminal migration must be allowed.
        if (!ruleset.allowTerminalMigration()) {
            revert JBTerminalStore_TerminalMigrationNotAllowed({projectId: projectId, rulesetId: ruleset.id});
        }

        // Return the current balance, which is the amount being migrated.
        balance = balanceOf[msg.sender][projectId][token];

        // Set the balance to 0.
        balanceOf[msg.sender][projectId][token] = 0;
    }

    /// @notice Records a surplus allowance withdrawal — takes funds from the project's surplus (the balance above
    /// payout limits) and enforces the surplus allowance cap.
    /// @dev Called by the terminal during `useAllowanceOf`. Unlike payouts, surplus withdrawals go directly to a
    /// beneficiary rather than through splits.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param token The token whose balances should contribute to the surplus allowance to reclaim from.
    /// @param amount The amount to use from the surplus allowance, as a fixed point number.
    /// @param currency The currency of the `amount`. Must match the currency of the surplus allowance.
    /// @return ruleset The ruleset the surplus allowance applies to, as a `JBRuleset` struct.
    /// @return usedAmount The amount of terminal tokens used, as a fixed point number with the same amount of decimals
    /// as its relative terminal.
    function recordUsedAllowanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency
    )
        external
        override
        returns (JBRuleset memory ruleset, uint256 usedAmount)
    {
        // Look up the accounting context from storage.
        JBAccountingContext memory accountingContext = _accountingContextForTokenOf[msg.sender][projectId][token];

        // Get a reference to the project's current ruleset.
        ruleset = RULESETS.currentOf(projectId);

        // Convert the amount to this store's terminal's token.
        usedAmount = currency == accountingContext.currency
            ? amount
            : mulDiv({
                x: amount,
                y: 10 ** _MAX_FIXED_POINT_FIDELITY, // Use `_MAX_FIXED_POINT_FIDELITY` to keep as much of the
                // `amount`'s fidelity as possible when converting.
                denominator: PRICES.pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: currency,
                    unitCurrency: accountingContext.currency,
                    decimals: _MAX_FIXED_POINT_FIDELITY
                })
            });

        // Set the token being used as the only one to look for surplus within.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = accountingContext;

        uint256 surplus = _surplusFrom({
            terminal: msg.sender,
            projectId: projectId,
            accountingContexts: accountingContexts,
            ruleset: ruleset,
            targetDecimals: accountingContext.decimals,
            targetCurrency: accountingContext.currency
        });

        // The amount being used must be available in the surplus.
        if (usedAmount > surplus) revert JBTerminalStore_InadequateTerminalStoreBalance(usedAmount, surplus);

        // Get a reference to the new used surplus allowance for this ruleset ID.
        uint256 newUsedSurplusAllowanceOf =
            usedSurplusAllowanceOf[msg.sender][projectId][token][ruleset.id][currency] + amount;

        // There must be sufficient surplus allowance available.
        // Validate BEFORE writing to storage to avoid wasting gas on SSTORE when the tx will revert.
        uint256 surplusAllowance = IJBController(address(DIRECTORY.controllerOf(projectId))).FUND_ACCESS_LIMITS()
            .surplusAllowanceOf({
            projectId: projectId, rulesetId: ruleset.id, terminal: msg.sender, token: token, currency: currency
        });

        // Make sure the new used amount is within the allowance.
        if (newUsedSurplusAllowanceOf > surplusAllowance || surplusAllowance == 0) {
            revert JBTerminalStore_InadequateControllerAllowance({
                amount: newUsedSurplusAllowanceOf, allowance: surplusAllowance
            });
        }

        // Cache the balance slot to avoid redundant storage reads.
        uint256 currentBalance = balanceOf[msg.sender][projectId][token];

        // Update the project's balance.
        balanceOf[msg.sender][projectId][token] = currentBalance - usedAmount;

        // Store the incremented value.
        usedSurplusAllowanceOf[msg.sender][projectId][token][ruleset.id][currency] = newUsedSurplusAllowanceOf;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns the accounting context for a terminal's project token.
    /// @param terminal The terminal the accounting context applies to.
    /// @param projectId The ID of the project.
    /// @param token The token to get the accounting context for.
    /// @return The accounting context.
    function accountingContextOf(
        address terminal,
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        return _accountingContextForTokenOf[terminal][projectId][token];
    }

    /// @notice Returns all accounting contexts for a terminal's project.
    /// @param terminal The terminal the accounting contexts apply to.
    /// @param projectId The ID of the project.
    /// @return The accounting contexts.
    function accountingContextsOf(
        address terminal,
        uint256 projectId
    )
        external
        view
        override
        returns (JBAccountingContext[] memory)
    {
        return _accountingContextsOf[terminal][projectId];
    }

    /// @notice Returns the number of surplus terminal tokens that would be reclaimed by cashing out a given project's
    /// tokens based on its current ruleset and the given total project token supply and total terminal token surplus.
    /// @param projectId The ID of the project whose project tokens would be cashed out.
    /// @param cashOutCount The number of project tokens that would be cashed out, as a fixed point number with 18
    /// decimals.
    /// @param totalSupply The total project token supply, as a fixed point number with 18 decimals.
    /// @param surplus The total terminal token surplus amount, as a fixed point number.
    /// @return The number of surplus terminal tokens that would be reclaimed, as a fixed point number with the same
    /// number of decimals as the provided `surplus`.
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 surplus
    )
        external
        view
        override
        returns (uint256)
    {
        // If there's no surplus, nothing can be reclaimed.
        if (surplus == 0) return 0;

        // Can't cash out more tokens than are in the total supply.
        if (cashOutCount > totalSupply) return 0;

        // Get a reference to the project's current ruleset.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Return the amount of surplus terminal tokens that would be reclaimed.
        // NOTE: This view does not run the data hook, so it cannot reflect a cross-chain totalSupply override.
        // For accurate omnichain estimates, use the data hook or simulate recordCashOutFor.
        return JBCashOuts.cashOutFrom({
            surplus: surplus,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            cashOutTaxRate: ruleset.cashOutTaxRate()
        });
    }

    /// @notice Gets the current surplus amount for a project across specified terminals and tokens.
    /// @param projectId The ID of the project to get surplus for.
    /// @param terminals The terminals to include. If empty, all project terminals are used.
    /// @param tokens The tokens to include. If empty, all tokens per terminal are used.
    /// @param decimals The number of decimals to expect in the resulting fixed point number.
    /// @param currency The currency the resulting amount should be in terms of.
    /// @return surplus The current surplus amount.
    function currentSurplusOf(
        uint256 projectId,
        IJBTerminal[] calldata terminals,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256)
    {
        return _currentSurplusOf({
            projectId: projectId, terminals: terminals, tokens: tokens, decimals: decimals, currency: currency
        });
    }

    /// @notice Returns the number of surplus terminal tokens that would be reclaimed by cashing out a given number of
    /// tokens across all of a project's terminals using all accounting contexts.
    /// @param projectId The ID of the project whose tokens would be cashed out.
    /// @param cashOutCount The number of tokens that would be cashed out, as a fixed point number with 18 decimals.
    /// @param decimals The number of decimals to include in the resulting fixed point number.
    /// @param currency The currency that the resulting number will be in terms of.
    /// @return The amount of surplus terminal tokens that would be reclaimed by cashing out `cashOutCount` tokens.
    function currentTotalReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256)
    {
        return currentReclaimableSurplusOf({
            projectId: projectId,
            cashOutCount: cashOutCount,
            terminals: new IJBTerminal[](0),
            tokens: new address[](0),
            decimals: decimals,
            currency: currency
        });
    }

    /// @notice Gets the current surplus amount for a specified project across all terminals.
    /// @param projectId The ID of the project to get the total surplus for.
    /// @param decimals The number of decimals that the fixed point surplus should include.
    /// @param currency The currency that the total surplus should be in terms of.
    /// @return The current total surplus amount that the project has across all terminals.
    function currentTotalSurplusOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256)
    {
        return _currentSurplusOf({
            projectId: projectId,
            terminals: new IJBTerminal[](0),
            tokens: new address[](0),
            decimals: decimals,
            currency: currency
        });
    }

    /// @notice Simulates a cash out without modifying state.
    /// @dev Invokes data hooks if configured, but skips the balance sufficiency check (balance may change between
    /// preview and execution).
    /// @param terminal The terminal to simulate the cash out from.
    /// @param holder The address cashing out.
    /// @param projectId The ID of the project to cash out from.
    /// @param cashOutCount The number of project tokens to cash out.
    /// @param tokenToReclaim The token to reclaim.
    /// @param beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address.
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return reclaimAmount The amount that would be reclaimed.
    /// @return cashOutTaxRate The cash out tax rate that would be applied.
    /// @return hookSpecifications Any cash out hook specifications from the data hook.
    function previewCashOutFrom(
        address terminal,
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
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
        (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications) = _computeCashOutFrom({
            terminal: terminal,
            holder: holder,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryIsFeeless: beneficiaryIsFeeless,
            metadata: metadata
        });
    }

    /// @notice Simulates a payment without modifying state.
    /// @dev Invokes data hooks if configured. Returns the same token count and hook specifications that
    /// `recordPaymentFrom` would produce.
    /// @param terminal The terminal to simulate the payment from.
    /// @param payer The address of the payer.
    /// @param amount The amount to pay.
    /// @param projectId The ID of the project to pay.
    /// @param beneficiary The address to mint project tokens to.
    /// @param metadata Extra data to pass along to the data hook.
    /// @return ruleset The project's current ruleset.
    /// @return tokenCount The number of project tokens that would be minted, including reserved tokens.
    /// @return hookSpecifications Any pay hook specifications from the data hook.
    function previewPayFrom(
        address terminal,
        address payer,
        JBTokenAmount memory amount,
        uint256 projectId,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        override
        returns (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications)
    {
        (ruleset, tokenCount, hookSpecifications,) = _computePayFrom({
            terminal: terminal,
            payer: payer,
            amount: amount,
            projectId: projectId,
            beneficiary: beneficiary,
            metadata: metadata
        });
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the number of surplus terminal tokens that would be reclaimed from terminals by cashing out a
    /// given number of tokens, considering only specific tokens.
    /// @param projectId The ID of the project whose tokens would be cashed out.
    /// @param cashOutCount The number of tokens that would be cashed out, as a fixed point number with 18 decimals.
    /// @param terminals The terminals that would be cashed out from. If this is an empty array, surplus within all
    /// the project's terminals are considered.
    /// @param tokens The tokens to include in the surplus calculation.
    /// @param decimals The number of decimals to include in the resulting fixed point number.
    /// @param currency The currency that the resulting number will be in terms of.
    /// @return The amount of surplus terminal tokens that would be reclaimed by cashing out `cashOutCount`
    /// tokens.
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        IJBTerminal[] memory terminals,
        address[] memory tokens,
        uint256 decimals,
        uint256 currency
    )
        public
        view
        override
        returns (uint256)
    {
        // Fetch the current ruleset once — used for both surplus calculation and cash out tax rate.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Aggregate surplus across the terminals, optionally filtered by the specified tokens.
        uint256 currentSurplus = _currentSurplusOf({
            projectId: projectId,
            terminals: terminals,
            tokens: tokens,
            decimals: decimals,
            currency: currency,
            ruleset: ruleset
        });

        // If there's no surplus, nothing can be reclaimed.
        if (currentSurplus == 0) return 0;

        // Get the project token's total supply.
        uint256 totalSupply =
            IJBController(address(DIRECTORY.controllerOf(projectId))).totalTokenSupplyWithReservedTokensOf(projectId);

        // Can't cash out more tokens than are in the total supply.
        if (cashOutCount > totalSupply) return 0;

        // Return the amount of surplus terminal tokens that would be reclaimed.
        // NOTE: This view does not run the data hook, so it cannot reflect a cross-chain totalSupply override.
        // For accurate omnichain estimates, use the data hook or simulate recordCashOutFor.
        return JBCashOuts.cashOutFrom({
            surplus: currentSurplus,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            cashOutTaxRate: ruleset.cashOutTaxRate()
        });
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Calls the data hook, validates noop specifications, and computes the bonding curve reclaim amount.
    /// @dev Extracted from `_computeCashOutFrom` to keep it under the EVM stack depth limit (16 slots).
    /// @param ruleset The current ruleset (used to resolve the data hook address).
    /// @param context The fully-populated cash out context to forward to the data hook.
    /// @param surplus The locally available surplus (used as a cap — can't reclaim more than what's on-chain here).
    /// @return reclaimAmount The amount of surplus tokens reclaimable after the bonding curve and cap.
    /// @return cashOutTaxRate The cash out tax rate returned by the data hook.
    /// @return hookSpecifications The hook specifications returned by the data hook.
    function _cashOutWithDataHook(
        JBRuleset memory ruleset,
        JBBeforeCashOutRecordedContext memory context,
        uint256 surplus
    )
        internal
        view
        returns (uint256 reclaimAmount, uint256 cashOutTaxRate, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        // Ask the data hook for the effective bonding curve parameters and any hook specifications.
        uint256 effectiveCashOutCount;
        uint256 effectiveTotalSupply;
        uint256 effectiveSurplusValue;
        (cashOutTaxRate, effectiveCashOutCount, effectiveTotalSupply, effectiveSurplusValue, hookSpecifications) =
            IJBRulesetDataHook(ruleset.dataHook()).beforeCashOutRecordedWith(context);

        // Noop specifications are informational only, so they can't also request forwarded funds.
        for (uint256 i; i < hookSpecifications.length;) {
            if (hookSpecifications[i].noop && hookSpecifications[i].amount != 0) {
                revert JBTerminalStore_NoopHookSpecHasAmount({amount: hookSpecifications[i].amount});
            }
            unchecked {
                ++i;
            }
        }

        // Apply the bonding curve to calculate how much of the surplus is reclaimable.
        if (surplus != 0) {
            reclaimAmount = JBCashOuts.cashOutFrom({
                surplus: effectiveSurplusValue,
                cashOutCount: effectiveCashOutCount,
                totalSupply: effectiveTotalSupply,
                cashOutTaxRate: cashOutTaxRate
            });

            // Cap at local surplus — can't reclaim more than what's locally available.
            if (reclaimAmount > surplus) reclaimAmount = surplus;
        }
    }

    /// @notice Computes cash out results without writing state.
    /// @param terminal The terminal recording the cash out.
    /// @param holder The account that is cashing out tokens.
    /// @param projectId The ID of the project to cash out from.
    /// @param cashOutCount The number of project tokens to cash out.
    /// @param tokenToReclaim The token to reclaim.
    /// @param beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address.
    /// @param metadata Bytes to send to the data hook.
    /// @return ruleset The ruleset during the cash out.
    /// @return reclaimAmount The amount of tokens reclaimed.
    /// @return cashOutTaxRate The cash out tax rate applied.
    /// @return hookSpecifications Cash out hook specifications from the data hook.
    function _computeCashOutFrom(
        address terminal,
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        bool beneficiaryIsFeeless,
        bytes memory metadata
    )
        internal
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Get a reference to the project's current ruleset.
        ruleset = RULESETS.currentOf(projectId);

        // Get the accounting context for the token being reclaimed.
        JBAccountingContext memory accountingContext = _accountingContextForTokenOf[terminal][projectId][tokenToReclaim];

        // Get the project's current surplus across ALL terminals and ALL tokens.
        uint256 surplus = JBSurplus.currentSurplusOf({
            projectId: projectId,
            terminals: DIRECTORY.terminalsOf(projectId),
            tokens: new address[](0),
            decimals: accountingContext.decimals,
            currency: accountingContext.currency
        });

        // Get the total number of outstanding project tokens.
        uint256 effectiveTotalSupply =
            IJBController(address(DIRECTORY.controllerOf(projectId))).totalTokenSupplyWithReservedTokensOf(projectId);

        // Can't cash out more tokens than are in the supply.
        if (cashOutCount > effectiveTotalSupply) {
            revert JBTerminalStore_InsufficientTokens({count: cashOutCount, totalSupply: effectiveTotalSupply});
        }

        // SECURITY NOTE: The data hook has absolute control over cash-out pricing.
        // It can set effectiveTotalSupply, effectiveCashOutCount, and cashOutTaxRate to arbitrary values,
        // completely overriding the terminal's bonding curve math. For example, setting
        // effectiveTotalSupply = surplus makes reclaimAmount = effectiveCashOutCount, bypassing the curve.
        // The terminal still burns the caller-supplied cashOutCount after pricing completes.
        // Project owners must review their data hooks with the same rigor as the terminal.

        // If the ruleset has a data hook which is enabled for cash outs, use it to derive a claim amount and memo.
        if (ruleset.useDataHookForCashOut() && ruleset.dataHook() != address(0)) {
            // Build the cash out context field-by-field — the struct has 11 fields, too many for a literal.
            JBBeforeCashOutRecordedContext memory context;
            context.terminal = terminal;
            context.holder = holder;
            context.projectId = projectId;
            context.rulesetId = ruleset.id;
            context.cashOutCount = cashOutCount;
            context.totalSupply = effectiveTotalSupply;
            context.surplus = JBTokenAmount({
                token: accountingContext.token,
                value: surplus,
                decimals: accountingContext.decimals,
                currency: accountingContext.currency
            });
            context.scopeCashOutsToLocalBalances = ruleset.scopeCashOutsToLocalBalances();
            context.cashOutTaxRate = ruleset.cashOutTaxRate();
            context.beneficiaryIsFeeless = beneficiaryIsFeeless;
            context.metadata = metadata;

            // Hook call + bonding curve in a helper to stay under the stack depth limit.
            (reclaimAmount, cashOutTaxRate, hookSpecifications) =
                _cashOutWithDataHook({ruleset: ruleset, context: context, surplus: surplus});
        } else {
            cashOutTaxRate = ruleset.cashOutTaxRate();

            // Apply the bonding curve to calculate how much of the surplus is reclaimable.
            if (surplus != 0) {
                reclaimAmount = JBCashOuts.cashOutFrom({
                    surplus: surplus,
                    cashOutCount: cashOutCount,
                    totalSupply: effectiveTotalSupply,
                    cashOutTaxRate: cashOutTaxRate
                });
            }
        }
    }

    /// @notice Computes payment results without writing state.
    /// @param terminal The terminal recording the payment.
    /// @param payer The address that made the payment.
    /// @param amount The amount of tokens to pay.
    /// @param projectId The ID of the project to pay.
    /// @param beneficiary The beneficiary of the payment.
    /// @param metadata Bytes to send to the data hook.
    /// @return ruleset The ruleset the payment would be made during.
    /// @return tokenCount The number of project tokens that would be minted.
    /// @return hookSpecifications Pay hook specifications from the data hook.
    /// @return balanceDiff The amount that would be added to the project's balance.
    function _computePayFrom(
        address terminal,
        address payer,
        JBTokenAmount memory amount,
        uint256 projectId,
        address beneficiary,
        bytes memory metadata
    )
        internal
        view
        returns (
            JBRuleset memory ruleset,
            uint256 tokenCount,
            JBPayHookSpecification[] memory hookSpecifications,
            uint256 balanceDiff
        )
    {
        // Get a reference to the project's current ruleset.
        ruleset = RULESETS.currentOf(projectId);

        // The project must have a ruleset.
        if (ruleset.cycleNumber == 0) revert JBTerminalStore_RulesetNotFound(projectId);

        // The ruleset must not have payments paused.
        if (ruleset.pausePay()) {
            revert JBTerminalStore_RulesetPaymentPaused({projectId: projectId, rulesetId: ruleset.id});
        }

        // The weight according to which new tokens are to be minted, as a fixed point number with 18 decimals.
        uint256 weight;

        // SECURITY NOTE: The data hook has absolute control over payment token minting.
        // It can return an arbitrary weight (overriding the ruleset's weight) and hook specifications
        // that divert payment funds to external hooks before they reach the project's balance.
        // Project owners must review their data hooks with the same rigor as the terminal.

        // If the ruleset has a data hook enabled for payments, use it to derive a weight and memo.
        if (ruleset.useDataHookForPay() && ruleset.dataHook() != address(0)) {
            // Create the pay context that'll be sent to the data hook.
            JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
                terminal: terminal,
                payer: payer,
                amount: amount,
                projectId: projectId,
                rulesetId: ruleset.id,
                beneficiary: beneficiary,
                weight: ruleset.weight,
                reservedPercent: ruleset.reservedPercent(),
                metadata: metadata
            });

            (weight, hookSpecifications) = IJBRulesetDataHook(ruleset.dataHook()).beforePayRecordedWith(context);
        }
        // Otherwise use the ruleset's weight
        else {
            weight = ruleset.weight;
        }

        // Keep a reference to the amount that should be added to the project's balance.
        balanceDiff = amount.value;

        // Ensure that the specifications have valid amounts.
        for (uint256 i; i < hookSpecifications.length;) {
            if (hookSpecifications[i].noop && hookSpecifications[i].amount != 0) {
                revert JBTerminalStore_NoopHookSpecHasAmount({amount: hookSpecifications[i].amount});
            }

            uint256 specifiedAmount = hookSpecifications[i].amount;

            // Can't send more to hook than was paid.
            if (specifiedAmount != 0) {
                if (specifiedAmount > balanceDiff) {
                    revert JBTerminalStore_InvalidAmountToForwardHook({
                        amount: specifiedAmount, paidAmount: balanceDiff
                    });
                }

                // Decrement the total amount being added to the local balance.
                balanceDiff -= specifiedAmount;
            }
            unchecked {
                ++i;
            }
        }

        // If there's no amount being recorded, there's nothing left to do.
        if (amount.value == 0) return (ruleset, 0, hookSpecifications, 0);

        // If there's no weight, the token count must be 0, so there's nothing left to do.
        if (weight == 0) return (ruleset, 0, hookSpecifications, balanceDiff);

        // If the terminal should base its weight on a currency other than the terminal's currency, determine the
        // factor. The weight is always a fixed point mumber with 18 decimals. To ensure this, the ratio should use the
        // same
        // number of decimals as the `amount`.
        uint256 weightRatio = amount.currency == ruleset.baseCurrency()
            ? 10 ** amount.decimals
            : PRICES.pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: amount.currency,
                unitCurrency: ruleset.baseCurrency(),
                decimals: amount.decimals
            });

        // Find the number of tokens to mint, as a fixed point number with as many decimals as `weight` has.
        tokenCount = mulDiv({x: amount.value, y: weight, denominator: weightRatio});
    }

    /// @notice Gets the current surplus amount for a project across specified terminals and tokens.
    /// @param projectId The ID of the project to get surplus for.
    /// @param terminals The terminals to include. If empty, all project terminals are used.
    /// @param tokens The tokens to include. If empty, all tokens per terminal are used.
    /// @param decimals The number of decimals to expect in the resulting fixed point number.
    /// @param currency The currency the resulting amount should be in terms of.
    /// @return surplus The current surplus amount.
    function _currentSurplusOf(
        uint256 projectId,
        IJBTerminal[] memory terminals,
        address[] memory tokens,
        uint256 decimals,
        uint256 currency
    )
        internal
        view
        returns (uint256 surplus)
    {
        // Fetch the ruleset once and delegate to the overload that accepts it.
        return _currentSurplusOf({
            projectId: projectId,
            terminals: terminals,
            tokens: tokens,
            decimals: decimals,
            currency: currency,
            ruleset: RULESETS.currentOf(projectId)
        });
    }

    /// @notice Gets the current surplus amount for a project across specified terminals and tokens, using a
    /// pre-fetched ruleset.
    /// @dev Use this overload when the caller already has the current ruleset to avoid a redundant
    /// `RULESETS.currentOf()` call.
    /// @param projectId The ID of the project to get surplus for.
    /// @param terminals The terminals to include. If empty, all project terminals are used.
    /// @param tokens The tokens to include. If empty, all tokens per terminal are used.
    /// @param decimals The number of decimals to expect in the resulting fixed point number.
    /// @param currency The currency the resulting amount should be in terms of.
    /// @param ruleset The project's current ruleset.
    /// @return surplus The current surplus amount.
    function _currentSurplusOf(
        uint256 projectId,
        IJBTerminal[] memory terminals,
        address[] memory tokens,
        uint256 decimals,
        uint256 currency,
        JBRuleset memory ruleset
    )
        internal
        view
        returns (uint256 surplus)
    {
        // If specific terminals were provided, use them. Otherwise, get all terminals from the directory.
        IJBTerminal[] memory resolvedTerminals = terminals.length != 0 ? terminals : DIRECTORY.terminalsOf(projectId);

        // Sum surplus across each terminal.
        for (uint256 i; i < resolvedTerminals.length;) {
            address terminal = address(resolvedTerminals[i]);

            // Build the list of accounting contexts to include in this terminal's surplus calculation.
            JBAccountingContext[] memory accountingContexts;
            if (tokens.length != 0) {
                // Specific tokens requested: look up each token's accounting context at this terminal.
                accountingContexts = new JBAccountingContext[](tokens.length);
                for (uint256 j; j < tokens.length;) {
                    accountingContexts[j] = _accountingContextForTokenOf[terminal][projectId][tokens[j]];
                    unchecked {
                        ++j;
                    }
                }
            } else {
                // No token filter: use all accounting contexts registered at this terminal.
                accountingContexts = _accountingContextsOf[terminal][projectId];
            }

            // Add this terminal's surplus (balance minus payout limits) converted to the target decimals/currency.
            surplus += _surplusFrom({
                terminal: terminal,
                projectId: projectId,
                accountingContexts: accountingContexts,
                ruleset: ruleset,
                targetDecimals: decimals,
                targetCurrency: currency
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Gets a project's surplus amount in a terminal as measured by a given ruleset, across multiple accounting
    /// contexts.
    /// @dev This amount changes as the value of the balance changes in relation to the currency used to measure
    /// various payout limits.
    /// @param terminal The terminal to calculate surplus for.
    /// @param projectId The ID of the project to get the surplus for.
    /// @param accountingContexts The accounting contexts of tokens whose balances should contribute to the surplus
    /// calculated.
    /// @param ruleset The ruleset to base the surplus on.
    /// @param targetDecimals The number of decimals to include in the resulting fixed point number.
    /// @param targetCurrency The currency that the reported surplus is expected to be in terms of.
    /// @return surplus The surplus of funds in terms of `targetCurrency`, as a fixed point number with
    /// `targetDecimals` decimals.
    function _surplusFrom(
        address terminal,
        uint256 projectId,
        JBAccountingContext[] memory accountingContexts,
        JBRuleset memory ruleset,
        uint256 targetDecimals,
        uint256 targetCurrency
    )
        internal
        view
        returns (uint256 surplus)
    {
        // Keep a reference to the number of tokens being iterated on.
        uint256 numberOfTokenAccountingContexts = accountingContexts.length;

        // Add payout limits from each token.
        for (uint256 i; i < numberOfTokenAccountingContexts;) {
            uint256 tokenSurplus = _tokenSurplusFrom({
                terminal: terminal,
                projectId: projectId,
                accountingContext: accountingContexts[i],
                ruleset: ruleset,
                targetDecimals: targetDecimals,
                targetCurrency: targetCurrency
            });
            // Increment the surplus with any remaining balance.
            if (tokenSurplus > 0) surplus += tokenSurplus;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get a project's surplus amount of a specific token in a given terminal as measured by a given ruleset
    /// (one specific accounting context).
    /// @dev This amount changes as the value of the balance changes in relation to the currency used to measure
    /// the payout limits.
    /// @param terminal The terminal to calculate surplus for.
    /// @param projectId The ID of the project to get the surplus of.
    /// @param accountingContext The accounting context of the token whose balance should contribute to the surplus
    /// measured.
    /// @param ruleset The ID of the ruleset to base the surplus calculation on.
    /// @param targetDecimals The number of decimals to include in the resulting fixed point number.
    /// @param targetCurrency The currency that the reported surplus is expected to be in terms of.
    /// @return surplus The surplus of funds in terms of `targetCurrency`, as a fixed point number with
    /// `targetDecimals` decimals.
    function _tokenSurplusFrom(
        address terminal,
        uint256 projectId,
        JBAccountingContext memory accountingContext,
        JBRuleset memory ruleset,
        uint256 targetDecimals,
        uint256 targetCurrency
    )
        internal
        view
        returns (uint256 surplus)
    {
        // Keep a reference to the balance.
        surplus = balanceOf[terminal][projectId][accountingContext.token];

        // If needed, adjust the decimals of the fixed point number to have the correct decimals.
        surplus = accountingContext.decimals == targetDecimals
            ? surplus
            : JBFixedPointNumber.adjustDecimals({
                value: surplus, decimals: accountingContext.decimals, targetDecimals: targetDecimals
            });

        // Add up all the balances.
        surplus = (surplus == 0 || accountingContext.currency == targetCurrency)
            ? surplus
            : mulDiv({
                x: surplus,
                y: 10 ** _MAX_FIXED_POINT_FIDELITY, // Use `_MAX_FIXED_POINT_FIDELITY` to keep as much of the
                // `_payoutLimitRemaining`'s fidelity as possible when converting.
                denominator: PRICES.pricePerUnitOf({
                    projectId: projectId,
                    pricingCurrency: accountingContext.currency,
                    unitCurrency: targetCurrency,
                    decimals: _MAX_FIXED_POINT_FIDELITY
                })
            });

        // Get a reference to the payout limit during the ruleset for the token.
        JBCurrencyAmount[] memory payoutLimits = IJBController(address(DIRECTORY.controllerOf(projectId)))
            .FUND_ACCESS_LIMITS()
            .payoutLimitsOf({
            projectId: projectId, rulesetId: ruleset.id, terminal: address(terminal), token: accountingContext.token
        });

        // Keep a reference to the number of payout limits being iterated on.
        uint256 numberOfPayoutLimits = payoutLimits.length;

        // Loop through each payout limit to determine the cumulative normalized payout limit remaining.
        for (uint256 i; i < numberOfPayoutLimits;) {
            JBCurrencyAmount memory payoutLimit = payoutLimits[i];

            // Set the payout limit value to the amount still available to pay out during the ruleset.
            {
                // Saturating subtraction: if a new ruleset activates with a lower payout limit than
                // what was already used under the previous limit, `used` can exceed `amount`. Clamping
                // to zero prevents an underflow revert that would DOS cashouts and surplus views.
                uint256 used = usedPayoutLimitOf[
                    terminal
                ][projectId][accountingContext.token][ruleset.cycleNumber][payoutLimit.currency];
                uint256 remaining = payoutLimit.amount > used ? payoutLimit.amount - used : 0;
                if (remaining > type(uint224).max) revert JBTerminalStore_Uint224Overflow(remaining);
                // forge-lint: disable-next-line(unsafe-typecast)
                payoutLimit.amount = uint224(remaining);
            }

            // Adjust the decimals of the fixed point number if needed to have the correct decimals.
            if (accountingContext.decimals != targetDecimals) {
                uint256 adjusted = JBFixedPointNumber.adjustDecimals({
                    value: payoutLimit.amount, decimals: accountingContext.decimals, targetDecimals: targetDecimals
                });
                if (adjusted > type(uint224).max) revert JBTerminalStore_Uint224Overflow(adjusted);
                // forge-lint: disable-next-line(unsafe-typecast)
                payoutLimit.amount = uint224(adjusted);
            }

            // Convert the `payoutLimit`'s amount to be in terms of the provided currency.
            if (payoutLimit.amount != 0 && payoutLimit.currency != targetCurrency) {
                uint256 converted = mulDiv({
                    x: payoutLimit.amount,
                    y: 10 ** _MAX_FIXED_POINT_FIDELITY, // Use `_MAX_FIXED_POINT_FIDELITY` to keep as much of the
                    // `payoutLimitRemaining`'s fidelity as possible when converting.
                    denominator: PRICES.pricePerUnitOf({
                        projectId: projectId,
                        pricingCurrency: payoutLimit.currency,
                        unitCurrency: targetCurrency,
                        decimals: _MAX_FIXED_POINT_FIDELITY
                    })
                });
                if (converted > type(uint224).max) revert JBTerminalStore_Uint224Overflow(converted);
                // forge-lint: disable-next-line(unsafe-typecast)
                payoutLimit.amount = uint224(converted);
            }

            // Decrement from the balance until it reaches zero.
            if (surplus > payoutLimit.amount) {
                surplus -= payoutLimit.amount;
            } else {
                return 0;
            }
            unchecked {
                ++i;
            }
        }
    }
}
