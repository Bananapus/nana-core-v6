# nana-core-v6 Changelog (v5 -> v6)

This document describes all changes between `nana-core` (v5, Solidity 0.8.23) and `nana-core-v6` (v6, Solidity 0.8.28).

## Summary

- **Preview APIs**: New `previewPayFor` and `previewCashOutFrom` view functions on terminal and store for simulating payments/cashouts without state changes.
- **Fee-free cashout bypass closed**: Intra-terminal payouts now tracked via `_feeFreeSurplusOf` to prevent round-trip fee evasion through zero-tax cashouts.
- **Approval hook hardening**: Reverting approval hooks now return `Failed` status instead of propagating, preventing permanent project freezing.
- **Weight cache overhaul**: Cache threshold raised from 1,000 to 20,000 iterations; exceeding the threshold now reverts instead of silently iterating.
- **Token metadata now mutable**: New `setTokenMetadataOf` allows changing a project token's name and symbol post-deployment.

---

## 0. Post-Release Changes

### 0.1 JBSplits -- Self-Auth GroupId Restriction

`setSplitGroupsOf` self-auth now requires the upper 96 bits of the `groupId` to be non-zero. The full self-auth check is: `uint160(groupId) == msg.sender && groupId >> 160 != 0`. GroupIds with zero upper 96 bits (bare addresses like `uint256(uint160(tokenAddress))`) are protocol-reserved for terminal payout groups and always require controller authorization. This prevents accepted token contracts from writing a project's payout splits without controller auth. The 721 hook is unaffected since it already uses `hookAddress | tierId << 160` (non-zero upper bits).

### 0.2 JBMultiTerminal -- Fee-Free Cashout Bypass Prevention

A new `_feeFreeSurplusOf` mapping (`projectId => token => uint256`) tracks cumulative fee-free intra-terminal payouts received by each project. When a split payout lands on the same terminal (intra-terminal routing, i.e. `terminal == this`), the net payout amount is added to `_feeFreeSurplusOf[projectId][token]`. After any outflow (payouts via `sendPayoutsOf`, surplus allowance via `useAllowanceOf`, non-zero-tax or feeless cashouts), the counter is capped at the remaining balance — non-fee-free funds are considered to leave first, preserving the fee-free counter as long as possible. During a cashout with `cashOutTaxRate == 0`, fees are charged on the reclaim amount up to the tracked fee-free surplus (and the tracker is decremented accordingly). Cashouts beyond the fee-free surplus remain fee-free. The counter is cleared on terminal migration. This closes a round-trip fee bypass where funds could be routed fee-free into a project via an intra-terminal split payout and then cashed out fee-free via a zero-tax cashout.

### 0.3 JBBeforeCashOutRecordedContext -- beneficiaryIsFeeless Field

A `bool beneficiaryIsFeeless` field was added to the `JBBeforeCashOutRecordedContext` struct (before the `metadata` field). `recordCashOutFor` in `IJBTerminalStore` gained a corresponding `bool beneficiaryIsFeeless` parameter. The terminal passes the result of its feeless address check, allowing data hooks to skip their own fees when the beneficiary is already feeless (e.g., project-to-project routing via the router terminal). This is a **breaking change** to both the struct layout and the `recordCashOutFor` function signature.

### 0.4 JBTerminalStore -- Preview Functions

Two `view` functions on `JBTerminalStore` and `IJBTerminalStore`:

- `previewPayFrom(address terminal, address payer, JBTokenAmount amount, uint256 projectId, address beneficiary, bytes metadata)` -- Simulates a payment and returns `(JBRuleset ruleset, uint256 tokenCount, JBPayHookSpecification[] hookSpecifications)`. Uses the explicit `terminal` parameter for balance/surplus lookups. Invokes data hooks if configured. Does not modify state.
- `previewCashOutFrom(address terminal, address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, bool beneficiaryIsFeeless, bytes metadata)` -- Simulates a cash out and returns `(JBRuleset ruleset, uint256 reclaimAmount, uint256 cashOutTaxRate, JBCashOutHookSpecification[] hookSpecifications)`. Uses the explicit `terminal` parameter for balance/surplus lookups. Invokes data hooks if configured. Does not modify state.

