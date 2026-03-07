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
| `setUriOf(uint256 projectId, string uri)` | Sets the project's metadata URI. |
| `transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 creditCount)` | Transfers credits between addresses (reverts if `pauseCreditTransfers` is set in ruleset). |
| `addPriceFeedFor(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)` | Registers a price feed (requires `allowAddPriceFeed` in ruleset). |
| `migrateController(uint256 projectId, IJBMigratable to)` | Migrates the project to a new controller. Calls `beforeReceiveMigrationFrom`, `migrate`, updates directory, then `afterReceiveMigrationFrom`. |
| `currentRulesetOf(uint256 projectId)` | Returns the current ruleset and unpacked metadata. |
| `upcomingRulesetOf(uint256 projectId)` | Returns the upcoming ruleset and unpacked metadata. |
| `allRulesetsOf(uint256 projectId, uint256 startingId, uint256 size)` | Returns an array of rulesets with metadata, paginated. |
| `pendingReservedTokenBalanceOf(uint256 projectId)` | Returns accumulated reserved tokens not yet distributed. |
| `totalTokenSupplyWithReservedTokensOf(uint256 projectId)` | Returns total supply including pending reserved tokens. |

### JBMultiTerminal

| Function | What it does |
|----------|--------------|
| `pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)` | Pays a project. Mints project tokens to beneficiary based on ruleset weight. Returns token count. |
| `cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address beneficiary, bytes metadata)` | Burns project tokens and reclaims surplus terminal tokens via bonding curve. |
| `sendPayoutsOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut)` | Distributes payouts from the project's balance to its payout split group, up to the payout limit. |
| `useAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut, address payable beneficiary, address payable feeBeneficiary, string memo)` | Withdraws from the project's surplus allowance to a beneficiary. The `feeBeneficiary` receives tokens minted by the fee payment. |
| `addToBalanceOf(uint256 projectId, address token, uint256 amount, bool shouldReturnHeldFees, string memo, bytes metadata)` | Adds funds to a project's balance without minting tokens. Can unlock held fees. |
| `migrateBalanceOf(uint256 projectId, address token, IJBTerminal to)` | Migrates a project's token balance to another terminal. Requires `allowTerminalMigration`. |
| `processHeldFeesOf(uint256 projectId, address token, uint256 count)` | Processes up to `count` held fees for a project, sending them to the fee beneficiary project. |
| `addAccountingContextsFor(uint256 projectId, JBAccountingContext[] accountingContexts)` | Adds new accounting contexts (token types) to a terminal for a project. |
| `currentSurplusOf(uint256 projectId, JBAccountingContext[] accountingContexts, uint256 decimals, uint256 currency)` | Returns the project's current surplus in the specified currency. |
| `accountingContextForTokenOf(uint256 projectId, address token)` | Returns the accounting context for a specific token. |
| `accountingContextsOf(uint256 projectId)` | Returns all accounting contexts for a project. |
| `heldFeesOf(uint256 projectId, address token, uint256 count)` | Returns up to `count` held fees for a project/token. |

### JBTerminalStore

| Function | What it does |
|----------|--------------|
| `recordPaymentFrom(address payer, JBTokenAmount amount, uint256 projectId, address beneficiary, bytes metadata)` | Records a payment. Applies data hook if enabled. Returns ruleset, token count, hook specifications. |
| `recordPayoutFor(uint256 projectId, JBAccountingContext accountingContext, uint256 amount, uint256 currency)` | Records a payout. Enforces payout limits. Returns ruleset and amount paid out. |
| `recordCashOutFor(address holder, uint256 projectId, uint256 cashOutCount, JBAccountingContext accountingContext, JBAccountingContext[] balanceAccountingContexts, bytes metadata)` | Records a cash out. Computes reclaim via bonding curve. Returns ruleset, reclaim amount, tax rate, and hook specifications. |
| `recordUsedAllowanceOf(uint256 projectId, JBAccountingContext accountingContext, uint256 amount, uint256 currency)` | Records surplus allowance usage. Enforces allowance limits. Returns ruleset and used amount. |
| `recordAddedBalanceFor(uint256 projectId, address token, uint256 amount)` | Records funds added to a project's balance. |
| `recordTerminalMigration(uint256 projectId, address token)` | Records a terminal migration, returning the full balance. |
| `balanceOf(address terminal, uint256 projectId, address token)` | Returns the balance of a project at a terminal for a given token. |
| `usedPayoutLimitOf(address terminal, uint256 projectId, address token, uint256 rulesetCycleNumber, uint256 currency)` | Returns the used payout limit for a project in a given cycle. |
| `usedSurplusAllowanceOf(address terminal, uint256 projectId, address token, uint256 rulesetId, uint256 currency)` | Returns the used surplus allowance for a project in a given ruleset. |
| `currentSurplusOf(address terminal, uint256 projectId, JBAccountingContext[] accountingContexts, uint256 decimals, uint256 currency)` | Returns the current surplus for a project at a terminal. |

