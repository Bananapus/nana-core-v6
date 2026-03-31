# Core Types, Errors, And Events

Use this file when you need deeper protocol reference material after the repo-local `SKILLS.md` has already routed you to `nana-core-v6`.

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBRuleset` | `cycleNumber (uint48)`, `id (uint48)`, `basedOnId (uint48)`, `start (uint48)`, `duration (uint32)`, `weight (uint112)`, `weightCutPercent (uint32)`, `approvalHook`, `metadata (uint256)` | `currentOf()`, `recordPaymentFrom()`, `recordCashOutFor()` return values |
| `JBRulesetConfig` | `mustStartAtOrAfter (uint48)`, `duration (uint32)`, `weight (uint112)`, `weightCutPercent (uint32)`, `approvalHook`, `metadata (JBRulesetMetadata)`, `splitGroups[]`, `fundAccessLimitGroups[]` | `launchProjectFor()`, `queueRulesetsOf()` input |
| `JBRulesetMetadata` | `reservedPercent (uint16)`, `cashOutTaxRate (uint16)`, `baseCurrency (uint32)`, `pausePay`, `pauseCreditTransfers`, `allowOwnerMinting`, `allowSetCustomToken`, `allowTerminalMigration`, `allowSetTerminals`, `allowSetController`, `allowAddAccountingContext`, `allowAddPriceFeed`, `ownerMustSendPayouts`, `holdFees`, `useTotalSurplusForCashOuts`, `useDataHookForPay`, `useDataHookForCashOut`, `dataHook (address)`, `metadata (uint16)` | Packed into `JBRuleset.metadata` |
| `JBSplit` | `percent (uint32)`, `projectId (uint64)`, `beneficiary (address payable)`, `preferAddToBalance`, `lockedUntil (uint48)`, `hook (IJBSplitHook)` | `splitsOf()`, `setSplitGroupsOf()` |
| `JBSplitGroup` | `groupId (uint256)`, `splits (JBSplit[])` | `JBRulesetConfig.splitGroups`, `setSplitGroupsOf()` |
| `JBAccountingContext` | `token (address)`, `decimals (uint8)`, `currency (uint32)` | Terminal token accounting, surplus/reclaim calculations |
| `JBTokenAmount` | `token (address)`, `decimals (uint8)`, `currency (uint32)`, `value (uint256)` | `recordPaymentFrom()` input |
| `JBTerminalConfig` | `terminal (IJBTerminal)`, `accountingContextsToAccept (JBAccountingContext[])` | `launchProjectFor()`, `launchRulesetsFor()` input |
| `JBCurrencyAmount` | `amount (uint224)`, `currency (uint32)` | Payout limits and surplus allowances |
| `JBFundAccessLimitGroup` | `terminal (address)`, `token (address)`, `payoutLimits (JBCurrencyAmount[])`, `surplusAllowances (JBCurrencyAmount[])` | `JBRulesetConfig.fundAccessLimitGroups` |
| `JBPermissionsData` | `operator (address)`, `projectId (uint64)`, `permissionIds (uint8[])` | `setPermissionsFor()` input |
| `JBFee` | `amount (uint256)`, `beneficiary (address)`, `unlockTimestamp (uint48)` | Held fees in `JBMultiTerminal` |
| `JBSingleAllowance` | `sigDeadline (uint256)`, `amount (uint160)`, `expiration (uint48)`, `nonce (uint48)`, `signature (bytes)` | Permit2 allowance in terminal payments |
| `JBRulesetWithMetadata` | `ruleset (JBRuleset)`, `metadata (JBRulesetMetadata)` | `allRulesetsOf()`, `currentRulesetOf()` return values |
| `JBRulesetWeightCache` | `weight (uint112)`, `weightCutMultiple (uint168)` | Weight caching for long-running rulesets in `JBRulesets` |
| `JBApprovalStatus` (enum) | `Empty`, `Upcoming`, `Active`, `ApprovalExpected`, `Approved`, `Failed` | Approval hook status for queued rulesets |

### Hook Structs

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBBeforePayRecordedContext` | `terminal`, `payer`, `amount (JBTokenAmount)`, `projectId`, `rulesetId`, `beneficiary`, `weight`, `reservedPercent`, `metadata` | `IJBRulesetDataHook.beforePayRecordedWith()` input |
| `JBBeforeCashOutRecordedContext` | `terminal`, `holder`, `projectId`, `rulesetId`, `cashOutCount`, `totalSupply`, `surplus (JBTokenAmount)`, `useTotalSurplus`, `cashOutTaxRate`, `beneficiaryIsFeeless`, `metadata` | `IJBRulesetDataHook.beforeCashOutRecordedWith()` input |
| `JBAfterPayRecordedContext` | `payer`, `projectId`, `rulesetId`, `amount (JBTokenAmount)`, `forwardedAmount (JBTokenAmount)`, `weight`, `newlyIssuedTokenCount`, `beneficiary`, `hookMetadata`, `payerMetadata` | `IJBPayHook.afterPayRecordedWith()` input |
| `JBAfterCashOutRecordedContext` | `holder`, `projectId`, `rulesetId`, `cashOutCount`, `reclaimedAmount (JBTokenAmount)`, `forwardedAmount (JBTokenAmount)`, `cashOutTaxRate`, `beneficiary`, `hookMetadata`, `cashOutMetadata` | `IJBCashOutHook.afterCashOutRecordedWith()` input |
| `JBPayHookSpecification` | `hook (IJBPayHook)`, `noop (bool)`, `amount`, `metadata` | Returned by data hook; specifies which pay hooks to call and how much to forward. `noop = true` means informational-only (callback skipped, amount must be 0). |
| `JBCashOutHookSpecification` | `hook (IJBCashOutHook)`, `noop (bool)`, `amount`, `metadata` | Returned by data hook; specifies which cash out hooks to call and how much to forward. `noop = true` means informational-only (callback skipped, amount must be 0). |
| `JBSplitHookContext` | `token`, `amount`, `decimals`, `projectId`, `groupId`, `split (JBSplit)` | `IJBSplitHook.processSplitWith()` input |