Internal computation logic was extracted into shared `_computePayFrom` and `_computeCashOutFrom` view helpers; the existing `recordPaymentFrom` and `recordCashOutFor` functions were refactored to call these helpers before writing state.

### 0.5 Terminal-Level Preview APIs

New `view` functions on `JBMultiTerminal`, `JBController`, and their interfaces provide user-facing preview entry points that compose the store-level previews with the mint token split:

- `JBMultiTerminal.previewPayFor(uint256 projectId, address token, uint256 amount, address beneficiary, bytes metadata)` -- Simulates a full payment including the reserved/beneficiary token split. Calls `STORE.previewPayFrom` then `controller.previewMintOf`. Returns `(JBRuleset ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount, JBPayHookSpecification[] hookSpecifications)`.
- `JBMultiTerminal.previewCashOutFrom(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, address beneficiary, bytes metadata)` -- Simulates a full cash out. Resolves accounting context internally and delegates to `STORE.previewCashOutFrom`. Returns `(JBRuleset ruleset, uint256 reclaimAmount, uint256 cashOutTaxRate, JBCashOutHookSpecification[] hookSpecifications)`.
- `JBController.previewMintOf(uint256 projectId, uint256 tokenCount, bool useReservedPercent)` -- Previews how a mint splits between beneficiary and reserved tokens under the current ruleset. Returns `(uint256 beneficiaryTokenCount, uint256 reservedTokenCount)`.

Also in this release:
- **Error consolidation**: Three separate `UnderMin*` errors on `JBMultiTerminal` consolidated into a single `JBMultiTerminal_UnderMin()` error for bytecode size reduction.
- **`via_ir = true`**: Added to `foundry.toml` to enable the Solidity IR optimizer pipeline, reducing deployed bytecode size (EIP-170 compliance).
- Internal helpers extracted: `_accountingContextOf` and `_tokenAmountOf` on `JBMultiTerminal`, `_splitTokenCount` on `JBController`.

### 0.6 JBMultiTerminal -- Migration Fee

`migrateBalanceOf` now charges the standard 2.5% protocol fee when migrating to a non-feeless terminal, consistent with all other fund egress. This also settles any `_feeFreeSurplusOf` liability that would otherwise be lost on the new terminal. The fee is deducted from the migrated balance before transfer. Feeless terminals are exempt.

### 0.7 JBMultiTerminal -- Self-Pay Revert

`_pay` now reverts with `JBMultiTerminal_MintNotAllowed()` when `payer == address(this)`. This prevents same-project intra-terminal payout splits (where `preferAddToBalance == false`) from minting tokens against existing balance without new funds entering the system. The try-catch in `JBPayoutSplitGroupLib` catches this revert and restores the balance via `recordAddedBalanceFor`. Projects that want to mint should do so explicitly via the controller.

---

## 1. Breaking Changes

### 1.1 Interface Signature Changes

#### IJBRulesets

| Change | v5 | v6 |
|--------|----|----|
| `updateRulesetWeightCache` signature | `updateRulesetWeightCache(uint256 projectId)` | `updateRulesetWeightCache(uint256 projectId, uint256 rulesetId)` |

A `rulesetId` parameter was added. Callers must now specify which ruleset to cache the weight for. This should be the ruleset that `currentOf()` actually uses (which may differ from `latestRulesetIdOf` if the latest was rejected by an approval hook).

#### IJBTerminalStore

| Change | v5 | v6 |
|--------|----|----|
| `currentReclaimableSurplusOf` parameter rename | `uint256 tokenCount` (4-param overload) | `uint256 cashOutCount` |
| `recordCashOutFor` new parameter | No `beneficiaryIsFeeless` parameter | `bool beneficiaryIsFeeless` added after `balanceAccountingContexts` |

The parameter was renamed from `tokenCount` to `cashOutCount` in the simple 4-parameter overload.

`recordCashOutFor` gained a `bool beneficiaryIsFeeless` parameter so the terminal can pass through its feeless address check to data hooks via the `JBBeforeCashOutRecordedContext` struct.

#### IJBPayoutTerminal

