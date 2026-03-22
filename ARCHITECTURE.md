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

## Design Decisions

**Bonding curve for cash outs.** Cash outs use a bonding curve (`JBCashOuts.cashOutFrom`) rather than a fixed price. The formula — `base * [(MAX - taxRate) + taxRate * (count / supply)] / MAX` — means that cashing out a small fraction of the supply returns close to a proportional share of the surplus, while cashing out a large fraction returns less. This creates a natural disincentive for bank runs: early cash-outs get a fair price, but dumping the entire supply at once cannot drain the treasury. The `cashOutTaxRate` parameter (0 to 10,000) lets each project tune the curve from fully linear (0%) to fully locked (100%). An inverse function (`minCashOutCountFor`) uses binary search to solve for the minimum tokens needed to achieve a desired output.

**256-bit packed permissions.** `JBPermissions` stores all of an operator's permissions for a given account and project in a single `uint256`, with each bit representing one permission ID. This keeps permission checks to a single `SLOAD` plus a bit-shift, regardless of how many permissions an operator holds. A dedicated ROOT permission (bit 1) grants all permissions, and a wildcard project ID (0) grants permissions across all projects. ROOT cannot be set for the wildcard project ID, preventing a single key compromise from escalating to protocol-wide control.

**Dual token system (credits + ERC-20).** `JBTokens` maintains two parallel representations of project tokens: internal credits (stored as simple mappings) and an optional ERC-20 (cloned from `JBERC20` via ERC-1167). Projects start with only credits, which are gas-cheap to mint and require no token deployment. When a project deploys or attaches an ERC-20, holders can claim credits into transferable tokens. Burns consume credits first, then ERC-20 tokens. This lets projects defer the cost and complexity of an ERC-20 until they actually need transferability or DeFi composability.

**Linked-list rulesets.** `JBRulesets` chains rulesets via `basedOnId`, forming a singly linked list from newest to oldest. Each ruleset inherits the previous ruleset's configuration as its base, and new rulesets can only be queued on top of the latest one. When a ruleset expires, the protocol walks the chain to find the most recent approved ruleset to derive the next cycle from. This avoids storing an unbounded array and makes ruleset history traversable without an index. Weight decay across many cycles is optimized with a cache (`_weightCacheOf`) that stores intermediate values, capping iteration at 20,000 per call.

**Compositional hooks vs monolithic.** The protocol separates extension logic into six distinct hook interfaces — data hooks (pay/cashout), action hooks (pay/cashout), split hooks, and approval hooks — each called at a specific point in a flow. Data hooks run inside `JBTerminalStore` and can override pricing parameters (weight, tax rate) before state is recorded. Action hooks run in `JBMultiTerminal` after state is settled and tokens are minted or burned. This separation means a single hook cannot simultaneously manipulate pricing and intercept funds, reducing the attack surface. Projects compose behavior by combining independent hooks rather than deploying a monolithic contract that controls everything.

**Approval hooks for governance.** Rather than hard-coding a timelock or multisig requirement, rulesets point to an `IJBRulesetApprovalHook` that returns an approval status. The built-in `JBDeadline` hook enforces a minimum delay between queuing and activation, but projects can implement arbitrary governance logic (e.g., on-chain voting) behind the same interface. If the approval hook rejects a queued ruleset, the protocol falls back to the most recent approved ruleset and continues cycling from there.

## Cross-Cutting Concerns

**Reentrancy model.** The protocol does not use OpenZeppelin's `ReentrancyGuard`. Instead, it relies on completing all state mutations before making external calls (checks-effects-interactions). In the payment flow, the store records the balance and the controller mints tokens before pay hooks execute. In cash outs, tokens are burned and funds transferred before cashout hooks run, preventing double-cashout. For held fee processing (`processHeldFeesOf`), the storage index `_nextHeldFeeIndexOf` is advanced and the fee entry is deleted before the external call, so a reentrant call sees the updated index and cannot reprocess the same fee. All risky external calls are wrapped in try-catch blocks, which means a reentrant call that reverts is caught and handled rather than propagating.

**Fee model.** A flat 2.5% fee (`FEE = 25`, `MAX_FEE = 1000`) is charged on payouts to addresses, surplus allowance usage, and cash outs when `cashOutTaxRate < 100%`. Fees are paid to project #1 via `_processFee`, which calls `pay()` on the fee beneficiary's terminal. Fees can be held for up to 28 days (`_FEE_HOLDING_SECONDS = 2,419,200`) before they unlock for processing, giving projects a window to add funds back and have fees returned. Forward fee math: `amount * feePercent / MAX_FEE`. Backward (fee-inclusive) math: `amount * MAX_FEE / (MAX_FEE - feePercent) - amount`. The `JBFeelessAddresses` registry exempts specific addresses from fees entirely.

**Try-catch on all external hook calls.** Every external call to a hook or split recipient in `JBMultiTerminal` and `JBController` is wrapped in a try-catch. Failed pay hooks, cashout hooks, split hook calls, fee payments, and payout transfers are caught rather than reverting the entire transaction. When a payout transfer fails, the amount is returned to the project's balance (the payout limit is still consumed by design — the project owner can retry via `addToBalanceOf` or in the next cycle). This ensures that a single malicious or broken hook cannot grief an entire payout distribution or block cash outs.

**ERC-2771 meta-transaction support.** Five contracts support gasless transactions via OpenZeppelin's `ERC2771Context`: `JBMultiTerminal`, `JBController`, `JBPermissions`, `JBPrices`, and `JBProjects`. Each overrides `_msgSender()` and `_msgData()` to extract the original sender from the calldata suffix when called through a trusted forwarder. This lets relayers submit transactions on behalf of users, enabling gasless project creation, payments, and permission management without requiring users to hold native tokens.