### Constants (`JBConstants`)

| Constant | Value | Meaning |
|----------|-------|---------|
| `NATIVE_TOKEN` | `0x000000000000000000000000000000000000EEEe` | Sentinel address for native ETH |
| `MAX_RESERVED_PERCENT` | `10_000` | 100% reserved (basis points) |
| `MAX_CASH_OUT_TAX_RATE` | `10_000` | 100% tax rate (basis points) |
| `MAX_WEIGHT_CUT_PERCENT` | `1_000_000_000` | 100% weight cut (9-decimal precision) |
| `SPLITS_TOTAL_PERCENT` | `1_000_000_000` | 100% split allocation (9-decimal precision) |
| `MAX_FEE` | `1000` | 100% fee cap (the actual fee is 25 = 2.5%) |

### Currency IDs (`JBCurrencyIds`)

| ID | Currency |
|----|----------|
| `1` | ETH |
| `2` | USD |

### Split Group IDs (`JBSplitGroupIds`)

| ID | Group |
|----|-------|
| `1` | `RESERVED_TOKENS` -- reserved token distribution |

### Special Values

| Value | Context | Meaning |
|-------|---------|---------|
| `weight = 0` | `JBRuleset` / `JBRulesetConfig` | No token issuance for payments. |
| `weight = 1` | `JBRuleset` / `JBRulesetConfig` | Inherit decayed weight from previous ruleset (sentinel). |
| `duration = 0` | `JBRuleset` / `JBRulesetConfig` | Ruleset never expires; must be explicitly replaced by a new queued ruleset (takes effect immediately). |
| `projectId = 0` | `JBPermissionsData` | Wildcard: permission applies to ALL projects. Cannot be combined with ROOT (1). |
| `permissionId = 1` | `JBPermissions` | ROOT: grants all permissions for the scoped project. |
| `rulesetId = 0` | `JBSplits.splitsOf()` | Fallback split group used when no splits are set for a specific ruleset. |
| `projectId = 0` | `JBPrices.addPriceFeedFor()` | Sets a protocol-wide default price feed (owner-only). |

## Gotchas