| Change | v5 | v6 |
|--------|----|----|
| `sendPayoutsOf` return value | `returns (uint256 netLeftoverPayoutAmount)` | `returns (uint256 amountPaidOut)` |

The return variable name was corrected from `netLeftoverPayoutAmount` to `amountPaidOut` to match the actual implementation semantics (total amount paid out). The v5 implementation already returned the total amount from `STORE.recordPayoutFor()`, not the leftover — only the interface had the misleading name.

#### IJBController

| Change | v5 | v6 |
|--------|----|----|
| `launchProjectFor` terminal configs | `JBTerminalConfig[] memory terminalConfigurations` | `JBTerminalConfig[] calldata terminalConfigurations` |
| `launchRulesetsFor` terminal configs | `JBTerminalConfig[] memory terminalConfigurations` | `JBTerminalConfig[] calldata terminalConfigurations` |

Parameters changed from `memory` to `calldata` for gas efficiency.
> **Cross-repo impact**: The `calldata` change affects `nana-omnichain-deployers-v6` and `revnet-core-v6`, which call `launchProjectFor`/`launchRulesetsFor`.

#### IJBSplits

| Change | v5 | v6 |
|--------|----|----|
| `setSplitGroupsOf` splits param | `JBSplitGroup[] memory splitGroups` | `JBSplitGroup[] calldata splitGroups` |

#### IJBFundAccessLimits

| Change | v5 | v6 |
|--------|----|----|
| `setFundAccessLimitsFor` param | `JBFundAccessLimitGroup[] memory fundAccessLimitGroups` | `JBFundAccessLimitGroup[] calldata fundAccessLimitGroups` |

### 1.2 Removed Errors

| Contract | v5 Error | v6 Replacement |
|----------|----------|----------------|
| `JBMultiTerminal` | `JBMultiTerminal_ZeroAccountingContextDecimals()` | `JBMultiTerminal_AccountingContextDecimalsMismatch()` |

---

## 2. New Features

### 2.1 New Functions

#### IJBController / JBController

| Function | Description |
|----------|-------------|
| `setTokenMetadataOf(uint256 projectId, string name, string symbol)` | Sets the name and symbol of a project's ERC-20 token. Requires the `SET_TOKEN_METADATA` permission. |
| `afterReceiveMigrationFrom(IERC165 from, uint256 projectId)` | Called by the directory after this controller has been set as the active controller. Added to the `IJBMigratable` interface. |

#### IJBTerminalStore / JBTerminalStore

| Function | Description |
|----------|-------------|
| `currentTotalReclaimableSurplusOf(uint256 projectId, uint256 cashOutCount, uint256 decimals, uint256 currency)` | Convenience view that returns the reclaimable surplus across all terminals using all tokens. Delegates to `currentReclaimableSurplusOf` with empty `terminals` and `tokens` arrays. Mirrors the `currentTotalSurplusOf` pattern. |

#### IJBTokens / JBTokens

| Function | Description |
|----------|-------------|
| `setTokenMetadataFor(uint256 projectId, string name, string symbol)` | Sets the name and symbol of a project's token. Only callable by the project's controller. |

#### IJBToken / JBERC20

| Function | Description |
|----------|-------------|
| `setMetadata(string name, string symbol)` | Sets the token's name and symbol. Only callable by the token's owner (JBTokens). |

#### IJBMigratable

| Function | Description |
|----------|-------------|
| `afterReceiveMigrationFrom(IERC165 from, uint256 projectId)` | New lifecycle hook called after a controller migration completes. |

#### JBCashOuts (Library)

| Function | Description |
|----------|-------------|
| `minCashOutCountFor(uint256 surplus, uint256 desiredOutput, uint256 totalSupply, uint256 cashOutTaxRate)` | Inverse bonding curve: returns the minimum number of tokens to cash out to receive at least `desiredOutput`. Uses binary search for the general case. |

### 2.2 New Events

| Contract | Event |
|----------|-------|
| `IJBTokens` | `SetTokenMetadata(uint256 indexed projectId, string name, string symbol, address caller)` |
| `IJBPermitTerminal` | `Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason)` |

### 2.3 New Errors

