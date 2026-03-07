# nana-core-v6

## Purpose

The core Juicebox V6 protocol on EVM: a modular system for launching treasury-backed tokens with configurable rulesets that govern payments, payouts, cash outs, and token issuance.

## Contracts

| Contract | Role |
|----------|------|
| `JBProjects` | ERC-721 project registry. Each NFT mint creates a new project ID. |
| `JBPermissions` | Packed `uint256` bitmap permissions. Operators get specific permission IDs scoped to projects. |
| `JBDirectory` | Maps project IDs to their controller (`IERC165`) and terminals (`IJBTerminal[]`). |
| `JBController` | Orchestrates rulesets, tokens, splits, fund access limits. Entry point for project lifecycle. |
| `JBMultiTerminal` | Handles ETH/ERC-20 payments, cash outs, payouts, surplus allowance, fees. |
| `JBTerminalStore` | Bookkeeping: balances, payout limit tracking, surplus calculation, bonding curve reclaim math. |
| `JBRulesets` | Stores/cycles rulesets with weight decay, approval hooks, and weight cache for gas-efficient long-running cycles. |
| `JBTokens` | Dual-balance system: credits (internal) + ERC-20. Credits burned first on burn. |
| `JBSplits` | Split configurations per project/ruleset/group. Packed storage for gas efficiency. |
| `JBFundAccessLimits` | Payout limits and surplus allowances per project/ruleset/terminal/token. |
| `JBPrices` | Price feed registry with project-specific and protocol-wide default feeds. |
| `JBERC20` | Cloneable ERC-20 with Votes + Permit. Owned by `JBTokens`. |
| `JBFeelessAddresses` | Allowlist for fee-exempt addresses. |
| `JBChainlinkV3PriceFeed` | Chainlink AggregatorV3 price feed with staleness threshold. |
| `JBChainlinkV3SequencerPriceFeed` | L2 sequencer-aware Chainlink feed (Optimism/Arbitrum). |
| `JBDeadline` | Approval hook: rejects rulesets queued within `DURATION` seconds of start. |
| `JBMatchingPriceFeed` | Always returns 1:1. For equivalent currencies. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `launchProjectFor(address owner, string uri, JBRulesetConfig[] rulesetConfigs, JBTerminalConfig[] terminalConfigs, string memo)` | `JBController` | Creates a project, queues its first rulesets, and configures terminals. Returns `projectId`. |
| `launchRulesetsFor(uint256 projectId, JBRulesetConfig[] rulesetConfigs, JBTerminalConfig[] terminalConfigs, string memo)` | `JBController` | Launches the first rulesets for an existing project that has none. |
| `queueRulesetsOf(uint256 projectId, JBRulesetConfig[] rulesetConfigs, string memo)` | `JBController` | Queues new rulesets for a project. Takes effect after the current ruleset ends (or immediately if duration is 0). |
| `mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary, string memo, bool useReservedPercent)` | `JBController` | Mints project tokens. Requires `allowOwnerMinting` in the current ruleset or caller must be a terminal/hook. |
| `burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string memo)` | `JBController` | Burns tokens from a holder. Requires holder's permission (`BURN_TOKENS`). |
| `sendReservedTokensToSplitsOf(uint256 projectId)` | `JBController` | Distributes accumulated reserved tokens to the reserved token split group. Returns token count sent. |
| `deployERC20For(uint256 projectId, string name, string symbol, bytes32 salt)` | `JBController` | Deploys a cloneable `JBERC20` for the project. Credits become claimable. |
| `claimTokensFor(address holder, uint256 projectId, uint256 count, address beneficiary)` | `JBController` | Redeems credits for ERC-20 tokens into beneficiary's wallet. |
| `pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata)` | `JBMultiTerminal` | Pays a project. Mints project tokens to beneficiary based on ruleset weight. Returns token count. |
| `cashOutTokensOf(address holder, uint256 projectId, uint256 cashOutCount, address tokenToReclaim, uint256 minTokensReclaimed, address beneficiary, bytes metadata)` | `JBMultiTerminal` | Burns project tokens and reclaims surplus terminal tokens via bonding curve. |
| `sendPayoutsOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut)` | `JBMultiTerminal` | Distributes payouts from the project's balance to its payout split group, up to the payout limit. |
| `useAllowanceOf(uint256 projectId, address token, uint256 amount, uint256 currency, uint256 minTokensPaidOut, address beneficiary, string memo)` | `JBMultiTerminal` | Withdraws from the project's surplus allowance to a beneficiary. |
| `addToBalanceOf(uint256 projectId, address token, uint256 amount, bool shouldReturnHeldFees, string memo, bytes metadata)` | `JBMultiTerminal` | Adds funds to a project's balance without minting tokens. Can unlock held fees. |
| `migrateBalanceOf(uint256 projectId, address token, IJBTerminal to)` | `JBMultiTerminal` | Migrates a project's token balance to another terminal. Requires `allowTerminalMigration`. |
| `currentOf(uint256 projectId)` | `JBRulesets` | Returns the currently active ruleset with decayed weight and correct cycle number. |
| `queueFor(uint256 projectId, uint256 duration, uint256 weight, uint256 weightCutPercent, IJBRulesetApprovalHook approvalHook, uint256 metadata, uint256 mustStartAtOrAfter)` | `JBRulesets` | Queues a new ruleset. Only callable by the project's controller. |
| `setPermissionsFor(address account, JBPermissionsData permissionsData)` | `JBPermissions` | Grants or revokes operator permissions. ROOT operators can set non-ROOT permissions. |
| `addPriceFeedFor(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed)` | `JBPrices` | Registers a price feed. Project ID 0 sets protocol-wide defaults (owner-only). |
| `pricePerUnitOf(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, uint256 decimals)` | `JBPrices` | Returns the price of 1 `unitCurrency` in `pricingCurrency`. Checks project-specific, inverse, then default feeds. |
| `setFeelessAddress(address addr, bool flag)` | `JBFeelessAddresses` | Adds or removes an address from the fee exemption list. Owner-only. |

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
| `JBApprovalStatus` (enum) | `Empty`, `Upcoming`, `Active`, `ApprovalExpected`, `Approved`, `Failed` | Approval hook status for queued rulesets |

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