- `IJBDirectory.controllerOf()` returns `IERC165`, NOT `address` -- must wrap: `address(directory.controllerOf(projectId))`
- `IJBDirectory.primaryTerminalOf()` returns `IJBTerminal`, NOT `address` -- must wrap: `address(directory.primaryTerminalOf(projectId, token))`
- `IJBDirectory.terminalsOf()` returns `IJBTerminal[]`, NOT `address[]`
- `pricePerUnitOf()` is on `IJBPrices`, NOT `IJBController` -- access via `IJBController(ctrl).PRICES().pricePerUnitOf(...)`
- `JBRulesetConfig` fields need explicit casts: `uint48 mustStartAtOrAfter`, `uint32 duration`, `uint112 weight`, `uint32 weightCutPercent`
- Zero-amount `pay{value:0}()` and zero-count `cashOutTokensOf(count=0)` are valid no-ops (mint/return 0)
- `sendPayoutsOf()` reverts when `amount > payout limit` -- does NOT auto-cap
- `IJBTokens.claimTokensFor()` takes 4 args: `(holder, projectId, count, beneficiary)` -- NOT 3
- `JBFeelessAddresses.setFeelessAddress()` NOT `setIsFeelessAddress()` -- the function name omits "Is"
- Named returns auto-return (no explicit `return` statement needed in Solidity)
- `bool` defaults to `false` (correct security default for metadata flags)
- Credits are burned before ERC-20 tokens in `JBTokens.burnFrom()`
- `JBRuleset.weight` is `uint112` with 18 decimals; `JBRuleset.metadata` is packed -- use `JBRulesetMetadataResolver` to unpack
- `JBERC20` is cloned via `Clones.clone()` -- its constructor sets invalid name/symbol; real values set in `initialize()`
- Fee is 2.5% (`FEE = 25` out of `MAX_FEE = 1000`)
- Project #1 is the fee beneficiary project (receives all protocol fees)
- **Fee-free cashout exemption is scoped to fee-free intra-terminal payout amounts.** `_feeFreeSurplusOf[projectId][token]` accumulates the value of fee-free payouts. After any outflow (payouts, `useAllowanceOf`, non-zero-tax or feeless cashouts), the counter is capped at the remaining balance — non-fee-free funds leave first, preserving the fee-free counter. During cashout with `cashOutTaxRate=0`, the 2.5% fee applies only up to this surplus, then depletes. Once consumed, subsequent cashouts are fee-free again. Cleared on terminal migration. This prevents a round-trip fee bypass (intra-terminal payout → zero-tax cashout) while scoping fees precisely to the fee-free inflow.
- `JBProjects` constructor optionally mints project #1 to `feeProjectOwner` -- if `address(0)`, no fee project is created
- `JBMultiTerminal` derives `DIRECTORY` from the provided `store` in its constructor -- not passed directly
- `JBPrices.pricePerUnitOf()` checks project-specific feed, then inverse, then falls back to `DEFAULT_PROJECT_ID = 0`
- `useAllowanceOf()` takes 8 args including `address payable feeBeneficiary` -- do NOT omit it
- Cash out tax rate of 0% = proportional (1:1) redemption; 100% = nothing reclaimable (all surplus locked). Do NOT confuse with a "cash out rate" where 100% means full redemption.
- `cashOutTaxRate` in `JBRulesetMetadata` is `uint16` (max 10,000 basis points), NOT 9-decimal precision
- `reservedPercent` in `JBRulesetMetadata` is `uint16` (max 10,000 basis points), NOT 9-decimal precision
- `weight` in `JBRuleset` is `uint112`, but `weight` in `JBRulesetConfig` is also `uint112` -- both use 18 decimals
- `JBSplits.splitsOf()` falls back to ruleset ID 0 if no splits are set for the given rulesetId
- Held fees are held for 28 days (`_FEE_HOLDING_SECONDS = 2,419,200`) before they can be processed
- `JBController`, `JBMultiTerminal`, `JBProjects`, `JBPrices`, `JBPermissions` all support ERC-2771 meta-transactions
- `JBRulesetMetadataResolver` bit layout: version (4 bits), reservedPercent (16), cashOutTaxRate (16), baseCurrency (32), 14 boolean flags (1 bit each), dataHook address (160), metadata (14)
- `IJBDirectoryAccessControl` has `setControllerAllowed()` and `setTerminalsAllowed()` -- NOT `setControllerAllowedFor()`
- Price feeds are immutable once set in `JBPrices` -- they cannot be replaced or removed
- `JBFundAccessLimits` requires payout limits and surplus allowances to be in strictly increasing currency order to prevent duplicates
- **Empty `fundAccessLimitGroups` = zero payouts, NOT unlimited.** If a ruleset's `fundAccessLimitGroups` array is empty (or has no entry for the terminal/token), `payoutLimitsOf()` returns an empty array → cumulative limit is 0 → `sendPayoutsOf()` reverts on any amount. To allow unlimited payouts, explicitly set a payout limit with `amount: type(uint224).max`.
- **`groupId` (uint256) vs `currency` (uint32) are different types for the same address.** `JBSplitGroup.groupId` is `uint256(uint160(tokenAddress))` while `JBAccountingContext.currency` is `uint32(uint160(tokenAddress))`. These truncate differently — only `NATIVE_TOKEN` (0x000000000000000000000000000000000000EEEe) matches by coincidence. Don't confuse them.
- **`JBAccountingContext.currency` is NOT `baseCurrency` — by design.** `baseCurrency` in ruleset metadata uses abstract real-world values (1 = ETH, 2 = USD) so rulesets are portable across chains — `baseCurrency=2` means "issue X tokens per USD" whether on Ethereum, Base, or Arbitrum. `JBAccountingContext.currency` uses token-derived values (`uint32(uint160(tokenAddress))`) because terminals track specific tokens at specific addresses — e.g. NATIVE_TOKEN = 61166, USDC on Ethereum = 909516616, USDC on Base = 3169378579. `JBPrices` mediates between the two: it converts token-derived currencies to/from abstract currencies (e.g. USDC token → USD concept, NATIVE_TOKEN → ETH concept) so that payout limits denominated in USD work correctly regardless of which token the terminal holds. The separation is what makes cross-chain consistency possible: same ruleset, different terminal accounting per chain.
- **Don't queue multiple identical rulesets.** A ruleset with a `duration` automatically cycles — no need to queue copies. Queue multiple rulesets only when configuration actually changes between periods (e.g. different weight, splits, or limits).
- **`NATIVE_TOKEN` represents a different token on each chain.** `NATIVE_TOKEN` (`0x000000000000000000000000000000000000EEEe`) is the token received via `msg.value` — ETH on Ethereum/Base/Optimism/Arbitrum, CELO on Celo, etc. Its currency is `uint32(uint160(NATIVE_TOKEN))` = 61166. A `JBMatchingPriceFeed` (returns 1:1) is deployed for `ETH:NATIVE_TOKEN` on ETH-native chains so that `baseCurrency=ETH` resolves correctly to the native token. On non-ETH-native chains, a different price feed would be needed.
- **Noop hook specifications are informational-only.** `noop = true` + `amount != 0` reverts with `JBTerminalStore_NoopHookSpecHasAmount`. Data hooks use noop specs to return diagnostics to preview clients without triggering a hook callback. The `noop` flag only suppresses the callback — parameter overrides (weight, tax rate, supply) from the data hook still apply.