| Contract | Error |
|----------|-------|
| `JBController` | `JBController_TerminalTokensNotTransferred()` |
| `JBMultiTerminal` | `JBMultiTerminal_AccountingContextDecimalsMismatch()` |
| `JBRulesets` | `JBRulesets_WeightCacheRequired(uint256 projectId)` |
| `JBTerminalStore` | `JBTerminalStore_Uint224Overflow(uint256 value)` |
| `JBCashOuts` | `JBCashOuts_DesiredOutputNotAchievable()` |
| `JBERC20` | `JBERC20_AlreadyInitialized()` |

### 2.4 New Permission IDs

| Permission | Description |
|------------|-------------|
| `LAUNCH_RULESETS` | Required for `launchRulesetsFor`. In v5, `QUEUE_RULESETS` was used. |
| `SET_TOKEN_METADATA` | Required for `setTokenMetadataOf`. |
> **Cross-repo impact**: `nana-permission-ids-v6` defines these new IDs. `nana-omnichain-deployers-v6` and `revnet-core-v6` use `LAUNCH_RULESETS` for their deployment flows.

---

## 3. Event Changes

### 3.0 Indexer Notes

For subgraph migrations, this repo is the protocol-level anchor:
- when an event signature gains parameters, prefer widening the existing entity schema instead of treating it as an unrelated event stream;
- preview/noop behavior in core-v6 means some routing diagnostics now come from returned hook specs rather than only from emitted callback events;
- if your v5 graph correlated protocol actions to hook callbacks only, re-check those assumptions against v6 preview/noop patterns.

### 3.1 New Events

See section 2.2 above.

### 3.2 Modified Events

| Contract | Event | Change |
|----------|-------|--------|
| `IJBCashOutTerminal` | `CashOutTokens` | Event order changed in the interface (moved before `HookAfterRecordCashOut`); NatSpec added. No field changes. |
| `IJBCashOutTerminal` | `HookAfterRecordCashOut` | Event order changed in the interface (moved after `CashOutTokens`); NatSpec added. No field changes. |

### 3.3 All Interfaces Gained NatSpec

Every interface file in v6 has comprehensive NatSpec documentation added to all functions, events, errors, and return values. This is a documentation-only change that does not affect the ABI.

---

## 4. Error Changes

### 4.1 Errors with Added Parameters (More Informative Reverts)

| Contract | v5 | v6 |
|----------|----|----|
| `JBController` | `JBController_AddingPriceFeedNotAllowed()` | `JBController_AddingPriceFeedNotAllowed(uint256 projectId)` |
| `JBController` | `JBController_MintNotAllowedAndNotTerminalOrHook()` | `JBController_MintNotAllowedAndNotTerminalOrHook(address caller)` |
| `JBController` | `JBController_RulesetsAlreadyLaunched()` | `JBController_RulesetsAlreadyLaunched(uint256 projectId)` |
| `JBController` | `JBController_RulesetSetTokenNotAllowed()` | `JBController_RulesetSetTokenNotAllowed(uint256 projectId)` |
| `JBMultiTerminal` | `JBMultiTerminal_FeeTerminalNotFound()` | `JBMultiTerminal_FeeTerminalNotFound(address token)` |
| `JBMultiTerminal` | `JBMultiTerminal_TerminalTokensIncompatible()` | `JBMultiTerminal_TerminalTokensIncompatible(uint256 projectId, address token, IJBTerminal terminal)` |
| `JBDirectory` | `JBDirectory_SetControllerNotAllowed()` | `JBDirectory_SetControllerNotAllowed(uint256 projectId)` |
| `JBDirectory` | `JBDirectory_SetTerminalsNotAllowed()` | `JBDirectory_SetTerminalsNotAllowed(uint256 projectId)` |
| `JBSplits` | `JBSplits_PreviousLockedSplitsNotIncluded()` | `JBSplits_PreviousLockedSplitsNotIncluded(uint256 projectId, uint256 rulesetId)` |
| `JBTokens` | `JBTokens_EmptyToken()` | `JBTokens_EmptyToken(uint256 projectId)` |
| `JBTerminalStore` | `JBTerminalStore_RulesetNotFound()` | `JBTerminalStore_RulesetNotFound(uint256 projectId)` |
| `JBPermissions` | `JBPermissions_Unauthorized()` | `JBPermissions_Unauthorized(address account, address operator, uint256 projectId, uint256 permissionId)` |

