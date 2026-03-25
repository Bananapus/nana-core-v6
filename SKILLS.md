# Juicebox Core

## Purpose

The core Juicebox V6 protocol on EVM: a modular system for launching treasury-backed tokens with configurable rulesets that govern payments, payouts, cash outs, and token issuance.

## Contracts

| Contract | Role |
|----------|------|
| `JBProjects` | ERC-721 project registry. Each NFT mint creates a new project ID. |
| `JBPermissions` | Packed `uint256` bitmap permissions. Operators get specific permission IDs scoped to projects. |
| `JBDirectory` | Maps project IDs to their controller (`IERC165`) and terminals (`IJBTerminal[]`). |
| `JBController` | Orchestrates rulesets, tokens, splits, fund access limits. Entry point for project lifecycle. |
| `JBMultiTerminal` | Handles ETH/ERC-20 payments, cash outs, payouts, surplus allowance, fees. Permit2 integration. |
| `JBTerminalStore` | Bookkeeping: balances, payout limit tracking, surplus calculation, bonding curve reclaim math. |
| `JBRulesets` | Stores/cycles rulesets with weight decay, approval hooks, and weight cache for gas-efficient long-running cycles. |
| `JBTokens` | Dual-balance system: credits (internal) + ERC-20. Credits burned first on burn. |
| `JBSplits` | Split configurations per project/ruleset/group. Packed storage for gas efficiency. |
| `JBFundAccessLimits` | Payout limits and surplus allowances per project/ruleset/terminal/token. |
| `JBPrices` | Price feed registry with project-specific and protocol-wide default feeds. Immutable once set. |
| `JBERC20` | Cloneable ERC-20 with Votes + Permit. Owned by `JBTokens`. Deployed via `Clones.clone()`. |
| `JBFeelessAddresses` | Allowlist for fee-exempt addresses. |
| `JBChainlinkV3PriceFeed` | Chainlink AggregatorV3 price feed with staleness threshold. Rejects negative/zero prices. |
| `JBChainlinkV3SequencerPriceFeed` | L2 sequencer-aware Chainlink feed (Optimism/Arbitrum) with grace period after restart. |
| `JBDeadline` | Approval hook: rejects rulesets queued within `DURATION` seconds of start. Ships as `JBDeadline3Hours`, `JBDeadline1Day`, `JBDeadline3Days`, `JBDeadline7Days`. |
| `JBMatchingPriceFeed` | Always returns 1:1. For equivalent currencies (e.g. ETH/NATIVE_TOKEN). |

## Key Functions

### JBController