## Permission IDs

Quick-reference for the most common `JBPermissionIds` values (from `@bananapus/permission-ids-v6`). Pass these to `JBPermissions.setPermissionsFor()`.

| ID | Name | Gates |
|----|------|-------|
| `1` | `ROOT` | All permissions for the scoped project. Cannot be combined with `projectId = 0`. |
| `2` | `QUEUE_RULESETS` | `JBController.queueRulesetsOf` |
| `3` | `LAUNCH_RULESETS` | `JBController.launchRulesetsFor` |
| `4` | `CASH_OUT_TOKENS` | `JBMultiTerminal.cashOutTokensOf` |
| `5` | `SEND_PAYOUTS` | `JBMultiTerminal.sendPayoutsOf` |
| `6` | `MIGRATE_TERMINAL` | `JBMultiTerminal.migrateBalanceOf` |
| `7` | `SET_PROJECT_URI` | `JBController.setUriOf` |
| `8` | `DEPLOY_ERC20` | `JBController.deployERC20For` |
| `9` | `SET_TOKEN` | `JBController.setTokenFor` |
| `10` | `MINT_TOKENS` | `JBController.mintTokensOf` |
| `11` | `BURN_TOKENS` | `JBController.burnTokensOf` |
| `12` | `CLAIM_TOKENS` | `JBController.claimTokensFor` |
| `13` | `TRANSFER_CREDITS` | `JBController.transferCreditsFrom` |
| `14` | `SET_CONTROLLER` | `JBDirectory.setControllerOf` |
| `15` | `SET_TERMINALS` | `JBDirectory.setTerminalsOf` (can remove primary terminal) |
| `16` | `SET_PRIMARY_TERMINAL` | `JBDirectory.setPrimaryTerminalOf` (also requires `ADD_TERMINALS` if the terminal is not already in the project's list) |
| `17` | `USE_ALLOWANCE` | `JBMultiTerminal.useAllowanceOf` |
| `18` | `SET_SPLIT_GROUPS` | `JBController.setSplitGroupsOf` |
| `19` | `ADD_PRICE_FEED` | `JBController.addPriceFeedFor` |
| `20` | `ADD_ACCOUNTING_CONTEXTS` | `JBMultiTerminal.addAccountingContextsFor` |
| `21` | `SET_TOKEN_METADATA` | `JBController.setTokenMetadataOf` |

IDs 22-33 are used by extension contracts (721 hook, buyback hook, router terminal, suckers).

## Common Errors

Errors an agent is most likely to encounter. All are custom errors (revert with selector).

| Error | Contract | When |
|-------|----------|------|
| `JBPermissioned_Unauthorized` | `JBPermissioned` | Caller lacks the required permission ID for the project. |
| `JBController_RulesetsArrayEmpty` | `JBController` | `launchProjectFor` / `queueRulesetsOf` called with empty rulesets array. |
| `JBController_RulesetsAlreadyLaunched` | `JBController` | `launchRulesetsFor` called on a project that already has rulesets. |
| `JBController_MintNotAllowedAndNotTerminalOrHook` | `JBController` | `mintTokensOf` called but `allowOwnerMinting` is false and caller is not a terminal/hook. |
| `JBController_ZeroTokensToMint` | `JBController` | `mintTokensOf` called with `tokenCount = 0`. |
| `JBController_ZeroTokensToBurn` | `JBController` | `burnTokensOf` called with `tokenCount = 0`. |
| `JBController_NoReservedTokens` | `JBController` | `sendReservedTokensToSplitsOf` called but no pending reserved tokens. |
| `JBController_CreditTransfersPaused` | `JBController` | `transferCreditsFrom` called but `pauseCreditTransfers` is set in ruleset. |
| `JBController_RulesetSetTokenNotAllowed` | `JBController` | `setTokenFor` called but `allowSetCustomToken` is false in ruleset. |
| `JBController_AddingPriceFeedNotAllowed` | `JBController` | `addPriceFeedFor` called but `allowAddPriceFeed` is false in ruleset. |
| `JBController_InvalidReservedPercent` | `JBController` | `reservedPercent` exceeds `MAX_RESERVED_PERCENT` (10,000). |
| `JBController_InvalidCashOutTaxRate` | `JBController` | `cashOutTaxRate` exceeds `MAX_CASH_OUT_TAX_RATE` (10,000). |
| `JBMultiTerminal_UnderMinReturnedTokens` | `JBMultiTerminal` | Payment minted fewer tokens than `minReturnedTokens`. |
| `JBMultiTerminal_UnderMinTokensReclaimed` | `JBMultiTerminal` | Cash out reclaimed less than `minTokensReclaimed`. |
| `JBMultiTerminal_UnderMinTokensPaidOut` | `JBMultiTerminal` | Payout distributed less than `minTokensPaidOut`. |
| `JBMultiTerminal_TokenNotAccepted` | `JBMultiTerminal` | Token has no accounting context for the project in this terminal. |
| `JBMultiTerminal_NoMsgValueAllowed` | `JBMultiTerminal` | `msg.value > 0` sent with an ERC-20 payment (not `NATIVE_TOKEN`). |
| `JBMultiTerminal_PermitAllowanceNotEnough` | `JBMultiTerminal` | Permit2 allowance insufficient for the payment amount. |
| `JBTerminalStore_RulesetPaymentPaused` | `JBTerminalStore` | `pausePay` is set in the current ruleset. |
| `JBTerminalStore_RulesetNotFound` | `JBTerminalStore` | No ruleset exists for the project (not launched). |
| `JBTerminalStore_InadequateControllerPayoutLimit` | `JBTerminalStore` | `sendPayoutsOf` amount exceeds the payout limit for this cycle. |
| `JBTerminalStore_InadequateControllerAllowance` | `JBTerminalStore` | `useAllowanceOf` amount exceeds the surplus allowance. |
| `JBTerminalStore_InadequateTerminalStoreBalance` | `JBTerminalStore` | Withdrawal exceeds the terminal's recorded balance. |
| `JBTerminalStore_InsufficientTokens` | `JBTerminalStore` | Cash out count exceeds the holder's token balance. |
| `JBTerminalStore_TerminalMigrationNotAllowed` | `JBTerminalStore` | `migrateBalanceOf` called but `allowTerminalMigration` is false. |
| `JBTerminalStore_NoopHookSpecHasAmount` | `JBTerminalStore` | Data hook returned a noop spec with `amount != 0`. |
| `JBTerminalStore_AccountingContextAlreadySet` | `JBTerminalStore` | Accounting context already exists for that token. |
| `JBDirectory_SetControllerNotAllowed` | `JBDirectory` | Controller change not allowed by the current ruleset. |
| `JBDirectory_SetTerminalsNotAllowed` | `JBDirectory` | Terminal change not allowed by the current ruleset. |
| `JBDirectory_DuplicateTerminals` | `JBDirectory` | Duplicate terminal in the terminals array. |
| `JBTokens_ProjectAlreadyHasToken` | `JBTokens` | `deployERC20For` / `setTokenFor` called but project already has an ERC-20. |
| `JBTokens_InsufficientCredits` | `JBTokens` | `claimTokensFor` count exceeds credit balance. |
| `JBTokens_TokensMustHave18Decimals` | `JBTokens` | Custom token does not use 18 decimals. |
| `JBSplits_TotalPercentExceeds100` | `JBSplits` | Split percentages sum exceeds `SPLITS_TOTAL_PERCENT`. |
| `JBPrices_PriceFeedAlreadyExists` | `JBPrices` | Feed already set for that currency pair (immutable). |
| `JBPrices_PriceFeedNotFound` | `JBPrices` | No feed found for the requested currency pair. |
| `JBPermissions_CantSetRootPermissionForWildcardProject` | `JBPermissions` | Tried to grant ROOT with `projectId = 0` (wildcard). |
| `JBRulesets_InvalidWeight` | `JBRulesets` | Weight exceeds `uint112.max`. |
| `JBRulesets_InvalidWeightCutPercent` | `JBRulesets` | `weightCutPercent` exceeds `MAX_WEIGHT_CUT_PERCENT`. |
| `JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering` | `JBFundAccessLimits` | Payout limit currencies not in strictly increasing order. |

## Key Events

The most important events for indexing and off-chain monitoring. Indexed params marked with `*`.

| Event | Interface | Key Params |
|-------|-----------|------------|
| `Pay` | `IJBTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `payer`, `beneficiary`, `amount`, `newlyIssuedTokenCount` |
| `CashOutTokens` | `IJBCashOutTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `holder`, `beneficiary`, `cashOutCount`, `cashOutTaxRate`, `reclaimAmount` |
| `SendPayouts` | `IJBPayoutTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `projectOwner`, `amount`, `amountPaidOut`, `fee`, `netLeftoverPayoutAmount` |
| `SendPayoutToSplit` | `IJBPayoutTerminal` | `projectId*`, `rulesetId*`, `group*`, `split`, `amount`, `netAmount` |
| `UseAllowance` | `IJBPayoutTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `beneficiary`, `amount`, `netAmountPaidOut` |
| `MintTokens` | `IJBController` | `beneficiary*`, `projectId*`, `tokenCount`, `beneficiaryTokenCount`, `reservedPercent` |
| `BurnTokens` | `IJBController` | `holder*`, `projectId*`, `tokenCount` |
| `SendReservedTokensToSplits` | `IJBController` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `owner`, `tokenCount`, `leftoverAmount` |
| `SendReservedTokensToSplit` | `IJBController` | `projectId*`, `rulesetId*`, `groupId*`, `split`, `tokenCount` |
| `SplitHookReverted` | `IJBController` | `projectId*`, `hook`, `reason` |
| `LaunchProject` | `IJBController` | `rulesetId`, `projectId`, `projectUri` |
| `QueueRulesets` | `IJBController` | `rulesetId`, `projectId` |
| `DeployERC20` | `IJBController` | `projectId*`, `deployer*`, `salt`, `saltHash`, `caller` |
| `SetUri` | `IJBController` | `projectId*`, `uri` |
| `AddToBalance` | `IJBTerminal` | `projectId*`, `amount`, `returnedFees` |
| `MigrateTerminal` | `IJBTerminal` | `projectId*`, `token*`, `to*`, `amount` |
| `HoldFee` | `IJBFeeTerminal` | `projectId*`, `token*`, `amount*`, `fee`, `beneficiary` |
| `ProcessFee` | `IJBFeeTerminal` | `projectId*`, `token*`, `amount*`, `wasHeld`, `beneficiary` |
| `ReturnHeldFees` | `IJBFeeTerminal` | `projectId*`, `token*`, `amount*`, `returnedFees`, `leftoverAmount` |
| `Create` | `IJBProjects` | `projectId*`, `owner*` |
| `OperatorPermissionsSet` | `IJBPermissions` | (operator, account, projectId, permissionIds, packed, caller) |
| `RulesetQueued` | `IJBRulesets` | (rulesetId, projectId, duration, weight, weightCutPercent, approvalHook, metadata, mustStartAtOrAfter, caller) |
| `SetSplit` | `IJBSplits` | (projectId, rulesetId, groupId, split, caller) |
| `AddPriceFeed` | `IJBPrices` | (projectId, pricingCurrency, unitCurrency, feed, caller) |

## Hook Interface Return Types

### `IJBRulesetDataHook.beforePayRecordedWith()`

```solidity
function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
    external view
    returns (
        uint256 weight,                              // Overrides the ruleset's weight for token issuance
        JBPayHookSpecification[] memory hookSpecifications  // Pay hooks to call + amounts to forward
    );
```

The data hook can override `weight` to change how many tokens the payer receives. Return `hookSpecifications` to redirect funds to pay hooks (each spec has `hook`, `amount`, `metadata`, and `noop`). An empty array means all funds stay in the terminal balance.

### `IJBRulesetDataHook.beforeCashOutRecordedWith()`

```solidity
function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
    external view
    returns (
        uint256 cashOutTaxRate,                               // Overrides the ruleset's cash out tax rate
        uint256 cashOutCount,                                 // Overrides the number of tokens being cashed out
        uint256 totalSupply,                                  // Overrides total supply for bonding curve calc
        JBCashOutHookSpecification[] memory hookSpecifications // Cash out hooks to call + amounts to forward
    );
```

The data hook can override `cashOutTaxRate` (0 = proportional, 10000 = nothing reclaimable), `cashOutCount` and `totalSupply` (to shift the bonding curve), and return `hookSpecifications` to redirect reclaimed funds to cash out hooks.

### `IJBRulesetDataHook.hasMintPermissionFor()`

```solidity
function hasMintPermissionFor(uint256 projectId, JBRuleset memory ruleset, address addr)
    external view returns (bool flag);
```

Returns whether `addr` is allowed to mint tokens for the project. Called by `JBController.mintTokensOf` when the caller is not the owner and `allowOwnerMinting` is false -- the data hook can grant mint permission to specific addresses (e.g. suckers for omnichain bridging).

## Example Integration

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

contract PayProject {
    IJBDirectory public immutable DIRECTORY;

    constructor(IJBDirectory directory) {
        DIRECTORY = directory;
    }

    /// @notice Pay a project with native ETH and receive project tokens.
    function payProject(uint256 projectId) external payable returns (uint256 tokenCount) {
        // Look up the project's primary terminal for native ETH.
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf(projectId, JBConstants.NATIVE_TOKEN);
        require(address(terminal) != address(0), "No terminal");

        // Pay the project. The msg.sender receives the minted tokens.
        tokenCount = IJBMultiTerminal(address(terminal)).pay{value: msg.value}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: msg.value,
            beneficiary: msg.sender,
            minReturnedTokens: 0,
            memo: "Paid via PayProject",
            metadata: ""
        });
    }
}
```