### 4.2 Renamed Errors

| Contract | v5 | v6 |
|----------|----|----|
| `JBMultiTerminal` | `JBMultiTerminal_ZeroAccountingContextDecimals()` | `JBMultiTerminal_AccountingContextDecimalsMismatch()` |

### 4.3 Removed Errors

| Contract | Error | Notes |
|----------|-------|-------|
| `JBMultiTerminal` | `JBMultiTerminal_ZeroAccountingContextDecimals()` | Replaced by `AccountingContextDecimalsMismatch` |

### 4.4 New Errors

See section 2.3 above.

---

## 5. Struct Changes

All structs are identical between v5 and v6 except:

| Struct | Change |
|--------|--------|
| `JBBeforeCashOutRecordedContext` | New `bool beneficiaryIsFeeless` field added before `metadata`. Indicates whether the cash out's beneficiary is a feeless address, allowing data hooks to skip their own fees for in-protocol routing. |

Other struct-level differences (non-functional):
- `forge-lint: disable-next-line(pascal-case-struct)` comments added to all struct definitions.
- `JBSplit`: Additional NatSpec documentation on the `beneficiary` field behavior when set to `address(0)`.

---

## 6. Enum Changes

`JBApprovalStatus` is **identical** between v5 and v6.

---

## 7. Library Changes

### JBCashOuts

| Change | Description |
|--------|-------------|
| **New function** `minCashOutCountFor` | Inverse bonding curve calculation using binary search. Returns the minimum tokens to cash out for a desired output. |
| **New error** `JBCashOuts_DesiredOutputNotAchievable` | Thrown when the cash out tax rate is 100% and no output is possible. |
| **Bug fix**: Early return for zero `cashOutCount` | `cashOutFrom` now returns `0` immediately when `cashOutCount == 0` (v5 would compute with zero). |

### JBMetadataResolver

| Change | Description |
|--------|-------------|
| Assembly blocks marked `"memory-safe"` | All inline assembly blocks now use the `assembly ("memory-safe")` annotation. |
| **Bug fix**: `_sliceBytes` copy loop | The loop bound changed from `end` (absolute source offset) to `length` (relative), preventing over-copy past the allocated buffer. |
| **Bug fix**: Overflow protection | Offset increment now checks for `> 255` overflow before casting to `uint8`, reverting with `JBMetadataResolver_MetadataTooLong()`. |
| **Bug fix**: Memory alignment | Free memory pointer in `_sliceBytes` now rounds up to 32-byte boundary to prevent overlapping allocations. |
| Empty input handling | `createMetadata` now returns empty bytes for empty input arrays. |
| Named parameters in `_sliceBytes` calls | All calls now use named parameters (`data:`, `start:`, `end:`). |

### JBRulesetMetadataResolver

| Change | Description |
|--------|-------------|
| Bit 77 comment fix | Changed from "allow controller migration" to "owner must send payouts" to match actual bit semantics. |
| `baseCurrency` range comment fix | Changed from `0-16777215` (24-bit) to `0-4294967295` (32-bit). |
| `currency` range comment fix | Changed from `0-4294967296` to `0-4294967295`. |
| Named field syntax | `expandMetadata()` now uses named field syntax (`reservedPercent:`, etc.) instead of positional. |

### JBFees

| Change | Description |
|--------|-------------|
| NatSpec improvements | Clarified that `feeAmountFrom` forward-calculates and `feeAmountIn` back-calculates. Added documentation about rounding bounds. |

### JBSurplus

| Change | Description |
|--------|-------------|
| Typo fix | `termainls` -> `terminals`. |

### JBConstants, JBFixedPointNumber, JBSplitGroupIds, JBCurrencyIds

No changes.

---

## 8. Implementation Changes (Non-Interface)

### 8.1 JBController