| Function | What it does |
|----------|--------------|
| `launchProjectFor(address owner, string uri, JBRulesetConfig[] rulesetConfigs, JBTerminalConfig[] terminalConfigs, string memo)` | Creates a project, queues its first rulesets, and configures terminals. Returns `projectId`. |
| `launchRulesetsFor(uint256 projectId, JBRulesetConfig[] rulesetConfigs, JBTerminalConfig[] terminalConfigs, string memo)` | Launches the first rulesets for an existing project that has none. |
| `queueRulesetsOf(uint256 projectId, JBRulesetConfig[] rulesetConfigs, string memo)` | Queues new rulesets for a project. Takes effect after the current ruleset ends (or immediately if duration is 0). |
| `mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary, string memo, bool useReservedPercent)` | Mints project tokens. Requires `allowOwnerMinting` in the current ruleset or caller must be a terminal/hook with mint permission. |
| `burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string memo)` | Burns tokens from a holder. Requires holder's permission (`BURN_TOKENS`). |
| `sendReservedTokensToSplitsOf(uint256 projectId)` | Distributes accumulated reserved tokens to the reserved token split group. Returns token count sent. |
| `deployERC20For(uint256 projectId, string name, string symbol, bytes32 salt)` | Deploys a cloneable `JBERC20` for the project. Credits become claimable. |
| `claimTokensFor(address holder, uint256 projectId, uint256 count, address beneficiary)` | Redeems credits for ERC-20 tokens into beneficiary's wallet. |
| `setSplitGroupsOf(uint256 projectId, uint256 rulesetId, JBSplitGroup[] splitGroups)` | Sets the split groups for a project's ruleset. |
| `setTokenFor(uint256 projectId, IJBToken token)` | Sets an existing ERC-20 token for the project (requires `allowSetCustomToken` in ruleset). |
| `setTokenMetadataOf(uint256 projectId, string name, string symbol)` | Sets the name and symbol of a project's ERC-20 token. Requires `SET_TOKEN_METADATA` permission. |
| `setUriOf(uint256 projectId, string uri)` | Sets the project's metadata URI. |
| `transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 creditCount)` | Transfers credits between addresses (reverts if `pauseCreditTransfers` is set in ruleset). |
| `addPriceFeedFor(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)` | Registers a price feed (requires `allowAddPriceFeed` in ruleset). |
| `migrate(uint256 projectId, IERC165 to)` | Migrates the project to a new controller. Calls `beforeReceiveMigrationFrom`, `migrate`, updates directory, then `afterReceiveMigrationFrom`. |
| `currentRulesetOf(uint256 projectId)` | Returns the current ruleset and unpacked metadata. |
| `upcomingRulesetOf(uint256 projectId)` | Returns the upcoming ruleset and unpacked metadata. |
| `allRulesetsOf(uint256 projectId, uint256 startingId, uint256 size)` | Returns an array of rulesets with metadata, paginated. |
| `pendingReservedTokenBalanceOf(uint256 projectId)` | Returns accumulated reserved tokens not yet distributed. |
| `totalTokenSupplyWithReservedTokensOf(uint256 projectId)` | Returns total supply including pending reserved tokens. |
| `previewMintOf(uint256 projectId, uint256 tokenCount, bool useReservedPercent)` | Simulates a mint under the current ruleset. Returns `(beneficiaryTokenCount, reservedTokenCount)`. Reverts if `tokenCount` is 0. |

### JBMultiTerminal

| Function | What it does |
|----------|--------------|
| `pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)` | Pays a project. Mints project tokens to beneficiary based on ruleset weight. Returns token count. |
| `cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address payable beneficiary, bytes metadata)` | Burns project tokens and reclaims surplus terminal tokens via bonding curve. |
| `sendPayoutsOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut)` | Distributes payouts from the project's balance to its payout split group, up to the payout limit. |
| `useAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut, address payable beneficiary, address payable feeBeneficiary, string memo)` | Withdraws from the project's surplus allowance to a beneficiary. The `feeBeneficiary` receives tokens minted by the fee payment. |
| `addToBalanceOf(uint256 projectId, address token, uint256 amount, bool shouldReturnHeldFees, string memo, bytes metadata)` | Adds funds to a project's balance without minting tokens. Can unlock held fees. |
| `migrateBalanceOf(uint256 projectId, address token, IJBTerminal to)` | Migrates a project's token balance to another terminal. Requires `allowTerminalMigration`. |
| `processHeldFeesOf(uint256 projectId, address token, uint256 count)` | Processes up to `count` held fees for a project, sending them to the fee beneficiary project. |
| `addAccountingContextsFor(uint256 projectId, JBAccountingContext[] accountingContexts)` | Adds new accounting contexts (token types) to a terminal for a project. |
| `currentSurplusOf(uint256 projectId, address[] tokens, uint256 decimals, uint256 currency)` | Returns the project's current surplus in this terminal. Empty `tokens` = all tokens. |
| `accountingContextForTokenOf(uint256 projectId, address token)` | Returns the accounting context for a specific token. |
| `accountingContextsOf(uint256 projectId)` | Returns all accounting contexts for a project. |
| `previewPayFor(uint256 projectId, address token, uint256 amount, address beneficiary, bytes metadata)` | Simulates a full payment including the reserved/beneficiary token split. Returns `(ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications)`. Composes `STORE.previewPayFrom` + `controller.previewMintOf`. |
| `previewCashOutFrom(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, address payable beneficiary, bytes metadata)` | Simulates a full cash out including bonding curve and data hook effects. Returns `(ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications)`. Delegates to `STORE.previewCashOutFrom`. |
| `heldFeesOf(uint256 projectId, address token, uint256 count)` | Returns up to `count` held fees for a project/token. |

