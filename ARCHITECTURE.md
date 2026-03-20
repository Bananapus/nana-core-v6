# nana-core-v6 — Architecture

## Purpose

Core protocol for Juicebox V6. Provides programmable treasuries with configurable governance, bonding-curve cash outs, split-based payouts, and a compositional hook system.

## Contract Map

```
src/
├── JBMultiTerminal.sol    — Multi-token payment terminal (pay, cash out, payouts, fees)
├── JBController.sol       — Orchestrator (project lifecycle, rulesets, token minting, reserved tokens)
├── JBTerminalStore.sol    — Bookkeeping (balances, payout limits, surplus, bonding curve math)
├── JBRulesets.sol         — Ruleset lifecycle (linked-list, weight decay, approval hooks)
├── JBDirectory.sol        — Routes projects to terminals and controllers
├── JBTokens.sol           — Dual token system (internal credits + ERC-20)
├── JBSplits.sol           — Packed split storage with lock enforcement
├── JBFundAccessLimits.sol — Payout limits and surplus allowances
├── JBPrices.sol           — Price feeds with project-specific + default fallback
├── JBPermissions.sol      — 256-bit packed permission system
├── JBProjects.sol         — ERC-721 project ownership
├── JBERC20.sol            — Cloneable ERC20Votes+Permit token
├── JBFeelessAddresses.sol — Fee-exempt address registry
├── JBDeadline.sol         — Approval hook requiring minimum delay
├── JBChainlinkV3PriceFeed.sol          — Chainlink v3 price feed with staleness check
├── JBChainlinkV3SequencerPriceFeed.sol — L2 sequencer-aware price feed
├── abstract/
│   ├── JBPermissioned.sol — Base for permission-checked contracts
│   └── JBControlled.sol   — Base for controller-gated contracts
└── libraries/
    ├── JBCashOuts.sol              — Bonding curve math
    ├── JBFees.sol                  — Fee calculation (forward/backward)
    ├── JBRulesetMetadataResolver.sol — Bit-packed metadata (256 bits)
    ├── JBMetadataResolver.sol      — Variable-length key-value metadata
    ├── JBFixedPointNumber.sol      — Decimal adjustment
    ├── JBConstants.sol             — Protocol constants
    └── JBSplitGroupIds.sol         — Split group ID constants
```

## Key Data Flows

### Payment Flow

```
User -> JBMultiTerminal.pay()
  -> JBTerminalStore.recordPaymentFrom()
    -> Read current ruleset
    -> [Optional] Data hook overrides weight
    -> Calculate token count from weight
    -> Update balance
  -> JBController.mintTokensOf()
    -> Calculate reserved tokens
    -> Mint beneficiary tokens
    -> Accumulate pendingReservedTokenBalanceOf
  -> [Optional] Pay hooks execute
```

### Cash Out Flow

```
Holder -> JBMultiTerminal.cashOutTokensOf()
  -> JBTerminalStore.recordCashOutFor()
    -> Calculate surplus (all terminals, converted via JBPrices)
    -> Get totalSupply (including pending reserved)
    -> [Optional] Data hook overrides parameters
    -> JBCashOuts.cashOutFrom() — bonding curve
    -> Deduct balance
  -> JBController.burnTokensOf()
  -> Transfer reclaimed tokens to beneficiary
  -> [Optional] Cash out hooks execute
  -> Take fees (2.5% to project #1) if cashOutTaxRate > 0
     OR if cashOutTaxRate == 0 and project has unconsumed fee-free surplus (_feeFreeSurplusOf)
```

### Preview Flow

Every core user action has a `view` counterpart that simulates the operation without modifying state. These compose the same internal computation paths as their non-preview counterparts and include data hook effects.

```
Caller -> JBMultiTerminal.previewPayFor(projectId, token, amount, beneficiary, metadata)
  -> JBTerminalStore.previewPayFrom()
    -> Read current ruleset, apply data hook
    -> Calculate token count from weight
  -> JBController.previewMintOf()
    -> Split token count into beneficiary + reserved portions
  -> Returns (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications)

Caller -> JBMultiTerminal.previewCashOutFrom(holder, projectId, cashOutCount, tokenToReclaim, beneficiary, metadata)
  -> JBTerminalStore.previewCashOutFrom()
    -> Calculate surplus, get totalSupply, apply data hook
    -> JBCashOuts.cashOutFrom() — bonding curve
  -> Returns (ruleset, reclaimAmount, cashOutTaxRate, hookSpecifications)

Caller -> JBController.previewMintOf(projectId, tokenCount, useReservedPercent)
  -> Read current ruleset
  -> Returns (beneficiaryTokenCount, reservedTokenCount)
```

### Payout Flow

```
Owner -> JBMultiTerminal.sendPayoutsOf()
  -> JBTerminalStore.recordPayoutFor()
    -> Deduct balance, check payout limits
  -> Distribute to splits (JBSplits)
    -> Split to project -> pay project's terminal
    -> Split to address -> direct transfer
    -> Split to hook -> IJBSplitHook.processSplitWith()
  -> Take fees on non-feeless payouts
```

## Extension Points

| Extension Point | Interface | Called By |
|----------------|-----------|-----------|
| Data Hook (pay) | `IJBRulesetDataHook.beforePayRecordedWith` | JBTerminalStore |
| Data Hook (cashout) | `IJBRulesetDataHook.beforeCashOutRecordedWith` | JBTerminalStore |
| Pay Hook | `IJBPayHook.afterPayRecordedWith` | JBMultiTerminal |
| Cash Out Hook | `IJBCashOutHook.afterCashOutRecordedWith` | JBMultiTerminal |
| Split Hook | `IJBSplitHook.processSplitWith` | JBMultiTerminal |
| Approval Hook | `IJBRulesetApprovalHook.approvalStatusOf` | JBRulesets |

## Dependencies

- `@bananapus/permission-ids-v6` — Permission ID constants
- `@openzeppelin/contracts` — ERC-721, ERC-20, ERC2771, Clones
- `@prb/math` — Fixed-point math (mulDiv)
- `@chainlink/contracts` — Price feed interfaces
- `@uniswap/permit2` — Permit2 token approvals

## Key Constants

- FEE = 25 (2.5%), MAX_FEE = 1000
- MAX_RESERVED_PERCENT = 10,000 (basis points)
- MAX_CASH_OUT_TAX_RATE = 10,000
- MAX_WEIGHT_CUT_PERCENT = 1,000,000,000 (9 decimals)
- SPLITS_TOTAL_PERCENT = 1,000,000,000
- NATIVE_TOKEN = 0x000000000000000000000000000000000000EEEe
- Fee holding: 28 days (2,419,200 seconds)
- Fee beneficiary: project ID 1
