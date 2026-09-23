# Core Types, Errors, And Events

Use this file when you need deeper protocol reference material after the repo-local `SKILLS.md` has already routed you to `nana-core-v6`.

## Key types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBRuleset` | `cycleNumber (uint48)`, `id (uint48)`, `basedOnId (uint48)`, `start (uint48)`, `duration (uint32)`, `weight (uint112)`, `weightCutPercent (uint32)`, `approvalHook`, `metadata (uint256)` | `currentOf()`, `recordPaymentFrom()`, `recordCashOutFor()` return values |
| `JBRulesetConfig` | `mustStartAtOrAfter (uint48)`, `duration (uint32)`, `weight (uint112)`, `weightCutPercent (uint32)`, `approvalHook`, `metadata (JBRulesetMetadata)`, `splitGroups[]`, `fundAccessLimitGroups[]` | `launchProjectFor()`, `launchRulesetsFor()`, `queueRulesetsOf()` input |
| `JBRulesetMetadata` | `reservedPercent (uint16)`, `cashOutTaxRate (uint16)`, `baseCurrency (uint32)`, `pausePay`, `pauseCreditTransfers`, `allowOwnerMinting`, `allowSetCustomToken`, `allowTerminalMigration`, `allowSetTerminals`, `allowSetController`, `allowAddAccountingContext`, `allowAddPriceFeed`, `ownerMustSendPayouts`, `holdFees`, `scopeCashOutsToLocalBalances`, `useDataHookForPay`, `useDataHookForCashOut`, `dataHook (address)`, `metadata (uint16)` | Packed into `JBRuleset.metadata` |
| `JBSplit` | `percent (uint32)`, `projectId (uint64)`, `beneficiary (address payable)`, `preferAddToBalance`, `lockedUntil (uint48)`, `hook (IJBSplitHook)` | `splitsOf()`, `setSplitGroupsOf()` |
| `JBSplitGroup` | `groupId (uint256)`, `splits (JBSplit[])` | `JBRulesetConfig.splitGroups`, `setSplitGroupsOf()` |
| `JBAccountingContext` | `token (address)`, `decimals (uint8)`, `currency (uint32)` | Terminal token accounting, surplus/reclaim calculations |
| `JBTokenAmount` | `token (address)`, `decimals (uint8)`, `currency (uint32)`, `value (uint256)` | `recordPaymentFrom()` input |
| `JBTerminalConfig` | `terminal (IJBTerminal)`, `accountingContextsToAccept (JBAccountingContext[])` | `launchProjectFor()`, `launchRulesetsFor()` input |
| `JBCurrencyAmount` | `amount (uint224)`, `currency (uint32)` | Payout limits and surplus allowances |
| `JBFundAccessLimitGroup` | `terminal (address)`, `token (address)`, `payoutLimits (JBCurrencyAmount[])`, `surplusAllowances (JBCurrencyAmount[])` | `JBRulesetConfig.fundAccessLimitGroups` |
| `JBPermissionsData` | `operator (address)`, `projectId (uint64)`, `permissionIds (uint8[])` | `setPermissionsFor()` input |
| `JBFee` | `amount (uint224)`, `beneficiary (address)`, `unlockTimestamp (uint48)` | Held fees in `JBMultiTerminal` |
| `JBSingleAllowance` | `sigDeadline (uint256)`, `amount (uint160)`, `expiration (uint48)`, `nonce (uint48)`, `signature (bytes)` | Permit2 allowance in terminal payments |
| `JBRulesetWithMetadata` | `ruleset (JBRuleset)`, `metadata (JBRulesetMetadata)` | `allRulesetsOf()` return values (`currentRulesetOf()` and the other single-ruleset controller views return the ruleset and its metadata as two separate values) |
| `JBRulesetWeightCache` | `weight (uint112)`, `weightCutMultiple (uint168)` | Weight caching for long-running rulesets in `JBRulesets` |
| `JBApprovalStatus` (enum) | `Empty`, `Upcoming`, `Active`, `ApprovalExpected`, `Approved`, `Failed` | Approval hook status for queued rulesets |