### JBTerminalStore

| Function | What it does |
|----------|--------------|
| `recordPaymentFrom(address payer, JBTokenAmount amount, uint256 projectId, address beneficiary, bytes metadata)` | Records a payment. Applies data hook if enabled. Returns ruleset, token count, hook specifications. |
| `recordPayoutFor(uint256 projectId, address token, uint256 amount, uint256 currency)` | Records a payout. Enforces payout limits. Returns ruleset and amount paid out. |
| `recordCashOutFor(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, bool beneficiaryIsFeeless, bytes metadata)` | Records a cash out. Computes reclaim via bonding curve. Returns ruleset, reclaim amount, tax rate, and hook specifications. |
| `recordUsedAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency)` | Records surplus allowance usage. Enforces allowance limits. Returns ruleset and used amount. |
| `recordAddedBalanceFor(uint256 projectId, address token, uint256 amount)` | Records funds added to a project's balance. |
| `recordTerminalMigration(uint256 projectId, address token)` | Records a terminal migration, returning the full balance. |
| `balanceOf(address terminal, uint256 projectId, address token)` | Returns the balance of a project at a terminal for a given token. |
| `usedPayoutLimitOf(address terminal, uint256 projectId, address token, uint256 rulesetCycleNumber, uint256 currency)` | Returns the used payout limit for a project in a given cycle. |
| `usedSurplusAllowanceOf(address terminal, uint256 projectId, address token, uint256 rulesetId, uint256 currency)` | Returns the used surplus allowance for a project in a given ruleset. |
| `currentReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, uint256 totalSupply, uint256 surplus)` | Returns the reclaimable surplus given raw total supply and surplus values. Applies bonding curve from current ruleset. |
| `currentReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, IJBTerminal[] terminals, address[] tokens, uint256 decimals, uint256 currency)` | Returns the reclaimable surplus across specified terminals and tokens. Empty arrays default to all. |
| `currentTotalReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, uint256 decimals, uint256 currency)` | Convenience view: reclaimable surplus across all terminals and all tokens. |
| `currentSurplusOf(uint256 projectId, IJBTerminal[] terminals, address[] tokens, uint256 decimals, uint256 currency)` | Returns the current surplus across specified terminals and tokens. Empty arrays default to all. |
| `currentTotalSurplusOf(uint256 projectId, uint256 decimals, uint256 currency)` | Convenience view: total surplus across all terminals and all tokens. |
| `previewPayFrom(address terminal, address payer, JBTokenAmount amount, uint256 projectId, address beneficiary, bytes metadata)` | Simulates a payment without modifying state. Uses the explicit `terminal` parameter for balance/surplus lookups. Invokes data hooks if configured. Returns ruleset, token count, and hook specifications. |
| `previewCashOutFrom(address terminal, address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, bool beneficiaryIsFeeless, bytes metadata)` | Simulates a cash out without modifying state. Uses the explicit `terminal` parameter for balance/surplus lookups. Invokes data hooks if configured. Returns ruleset, reclaim amount, tax rate, and hook specifications. |

### JBRulesets

| Function | What it does |
|----------|--------------|
| `currentOf(uint256 projectId)` | Returns the currently active ruleset with decayed weight and correct cycle number. |
| `latestQueuedOf(uint256 projectId)` | Returns the latest queued ruleset and its approval status. |
| `queueFor(uint256 projectId, uint256 duration, uint256 weight, uint256 weightCutPercent, IJBRulesetApprovalHook approvalHook, uint256 metadata, uint256 mustStartAtOrAfter)` | Queues a new ruleset. Only callable by the project's controller. |
| `updateRulesetWeightCache(uint256 projectId, uint256 rulesetId)` | Updates the weight cache for long-running rulesets. Required when `weightCutMultiple > 20,000` to avoid gas limits. |