### JBRulesets

| Function | What it does |
|----------|--------------|
| `currentOf(uint256 projectId)` | Returns the currently active ruleset with decayed weight and correct cycle number. |
| `latestQueuedOf(uint256 projectId)` | Returns the latest queued ruleset and its approval status. |
| `queueFor(uint256 projectId, uint256 duration, uint256 weight, uint256 weightCutPercent, IJBRulesetApprovalHook approvalHook, uint256 metadata, uint256 mustStartAtOrAfter)` | Queues a new ruleset. Only callable by the project's controller. |
| `updateRulesetWeightCache(uint256 projectId)` | Updates the weight cache for long-running rulesets. Required when `weightCutMultiple > 20,000` to avoid gas limits. |

### JBPermissions

| Function | What it does |
|----------|--------------|
| `setPermissionsFor(address account, JBPermissionsData permissionsData)` | Grants or revokes operator permissions. ROOT operators can set non-ROOT permissions for others. |
| `hasPermission(address operator, address account, uint256 projectId, uint256 permissionId)` | Checks if an operator has a specific permission. |
| `hasPermissions(address operator, address account, uint256 projectId, uint256[] permissionIds)` | Checks if an operator has all specified permissions. |

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

### JBSplits

| Function | What it does |
|----------|--------------|
| `splitsOf(uint256 projectId, uint256 rulesetId, uint256 groupId)` | Returns splits for a project/ruleset/group. Falls back to ruleset ID 0 if none set. |

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
| `JBBeforeCashOutRecordedContext` | `terminal`, `holder`, `projectId`, `rulesetId`, `cashOutCount`, `totalSupply`, `surplus (JBTokenAmount)`, `useTotalSurplus`, `cashOutTaxRate`, `metadata` | `IJBRulesetDataHook.beforeCashOutRecordedWith()` input |
| `JBAfterPayRecordedContext` | `payer`, `projectId`, `rulesetId`, `amount (JBTokenAmount)`, `forwardedAmount (JBTokenAmount)`, `weight`, `newlyIssuedTokenCount`, `beneficiary`, `hookMetadata`, `payerMetadata` | `IJBPayHook.afterPayRecordedWith()` input |
| `JBAfterCashOutRecordedContext` | `holder`, `projectId`, `rulesetId`, `cashOutCount`, `reclaimedAmount (JBTokenAmount)`, `forwardedAmount (JBTokenAmount)`, `cashOutTaxRate`, `beneficiary`, `hookMetadata`, `cashOutMetadata` | `IJBCashOutHook.afterCashOutRecordedWith()` input |
| `JBPayHookSpecification` | `hook (IJBPayHook)`, `amount`, `metadata` | Returned by data hook; specifies which pay hooks to call and how much to forward |
| `JBCashOutHookSpecification` | `hook (IJBCashOutHook)`, `amount`, `metadata` | Returned by data hook; specifies which cash out hooks to call and how much to forward |
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
| `projectId = 0` | `JBPermissionsData` | Wildcard: permission applies to ALL projects. Cannot be combined with ROOT (255). |
| `permissionId = 255` | `JBPermissions` | ROOT: grants all permissions for the scoped project. |
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
- `JBProjects` constructor optionally mints project #1 to `feeProjectOwner` -- if `address(0)`, no fee project is created
- `JBMultiTerminal` derives `DIRECTORY` and `RULESETS` from the provided `store` in its constructor -- not passed directly
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

## Example Integration

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