### Hook structs

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBBeforePayRecordedContext` | `terminal`, `payer`, `amount (JBTokenAmount)`, `projectId`, `rulesetId`, `beneficiary`, `weight`, `reservedPercent`, `metadata` | `IJBRulesetDataHook.beforePayRecordedWith()` input |
| `JBBeforeCashOutRecordedContext` | `terminal`, `holder`, `projectId`, `rulesetId`, `cashOutCount`, `totalSupply`, `surplus (JBTokenAmount)`, `scopeCashOutsToLocalBalances`, `cashOutTaxRate`, `beneficiaryIsFeeless`, `metadata` | `IJBRulesetDataHook.beforeCashOutRecordedWith()` input |
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
| `MAX_FEE` | `1000` | Fee denominator. The protocol fee is `STANDARD_FEE / MAX_FEE`. |
| `STANDARD_FEE` | `25` | Protocol fee numerator: `25 / 1000` = 2.5% |
| `FEE_BENEFICIARY_PROJECT_ID` | `1` | Project that receives protocol fees |
| `NATIVE_TOKEN_CURRENCY` | `61166` | Accounting-context currency of `NATIVE_TOKEN` (`uint32(uint160(NATIVE_TOKEN))`) |

### Currency IDs (`JBCurrencyIds`)

| ID | Currency |
|----|----------|
| `1` | ETH |
| `2` | USD |

### Split group IDs (`JBSplitGroupIds`)

| ID | Group |
|----|-------|
| `1` | `RESERVED_TOKENS` -- reserved token distribution |

### Special values

| Value | Context | Meaning |
|-------|---------|---------|
| `weight = 0` | `JBRuleset` / `JBRulesetConfig` | No token issuance for payments. |
| `weight = 1` | `JBRuleset` / `JBRulesetConfig` | Inherit the decayed weight of the ruleset it is based on (sentinel). A project's first ruleset stores `1` as-is. |
| `duration = 0` | `JBRuleset` / `JBRulesetConfig` | Ruleset never cycles; it stays current until a newly queued ruleset replaces it. The replacement can start as soon as its `mustStartAtOrAfter` and the current ruleset's approval hook allow. |
| `projectId = 0` | `JBPermissionsData` | Wildcard: permission applies to ALL projects. Only the account itself can set wildcard permissions (ROOT included); a ROOT operator acting for the account cannot. |
| `permissionId = 1` | `JBPermissions` | ROOT: grants all permissions for the scoped project. |
| `rulesetId = 0` | `JBSplits.splitsOf()` | Fallback split group used when no splits are set for a specific ruleset. |
| `projectId = 0` | `JBPrices.addPriceFeedFor()` | Appends a protocol-wide default price feed (owner-only). |

## Gotchas

- `IJBDirectory.controllerOf()` returns `IERC165`, NOT `address` -- must wrap: `address(directory.controllerOf(projectId))`
- `IJBDirectory.primaryTerminalOf()` returns `IJBTerminal`, NOT `address` -- must wrap: `address(directory.primaryTerminalOf(projectId, token))`
- `IJBDirectory.terminalsOf()` returns `IJBTerminal[]`, NOT `address[]`
- `pricePerUnitOf()` is on `IJBPrices`, NOT `IJBController` -- access via `IJBController(ctrl).PRICES().pricePerUnitOf(...)`
- `JBRulesetConfig` fields need explicit casts: `uint48 mustStartAtOrAfter`, `uint32 duration`, `uint112 weight`, `uint32 weightCutPercent`
- Zero-amount `pay{value:0}()` and zero-count `cashOutTokensOf(count=0)` are valid no-ops (mint/return 0)
- `sendPayoutsOf()` auto-caps `amount` to the remaining payout limit -- does NOT revert. Use `minTokensPaidOut` to enforce a minimum.
- `IJBTokens.claimTokensFor()` takes 4 args: `(holder, projectId, count, beneficiary)` -- NOT 3
- `JBFeelessAddresses.setFeelessAddress()` NOT `setIsFeelessAddress()` -- the function name omits "Is"
- Named returns auto-return (no explicit `return` statement needed in Solidity)
- `bool` defaults to `false` (correct security default for metadata flags)
- Credits are burned before ERC-20 tokens in `JBTokens.burnFrom()`
- `JBRuleset.weight` is `uint112` with 18 decimals; `JBRuleset.metadata` is packed -- use `JBRulesetMetadataResolver` to unpack
- `JBTokens.deployERC20For()` clones `JBERC20` with `Clones.clone()` when the salt is zero and `Clones.cloneDeterministic()` when it is non-zero (`JBController` hashes the salt with its caller, then `JBTokens` hashes it again with the controller) -- the implementation's constructor sets invalid name/symbol; real values set in `initialize()`
- `JBERC20.getPastTotalSupply()` includes undelegated balances; `getPastTotalActiveVotes()` only counts balances whose
  owner had a nonzero delegate at the queried block.
- Fee is 2.5% (`JBConstants.STANDARD_FEE = 25` out of `JBConstants.MAX_FEE = 1000`)
- Project #1 is the fee beneficiary project (receives all protocol fees)
- **Fee-free cashout exemption is scoped to fee-free intra-terminal payout amounts.** `feeFreeSurplusOf[projectId][token]` accumulates the value of fee-free payouts. After any outflow (payouts, `useAllowanceOf`, non-zero-tax or feeless cashouts), the counter is capped at the remaining balance — non-fee-free funds leave first, preserving the fee-free counter. During cashout with `cashOutTaxRate=0`, the 2.5% fee applies only up to this surplus, then depletes. Once consumed, subsequent cashouts are fee-free again. Cleared on terminal migration. This prevents a round-trip fee bypass (intra-terminal payout → zero-tax cashout) while scoping fees precisely to the fee-free inflow.
- `JBProjects` constructor optionally mints project #1 to `feeProjectOwner` -- if `address(0)`, no fee project is created
- `JBMultiTerminal` derives `DIRECTORY` from the provided `store` in its constructor -- not passed directly
- `JBPrices.pricePerUnitOf()` checks project direct feeds, project inverse feeds, default direct feeds, then default inverse feeds. It skips feeds that revert or return zero.
- `useAllowanceOf()` takes 8 args including `address payable feeBeneficiary` -- do NOT omit it
- `JBFeelessAddresses.isFeelessFor()` takes 3 args: `(addr, projectId, caller)`. The optional hook can use `caller` to scope dynamic grants.
- Cash out tax rate of 0% = proportional (1:1) redemption; 100% = nothing reclaimable (all surplus locked). Do NOT confuse with a "cash out rate" where 100% means full redemption.
- `cashOutTaxRate` in `JBRulesetMetadata` is `uint16` (max 10,000 basis points), NOT 9-decimal precision
- `reservedPercent` in `JBRulesetMetadata` is `uint16` (max 10,000 basis points), NOT 9-decimal precision
- `weight` in `JBRuleset` is `uint112`, but `weight` in `JBRulesetConfig` is also `uint112` -- both use 18 decimals
- `JBSplits.splitsOf()` falls back to ruleset ID 0 if no splits are set for the given rulesetId
- Held fees are held for 28 days (`_FEE_HOLDING_SECONDS = 2,419,200`) before they can be processed
- `JBController`, `JBMultiTerminal`, `JBProjects`, `JBPrices`, `JBPermissions` all support ERC-2771 meta-transactions
- `JBRulesetMetadataResolver` bit layout: version (4 bits), reservedPercent (16), cashOutTaxRate (16), baseCurrency (32), 14 boolean flags (1 bit each), dataHook address (160), metadata (14)
- `IJBDirectoryAccessControl` has `setControllerAllowed()` and `setTerminalsAllowed()` -- NOT `setControllerAllowedFor()`
- Price feeds are append-only in `JBPrices`. Existing feeds cannot be replaced or removed; later feeds are fallbacks after the primary feed.
- `JBFundAccessLimits` requires payout limits and surplus allowances to be in strictly increasing currency order to prevent duplicates
- **Empty `fundAccessLimitGroups` = zero payouts, NOT unlimited.** If a ruleset's `fundAccessLimitGroups` array is empty (or has no entry for the terminal/token), `payoutLimitOf()` returns 0 for every currency → the payout limit is 0 → `sendPayoutsOf()` caps to 0 and returns 0. To allow unlimited payouts, explicitly set a payout limit with `amount: type(uint224).max`.
- **`groupId` (uint256) vs `currency` (uint32) are different types for the same address.** `JBSplitGroup.groupId` is `uint256(uint160(tokenAddress))` while `JBAccountingContext.currency` is `uint32(uint160(tokenAddress))`. These truncate differently — only `NATIVE_TOKEN` (0x000000000000000000000000000000000000EEEe) matches by coincidence. Don't confuse them.
- **`JBAccountingContext.currency` is NOT `baseCurrency` — by design.** `baseCurrency` in ruleset metadata uses abstract real-world values (1 = ETH, 2 = USD) so rulesets are portable across chains — `baseCurrency=2` means "issue X tokens per USD" whether on Ethereum, Base, or Arbitrum. `JBAccountingContext.currency` uses token-derived values (`uint32(uint160(tokenAddress))`) because terminals track specific tokens at specific addresses — e.g. NATIVE_TOKEN = 61166, USDC on Ethereum = 906423112, USDC on Base = 3181390099. `JBPrices` mediates between the two: it converts token-derived currencies to/from abstract currencies (e.g. USDC token → USD concept, NATIVE_TOKEN → ETH concept) so that payout limits denominated in USD work correctly regardless of which token the terminal holds. The separation is what makes cross-chain consistency possible: same ruleset, different terminal accounting per chain.
- **Don't queue multiple identical rulesets.** A ruleset with a `duration` automatically cycles — no need to queue copies. Queue multiple rulesets only when configuration actually changes between periods (e.g. different weight, splits, or limits).
- **`NATIVE_TOKEN` represents a different token on each chain.** `NATIVE_TOKEN` (`0x000000000000000000000000000000000000EEEe`) is the token received via `msg.value` — ETH on Ethereum/Base/Optimism/Arbitrum, CELO on Celo, etc. Its currency is `uint32(uint160(NATIVE_TOKEN))` = 61166. A `JBMatchingPriceFeed` (returns 1:1) is deployed for `ETH:NATIVE_TOKEN` on ETH-native chains so that `baseCurrency=ETH` resolves correctly to the native token. On non-ETH-native chains, a different price feed would be needed.
- **`JBPrices` resolves a pair through one direct feed or one inverted feed — it never chains two.** For a pair it tries the registered feeds for `{pricingCurrency ← unitCurrency}`, then inverts the feeds registered for `{unitCurrency ← pricingCurrency}`, then repeats both against the project-0 defaults. Shared USD legs are not composed automatically. The floor-fix rollout supplies a `JBRatioPriceFeed` with ETH/USD as numerator and USDC/USD as denominator, returning USDC per NATIVE/ETH. It registers project-0 defaults for BOTH `{uint32(usdc) ← NATIVE}` and `{uint32(usdc) ← ETH}` because `ETH` (1) and `NATIVE_TOKEN` (61166) are distinct currency IDs and their matching feed is not chained either. Keeping USDC on the pricing side makes six-decimal USDC payment queries direct, avoiding the precision loss of first rounding a small reciprocal. Verify the live registration and underlying feeds separately from the deployment record.
- **Noop hook specifications are informational-only.** `noop = true` + `amount != 0` reverts with `JBTerminalStore_NoopHookSpecHasAmount`. Data hooks use noop specs to return diagnostics to preview clients without triggering a hook callback. The `noop` flag only suppresses the callback — parameter overrides (weight, tax rate, supply) from the data hook still apply.

## Permission IDs

Quick-reference for the `JBPermissionIds` values that core contracts check (from `@bananapus/permission-ids-v6`). Pass these to `JBPermissions.setPermissionsFor()`. Unless noted, the account granting the permission is the project owner.

| ID | Name | Gates |
|----|------|-------|
| `1` | `ROOT` | All permissions for the scoped project: every core check passes `includeRoot = true`. Only the account itself can grant ROOT or wildcard (`projectId = 0`) permissions; a ROOT operator can set non-ROOT permissions on a specific project it holds ROOT for (directly or through a wildcard grant). |
| `2` | `QUEUE_RULESETS` | `JBController.queueRulesetsOf` (the `OMNICHAIN_RULESET_OPERATOR` is exempt) |
| `3` | `LAUNCH_RULESETS` | `JBController.launchRulesetsFor` (the `OMNICHAIN_RULESET_OPERATOR` is exempt) |
| `4` | `CASH_OUT_TOKENS` | `JBMultiTerminal.cashOutTokensOf` (granted by the token holder) |
| `5` | `SEND_PAYOUTS` | `JBMultiTerminal.sendPayoutsOf`, only when the ruleset sets `ownerMustSendPayouts` (otherwise permissionless) |
| `6` | `MIGRATE_TERMINAL` | `JBMultiTerminal.migrateBalanceOf` |
| `7` | `SET_PROJECT_URI` | `JBController.setUriOf`; `JBController.launchRulesetsFor` when `projectUri` is non-empty (the `OMNICHAIN_RULESET_OPERATOR` is exempt there) |
| `8` | `DEPLOY_ERC20` | `JBController.deployERC20For` |
| `9` | `SET_TOKEN` | `JBController.setTokenFor` |
| `10` | `MINT_TOKENS` | `JBController.mintTokensOf` (the project's terminals, its data hook and addresses the data hook grants are exempt) |
| `11` | `BURN_TOKENS` | `JBController.burnTokensOf` (granted by the token holder; the project's terminals are exempt) |
| `12` | `CLAIM_TOKENS` | `JBController.claimTokensFor` (granted by the credit holder) |
| `13` | `TRANSFER_CREDITS` | `JBController.transferCreditsFrom` (granted by the credit holder) |
| `14` | `SET_CONTROLLER` | `JBDirectory.setControllerOf` (addresses allowed to set a first controller are exempt while the project has none) |
| `15` | `SET_TERMINALS` | `JBDirectory.setTerminalsOf` (can remove primary terminal; the project's controller is exempt); `JBController.launchRulesetsFor` (the `OMNICHAIN_RULESET_OPERATOR` is exempt there) |
| `16` | `ADD_TERMINALS` | `JBDirectory.setPrimaryTerminalOf` when the terminal is not already in the project's list (implicit addition) |
| `17` | `SET_PRIMARY_TERMINAL` | `JBDirectory.setPrimaryTerminalOf` |
| `18` | `USE_ALLOWANCE` | `JBMultiTerminal.useAllowanceOf` |
| `19` | `SET_SPLIT_GROUPS` | `JBController.setSplitGroupsOf` |
| `20` | `ADD_PRICE_FEED` | `JBController.addPriceFeedFor` |
| `21` | `ADD_ACCOUNTING_CONTEXTS` | `JBMultiTerminal.addAccountingContextsFor` (the project's controller is exempt) |
| `22` | `SET_TOKEN_METADATA` | `JBController.setTokenMetadataOf` |
| `23` | `SIGN_FOR_ERC20` | `JBERC20.isValidSignature` (returns `0xffffffff` instead of reverting when the signer lacks it) |

IDs 24-39 are used by extension contracts: 721 hook (24-27), buyback hook (28-30), router terminal (31), suckers (32-36) and revnet loans (37-39).

## Common errors

Errors an agent is most likely to encounter. All are custom errors (revert with selector).

| Error | Contract | When |
|-------|----------|------|
| `JBPermissioned_Unauthorized` | `JBPermissioned` | Caller lacks the required permission ID for the project. |
| `JBControlled_ControllerUnauthorized` | `JBControlled` | Caller is not the project's controller in `JBDirectory`. Guards `JBRulesets.queueFor`, every `JBTokens` write, `JBFundAccessLimits.setFundAccessLimitsFor`, `JBSplits.setSplitGroupsOf` (unless the group is self-managed) and `JBPrices.addPriceFeedFor` for non-zero project IDs. |
| `JBController_RulesetsArrayEmpty` | `JBController` | `launchRulesetsFor` / `queueRulesetsOf` called with empty rulesets array. `launchProjectFor` does not check: an empty array launches the project with no rulesets. |
| `JBController_RulesetsAlreadyLaunched` | `JBController` | `launchRulesetsFor` called on a project that already has rulesets. |
| `JBController_MintNotAllowedAndNotTerminalOrHook` | `JBController` | `mintTokensOf` called while the current ruleset has `allowOwnerMinting` false, and the caller is not a project terminal, the data hook, or an address the data hook grants via `hasMintPermissionFor`. |
| `JBController_ZeroTokensToMint` | `JBController` | `mintTokensOf` called with `tokenCount = 0`. |
| `JBController_ZeroTokensToBurn` | `JBController` | `burnTokensOf` called with `tokenCount = 0`. |
| `JBController_NoReservedTokens` | `JBController` | `sendReservedTokensToSplitsOf` called but no pending reserved tokens. |
| `JBController_CreditTransfersPaused` | `JBController` | `transferCreditsFrom` called but `pauseCreditTransfers` is set in ruleset. |
| `JBController_RulesetSetTokenNotAllowed` | `JBController` | `setTokenFor` called but `allowSetCustomToken` is false in the current ruleset (or the upcoming one when there is no current ruleset). |
| `JBController_AddingPriceFeedNotAllowed` | `JBController` | `addPriceFeedFor` called while a current ruleset exists and its `allowAddPriceFeed` is false. |
| `JBController_InvalidReservedPercent` | `JBController` | `reservedPercent` exceeds `MAX_RESERVED_PERCENT` (10,000). |
| `JBController_InvalidCashOutTaxRate` | `JBController` | `cashOutTaxRate` exceeds `MAX_CASH_OUT_TAX_RATE` (10,000). |
| `JBMultiTerminal_UnderMin` | `JBMultiTerminal` | Returned value was below the caller-specified minimum in `pay`, `cashOutTokensOf`, `sendPayoutsOf` or `useAllowanceOf`. |
| `JBMultiTerminal_TokenNotAccepted` | `JBMultiTerminal` | Token has no accounting context for the project in this terminal. |
| `JBMultiTerminal_NoMsgValueAllowed` | `JBMultiTerminal` | `msg.value > 0` sent with an ERC-20 payment (not `NATIVE_TOKEN`). |
| `JBMultiTerminal_PermitAllowanceNotEnough` | `JBMultiTerminal` | Permit2 allowance insufficient for the payment amount. |
| `JBTerminalStore_RulesetPaymentPaused` | `JBTerminalStore` | `pausePay` is set in the current ruleset. |
| `JBTerminalStore_RulesetNotFound` | `JBTerminalStore` | Payment (or payment preview) while the project has no current ruleset: it has not been launched, or its first ruleset has not started yet. |
| `JBTerminalStore_InadequateControllerAllowance` | `JBTerminalStore` | `useAllowanceOf` would take the ruleset's used surplus allowance for that currency past its limit, or no allowance is set. |
| `JBTerminalStore_InadequateTerminalStoreBalance` | `JBTerminalStore` | A payout exceeds the terminal's recorded balance, or a cash out (reclaim plus forwarded hook amounts) or allowance use exceeds the token's surplus in the terminal. |
| `JBTerminalStore_InsufficientTokens` | `JBTerminalStore` | Cash out count exceeds the project's total token supply including pending reserved tokens. |
| `JBTerminalStore_TerminalMigrationNotAllowed` | `JBTerminalStore` | `migrateBalanceOf` called but `allowTerminalMigration` is false. |
| `JBTerminalStore_NoopHookSpecHasAmount` | `JBTerminalStore` | Data hook returned a noop spec with `amount != 0`. |
| `JBTerminalStore_AccountingContextAlreadySet` | `JBTerminalStore` | Accounting context already exists for that token. |
| `JBDirectory_SetControllerNotAllowed` | `JBDirectory` | Controller change not allowed by the current ruleset. |
| `JBDirectory_SetTerminalsNotAllowed` | `JBDirectory` | Terminal change not allowed by the current ruleset. |
| `JBDirectory_DuplicateTerminals` | `JBDirectory` | Duplicate terminal in the terminals array. |
| `JBTokens_ProjectAlreadyHasToken` | `JBTokens` | `deployERC20For` / `setTokenFor` called but project already has an ERC-20. |
| `JBTokens_InsufficientCredits` | `JBTokens` | `claimTokensFor` / `transferCreditsFrom` count exceeds the holder's credit balance. |
| `JBTokens_TokensMustHave18Decimals` | `JBTokens` | Custom token does not use 18 decimals. |
| `JBTokens_EmptyName` | `JBTokens` | `deployERC20For` / `setTokenMetadataFor` called with an empty name. |
| `JBTokens_EmptySymbol` | `JBTokens` | `deployERC20For` / `setTokenMetadataFor` called with an empty symbol. |
| `JBTokens_EmptyToken` | `JBTokens` | `setTokenFor` called with the zero address. |
| `JBTokens_InsufficientTokensToBurn` | `JBTokens` | `burnFrom` count exceeds the holder's credits plus ERC-20 balance. |
| `JBTokens_OverflowAlert` | `JBTokens` | `mintFor` would push the project's total supply above `uint208.max`. |
| `JBTokens_TokenAlreadyBeingUsed` | `JBTokens` | `setTokenFor` token is already attached to another project. |
| `JBTokens_TokenCantBeAdded` | `JBTokens` | `setTokenFor` token's `canBeAddedTo(projectId)` returns false (always the case for a `JBERC20`). |
| `JBTokens_TokenNotFound` | `JBTokens` | `claimTokensFor` / `setTokenMetadataFor` called for a project with no token. |
| `JBSplits_TotalPercentExceeds100` | `JBSplits` | Split percentages sum exceeds `SPLITS_TOTAL_PERCENT`. |
| `JBSplits_ZeroSplitPercent` | `JBSplits` | A split has `percent = 0`. |
| `JBSplits_PreviousLockedSplitsNotIncluded` | `JBSplits` | The new splits drop a split that is still locked (or keep fewer copies of it). A locked split is kept only by a split with the same `percent`, `projectId`, `beneficiary`, `preferAddToBalance` and `hook`, and a `lockedUntil` no earlier. |
| `JBPrices_PriceFeedAlreadyAdded` | `JBPrices` | The same feed address is already configured for that exact pair. Other backup feeds can still be appended. |
| `JBPrices_PriceFeedNotFound` | `JBPrices` | No project or default feed, direct or inverse, returned a non-zero price for the requested currency pair (feeds that revert or return zero are skipped). |
| `JBRatioPriceFeed_ZeroNumerator` | `JBRatioPriceFeed` | Constructed with the zero address as the numerator leg. |
| `JBRatioPriceFeed_ZeroDenominator` | `JBRatioPriceFeed` | Constructed with the zero address as the denominator leg. |
| `JBRatioPriceFeed_ZeroDenominatorPrice` | `JBRatioPriceFeed` | The denominator leg reported a price of zero, which has no reciprocal. |
| `JBRulesets_InvalidWeight` | `JBRulesets` | Weight exceeds `uint112.max`. |
| `JBRulesets_InvalidWeightCutPercent` | `JBRulesets` | `weightCutPercent` exceeds `MAX_WEIGHT_CUT_PERCENT`. |
| `JBRulesets_InvalidRulesetDuration` | `JBRulesets` | `duration` exceeds `uint32.max`. |
| `JBRulesets_InvalidRulesetEndTime` | `JBRulesets` | `mustStartAtOrAfter` (or `block.timestamp` when it is 0) plus `duration` exceeds `uint48.max`. |
| `JBRulesets_InvalidRulesetApprovalHook` | `JBRulesets` | Approval hook has no code, or does not report ERC-165 support for `IJBRulesetApprovalHook`. |
| `JBRulesets_WeightCacheRequired` | `JBRulesets` | Deriving a weight would need more than 20,000 weight cuts beyond what the weight cache covers. Call `updateRulesetWeightCache` first (once per 20,000 cycles of gap). |
| `JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering` | `JBFundAccessLimits` | Payout limit currencies not in strictly increasing order. |
| `JBFundAccessLimits_InvalidSurplusAllowanceCurrencyOrdering` | `JBFundAccessLimits` | Surplus allowance currencies not in strictly increasing order. |
| `JBFundAccessLimits_DuplicateFundAccessLimitGroup` | `JBFundAccessLimits` | Two groups in the same call use the same terminal and token. |

## Key events

The most important events for indexing and off-chain monitoring. Params are listed in declaration order; indexed params marked with `*`.

| Event | Interface | Key Params |
|-------|-----------|------------|
| `Pay` | `IJBTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `payer`, `beneficiary`, `amount`, `newlyIssuedTokenCount`, `memo`, `metadata`, `caller` |
| `CashOutTokens` | `IJBCashOutTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `holder`, `beneficiary`, `cashOutCount`, `cashOutTaxRate`, `reclaimAmount`, `metadata`, `caller` |
| `SendPayouts` | `IJBPayoutTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `projectOwner`, `amount`, `amountPaidOut`, `fee`, `netLeftoverPayoutAmount`, `caller` |
| `SendPayoutToSplit` | `IJBPayoutTerminal` | `projectId*`, `rulesetId*`, `group*`, `split`, `amount`, `netAmount`, `caller` |
| `UseAllowance` | `IJBPayoutTerminal` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `beneficiary`, `feeBeneficiary`, `amount`, `amountPaidOut`, `netAmountPaidOut`, `memo`, `caller` |
| `MintTokens` | `IJBController` | `beneficiary*`, `projectId*`, `tokenCount`, `beneficiaryTokenCount`, `memo`, `reservedPercent`, `caller` |
| `BurnTokens` | `IJBController` | `holder*`, `projectId*`, `tokenCount`, `memo`, `caller` |
| `SendReservedTokensToSplits` | `IJBController` | `rulesetId*`, `rulesetCycleNumber*`, `projectId*`, `owner`, `tokenCount`, `leftoverAmount`, `caller` |
| `SendReservedTokensToSplit` | `IJBController` | `projectId*`, `rulesetId*`, `groupId*`, `split`, `tokenCount`, `caller` |
| `SplitHookReverted` | `IJBController` | `projectId*`, `hook`, `reason`, `caller` |
| `LaunchProject` | `IJBController` | `rulesetId`, `projectId`, `projectUri`, `memo`, `caller` |
| `LaunchRulesets` | `IJBController` | `rulesetId`, `projectId`, `projectUri`, `memo`, `caller` |
| `QueueRulesets` | `IJBController` | `rulesetId`, `projectId`, `memo`, `caller` |
| `DeployERC20` | `IJBController` | `projectId*`, `deployer*`, `salt`, `saltHash`, `caller` |
| `SetUri` | `IJBController` | `projectId*`, `uri`, `caller` |
| `AddToBalance` | `IJBTerminal` | `projectId*`, `amount`, `returnedFees`, `memo`, `metadata`, `caller` |
| `MigrateTerminal` | `IJBTerminal` | `projectId*`, `token*`, `to*`, `amount`, `caller` |
| `HoldFee` | `IJBFeeTerminal` | `projectId*`, `token*`, `amount*`, `fee`, `beneficiary`, `caller` |
| `ProcessFee` | `IJBFeeTerminal` | `projectId*`, `token*`, `amount*`, `wasHeld`, `beneficiary`, `caller` |
| `ReturnHeldFees` | `IJBFeeTerminal` | `projectId*`, `token*`, `amount*`, `returnedFees`, `leftoverAmount`, `caller` |
| `FeeReverted` | `IJBFeeTerminal` | `projectId*`, `token*`, `feeProjectId*`, `amount`, `reason`, `caller` |
| `Create` | `IJBProjects` | `projectId*`, `owner*`, `caller` |
| `SetTokenMetadata` | `IJBTokens` | `projectId*`, `name`, `symbol`, `caller` |
| `DeployERC20` | `IJBTokens` | `projectId*`, `token*`, `name`, `symbol`, `salt`, `caller` |
| `SetToken` | `IJBTokens` | `projectId*`, `token*`, `caller` |
| `Mint` | `IJBTokens` | `holder*`, `projectId*`, `count`, `tokensWereClaimed`, `caller` |
| `Burn` | `IJBTokens` | `holder*`, `projectId*`, `count`, `creditBalance`, `tokenBalance`, `caller` |
| `ClaimTokens` | `IJBTokens` | `holder*`, `projectId*`, `creditBalance`, `count`, `beneficiary`, `caller` |
| `TransferCredits` | `IJBTokens` | `holder*`, `projectId*`, `recipient*`, `count`, `caller` |
| `OperatorPermissionsSet` | `IJBPermissions` | `operator*`, `account*`, `projectId*`, `permissionIds`, `packed`, `caller` |
| `RulesetQueued` | `IJBRulesets` | `rulesetId*`, `projectId*`, `duration`, `weight`, `weightCutPercent`, `approvalHook`, `metadata`, `mustStartAtOrAfter`, `caller` |
| `RulesetInitialized` | `IJBRulesets` | `rulesetId*`, `projectId*`, `basedOnId*`, `caller` |
| `WeightCacheUpdated` | `IJBRulesets` | `projectId`, `weight`, `weightCutMultiple`, `caller` |
| `SetSplit` | `IJBSplits` | `projectId*`, `rulesetId*`, `groupId*`, `split`, `caller` |
| `SetFundAccessLimits` | `IJBFundAccessLimits` | `rulesetId*`, `projectId*`, `fundAccessLimitGroup`, `caller` |
| `AddPriceFeed` | `IJBPrices` | `projectId*`, `pricingCurrency*`, `unitCurrency*`, `feed`, `caller` |