### JBPermissions

| Function | What it does |
|----------|--------------|
| `setPermissionsFor(address account, JBPermissionsData permissionsData)` | Grants or revokes operator permissions. ROOT operators can set non-ROOT permissions for others. |
| `hasPermission(address operator, address account, uint256 projectId, uint256 permissionId, bool includeRoot, bool includeWildcardProjectId)` | Checks if an operator has a specific permission. |
| `hasPermissions(address operator, address account, uint256 projectId, uint256[] permissionIds, bool includeRoot, bool includeWildcardProjectId)` | Checks if an operator has all specified permissions. |

### JBDirectory

| Function | What it does |
|----------|--------------|
| `controllerOf(uint256 projectId)` | Returns the project's controller as `IERC165`. |
| `terminalsOf(uint256 projectId)` | Returns the project's terminals as `IJBTerminal[]`. |
| `primaryTerminalOf(uint256 projectId, address token)` | Returns the project's primary terminal for a given token. |
| `isTerminalOf(uint256 projectId, IJBTerminal terminal)` | Checks if a terminal belongs to a project. |
| `setControllerOf(uint256 projectId, IERC165 controller)` | Sets the project's controller. |
| `setTerminalsOf(uint256 projectId, IJBTerminal[] terminals)` | Sets the project's terminals. |
| `setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal)` | Sets the primary terminal for a token. |
| `setIsAllowedToSetFirstController(address addr, bool flag)` | Allows/disallows an address to set a project's first controller. Owner-only. |

### JBPrices

| Function | What it does |
|----------|--------------|
| `pricePerUnitOf(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, uint256 decimals)` | Returns the price of 1 `unitCurrency` in `pricingCurrency`. Checks project-specific, inverse, then default feeds. |
| `addPriceFeedFor(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)` | Registers a price feed. Project ID 0 sets protocol-wide defaults (owner-only). Immutable once set. |

### JBTokens

| Function | What it does |
|----------|--------------|
| `totalSupplyOf(uint256 projectId)` | Returns total supply: credits + ERC-20 tokens. |
| `totalBalanceOf(address holder, uint256 projectId)` | Returns combined credit + ERC-20 balance. |
| `creditBalanceOf(address holder, uint256 projectId)` | Returns the holder's credit balance. |
| `tokenOf(uint256 projectId)` | Returns the ERC-20 token for a project (`IJBToken`). |
| `setTokenMetadataFor(uint256 projectId, string name, string symbol)` | Sets the name and symbol of a project's token. Controller-only. |

### JBSplits

| Function | What it does |
|----------|--------------|
| `splitsOf(uint256 projectId, uint256 rulesetId, uint256 groupId)` | Returns splits for a project/ruleset/group. Falls back to ruleset ID 0 if none set. |

**Self-auth for `setSplitGroupsOf`**: A contract can set its own split groups without controller authorization if the lower 160 bits of the `groupId` match `msg.sender` AND the upper 96 bits are non-zero. GroupIds with zero upper 96 bits (bare addresses like `uint256(uint160(token))`) are protocol-reserved for terminal payout groups and always require controller auth.

### Other

| Function | What it does |
|----------|--------------|
| `setFeelessAddress(address addr, bool flag)` | Adds or removes an address from the fee exemption list. Owner-only. (`JBFeelessAddresses`) |
| `setControllerAllowed(uint256 projectId)` | Returns whether a project's controller can currently be set. (`IJBDirectoryAccessControl`) |
| `setTerminalsAllowed(uint256 projectId)` | Returns whether a project's terminals can currently be set. (`IJBDirectoryAccessControl`) |

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
| `16` | `SET_PRIMARY_TERMINAL` | `JBDirectory.setPrimaryTerminalOf` |
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