| Change | Description |
|--------|-------------|
| **Migration lifecycle** | `afterReceiveMigrationFrom` added — called by directory after migration completes (validates caller is directory). |
| **`launchRulesetsFor` permission** | Changed from `QUEUE_RULESETS` to `LAUNCH_RULESETS`. |
| **Split token transfer assertion** | `assert(allowance == 0)` replaced with explicit `revert JBController_TerminalTokensNotTransferred()`. |
| **Code organization** | External views moved after external transactions. Internal views moved to end of file. |

### 8.2 JBMultiTerminal

| Change | Description |
|--------|-------------|
| **Decimal validation** | `ZeroAccountingContextDecimals` renamed to `AccountingContextDecimalsMismatch`. Non-standard ERC-20s that revert on `decimals()` bypass validation (documented). |
| **Permit2 failure event** | Failed Permit2 allowance approvals now emit `Permit2AllowanceFailed` instead of silently catching. |
| **Migration held fees** | Migration intentionally does not transfer held fees (documented: held fees belong to fee beneficiary, not the migrating project). |
| **Held fee processing (reentrancy hardening)** | `processHeldFeesOf` now re-reads the storage index each iteration (instead of caching), deletes the entry before the external call, and updates the index before the external call. |
| **Split payout documentation** | Failed split payouts documented as consuming payout limit by design. |
| **Fee-free cashout bypass prevention** | New `_feeFreeSurplusOf` mapping tracks cumulative fee-free intra-terminal payouts per project/token. Capped at remaining balance after outflows including non-zero-tax/feeless cashouts (non-fee-free funds leave first). During zero-tax cashouts, fees are charged up to this tracked amount (then decremented). Cleared on migration. See Section 0.2. |
| **beneficiaryIsFeeless passthrough** | `cashOutTokensOf` now passes `_isFeeless(beneficiary)` to `recordCashOutFor`, which forwards it to data hooks via `JBBeforeCashOutRecordedContext.beneficiaryIsFeeless`. |

### 8.3 JBRulesets

| Change | Description |
|--------|-------------|
| **Cache threshold** | `_WEIGHT_CUT_MULTIPLE_CACHE_LOOKUP_THRESHOLD` increased from `1,000` to `20,000`. |
| **Cache cap removed** | `_MAX_WEIGHT_CUT_MULTIPLE_CACHE_THRESHOLD` (`50,000`) removed entirely. |
| **Weight cache required** | `_deriveWeightFrom` now reverts with `JBRulesets_WeightCacheRequired(projectId)` when iteration count exceeds the threshold, instead of silently iterating. |
| **Approval hook try/catch** | `_approvalStatusOf` now wraps the external `approvalHook.approvalStatusOf()` call in a try/catch. A reverting approval hook returns `JBApprovalStatus.Failed` instead of propagating the revert. This prevents a malicious or buggy approval hook from permanently freezing a project. |

### 8.4 JBDirectory

| Change | Description |
|--------|-------------|
| **Migration ordering** | `setControllerOf` now calls `migrate()` on the old controller BEFORE updating `controllerOf` in storage (so `migrate()` runs while the directory still points to the old controller). After updating storage, it calls `afterReceiveMigrationFrom` on the new controller. |

### 8.5 JBSplits

| Change | Description |
|--------|-------------|
| **Stale storage cleanup** | `_setSplitsOf` now deletes stale packed split data when the new split count is smaller than the previous count, preventing leftover storage from prior configurations. |

### 8.6 JBTokens

| Change | Description |
|--------|-------------|
| **Overflow check timing** | `mintFor` now checks `totalSupplyOf(projectId) + count > type(uint208).max` BEFORE minting (v5 checked after). |

### 8.7 JBERC20

| Change | Description |
|--------|-------------|
| **Named revert** | `initialize()` now reverts with `JBERC20_AlreadyInitialized()` instead of a bare `revert()`. |

### 8.8 JBChainlinkV3PriceFeed

| Change | Description |
|--------|-------------|
| **Incomplete round check order** | The check for `updatedAt == 0` (incomplete round) now runs BEFORE the stale price check, avoiding false stale errors on incomplete rounds. |

### 8.9 JBChainlinkV3SequencerPriceFeed