## Hook interface return types

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
        uint256 effectiveCashOutCount,                        // Overrides the token count used for pricing only
        uint256 effectiveTotalSupply,                         // Overrides total supply used for bonding curve calc
        uint256 effectiveSurplusValue,                        // Overrides surplus used for bonding curve calc
        JBCashOutHookSpecification[] memory hookSpecifications // Cash out hooks to call + amounts to forward
    );
```

The data hook can override `cashOutTaxRate` (0 = proportional, 10000 = nothing reclaimable), `effectiveCashOutCount`, `effectiveTotalSupply`, and `effectiveSurplusValue` to shift cash-out pricing, and return `hookSpecifications` to redirect reclaimed funds to cash out hooks. The terminal still burns the caller-supplied `cashOutCount`. The store caps the resulting reclaim at the project's current surplus across all its terminals, and `recordCashOutFor` reverts with `JBTerminalStore_InadequateTerminalStoreBalance` if the reclaim plus forwarded hook amounts exceed the reclaimed token's surplus in the calling terminal.

### `IJBRulesetDataHook.hasMintPermissionFor()`

```solidity
function hasMintPermissionFor(uint256 projectId, JBRuleset memory ruleset, address addr)
    external view returns (bool flag);
```

Returns whether `addr` is allowed to mint tokens for the project. Called by `JBController.mintTokensOf` when the current ruleset has a data hook and the caller is neither one of the project's terminals nor the data hook itself. A `true` result lets the caller mint without `MINT_TOKENS` and even when `allowOwnerMinting` is false -- the data hook can grant mint permission to specific addresses (e.g. suckers for omnichain bridging).

## Example integration

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