| Change | Description |
|--------|-------------|
| **Typo fix** | Error parameter `gradePeriodTime` corrected to `gracePeriodTime` in `JBChainlinkV3SequencerPriceFeed_SequencerDown`. |
| **Threshold docs** | Constructor parameter `threshold` documentation corrected from "blocks" to "seconds". |

### 8.10 Solidity Version

All contracts upgraded from `pragma solidity 0.8.23` to `pragma solidity 0.8.28`.

### 8.11 Named Arguments

Throughout the codebase, function calls were updated to use named argument syntax (e.g., `foo({bar: 1, baz: 2})`) for improved readability.

---

## 9. Migration Table

### Interfaces

| v5 | v6 | Notes |
|----|----|-------|
| `IJBController` | `IJBController` | Gained `setTokenMetadataOf`. `calldata` for terminal configs. |
| `IJBRulesets` | `IJBRulesets` | `updateRulesetWeightCache` gained `rulesetId` parameter |
| `IJBTerminalStore` | `IJBTerminalStore` | `tokenCount` renamed to `cashOutCount` in `currentReclaimableSurplusOf`. `recordCashOutFor` gained `beneficiaryIsFeeless` param. New `currentTotalReclaimableSurplusOf` convenience view. View functions reordered. |
| `IJBPayoutTerminal` | `IJBPayoutTerminal` | `sendPayoutsOf` returns `amountPaidOut` (was `netLeftoverPayoutAmount`). `SendPayoutToSplit` event moved. |
| `IJBPermitTerminal` | `IJBPermitTerminal` | Gained `Permit2AllowanceFailed` event |
| `IJBMigratable` | `IJBMigratable` | Gained `afterReceiveMigrationFrom` function |
| `IJBTokens` | `IJBTokens` | Gained `setTokenMetadataFor`, `SetTokenMetadata` event |
| `IJBToken` | `IJBToken` | Gained `setMetadata` function |
| `IJBSplits` | `IJBSplits` | `setSplitGroupsOf` param changed to `calldata` |
| `IJBFundAccessLimits` | `IJBFundAccessLimits` | `setFundAccessLimitsFor` param changed to `calldata` |
| `IJBFeelessAddresses` | `IJBFeelessAddresses` | Param names: `account` -> `addr`. NatSpec added. |
| All other interfaces | Same name | NatSpec documentation added. No functional changes. |

### Contracts

| v5 | v6 | Notes |
|----|----|-------|
| `JBController` | `JBController` | Token metadata, migration lifecycle (`afterReceiveMigrationFrom`), `LAUNCH_RULESETS` permission |
| `JBMultiTerminal` | `JBMultiTerminal` | Reentrancy hardening, decimal validation rename, Permit2 event, fee-free bypass prevention (`_feeFreeSurplusOf`), `beneficiaryIsFeeless` passthrough |
| `JBRulesets` | `JBRulesets` | Approval hook try/catch, weight cache changes, threshold increase |
| `JBDirectory` | `JBDirectory` | Migration ordering fix, afterReceiveMigration call |
| `JBTokens` | `JBTokens` | Token metadata support, overflow check timing |
| `JBERC20` | `JBERC20` | `setMetadata`, named revert |
| `JBDeadline` | `JBDeadline` | No functional changes |
| All others | Same name | Error parameter enrichment, named arguments, NatSpec |

### Libraries

| v5 | v6 | Notes |
|----|----|-------|
| `JBCashOuts` | `JBCashOuts` | Added `minCashOutCountFor` (inverse bonding curve) |
| `JBMetadataResolver` | `JBMetadataResolver` | Memory safety, overflow protection, copy loop fix |
| `JBRulesetMetadataResolver` | `JBRulesetMetadataResolver` | Comment fixes, named field syntax |
| `JBCurrencyIds` | `JBCurrencyIds` | No changes |
| All others | Same name | No changes |

### Structs

| v5 | v6 | Notes |
|----|----|-------|
| All 22 structs | Same names | All identical except `JBBeforeCashOutRecordedContext` (gained `beneficiaryIsFeeless` field). Lint comments added to all. |

### Enums

| v5 | v6 | Notes |
|----|----|-------|
| `JBApprovalStatus` | `JBApprovalStatus` | Identical |
