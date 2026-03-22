# nana-core-v6 -- Audit Instructions

You are auditing the core Juicebox V6 protocol -- a modular system for programmable treasuries with configurable rulesets, bonding-curve cash outs, split-based payouts, and a compositional hook system. Your goal is to find bugs that lose funds, break invariants, or enable unauthorized access.

Read [RISKS.md](./RISKS.md) for known risks, trust model, and reentrancy analysis. Then come back here.

## Architecture Overview

16 contracts, ~8,100 lines in main contracts. All contracts use Solidity 0.8.26.

```
                              JBProjects (ERC-721)
                                    |
                              JBDirectory
                            /       |        \
                JBController   JBMultiTerminal  JBPermissions
                /   |   \          |
        JBRulesets  |  JBTokens  JBTerminalStore
                    |              |
              JBSplits      JBPrices
                    |
          JBFundAccessLimits
```

### Contract Roles

| Contract | Lines | Role | Calls |
|----------|-------|------|-------|
| **JBMultiTerminal** | ~2024 | Payment terminal. Handles pay, cash out, payouts, surplus allowance, fees, and previews (`previewPayFor`, `previewCashOutFrom`). Multi-token. Permit2 integration. | Store, Controller, Splits, Directory, Prices |
| **JBController** | ~1186 | Orchestrator. Project lifecycle, ruleset queuing, token minting/burning, reserved token distribution, mint preview (`previewMintOf`). ERC-2771 meta-tx. | Rulesets, Tokens, Splits, FundAccessLimits, Directory, Prices |
| **JBTerminalStore** | ~1,267 | Bookkeeping. Balances, payout limit tracking, surplus calculation, bonding curve reclaim math. Data hook integration point. | Rulesets, Prices, Directory |
| **JBRulesets** | ~1093 | Ruleset lifecycle. Linked-list via `basedOnId`. Weight decay with cache (20k iteration threshold). Approval hooks. Bit-packed storage. | Directory (via JBControlled) |
| **JBDirectory** | ~344 | Routes projects to terminals and controllers. Migration lifecycle (before/after). | Projects, Permissions |
| **JBTokens** | ~415 | Dual token system: credits (internal) + ERC-20. Credits burned first on burn. 18-decimal requirement. | JBERC20 (clone) |
| **JBSplits** | ~333 | Packed split storage per project/ruleset/group. Locked splits enforcement. Fallback to ruleset 0. | -- |
| **JBFundAccessLimits** | ~318 | Payout limits and surplus allowances per terminal/token/currency. Strictly increasing currency order. | -- |
| **JBPrices** | ~233 | Price feed registry. Project-specific + default fallback. Immutable once set. Inverse auto-calculation. | Chainlink feeds |
| **JBPermissions** | ~260 | 256-bit packed permission bitmap. ROOT (1) grants all. Wildcard projectId=0. ERC-2771. | -- |
| **JBProjects** | ~126 | ERC-721 project ownership. Auto-incrementing IDs. | -- |
| **JBERC20** | ~144 | Cloneable ERC20Votes+Permit. Owned by JBTokens. Deployed via `Clones.clone()`. | -- |
| **JBFeelessAddresses** | ~50 | Fee-exempt address registry. Owner-only. | -- |
| **JBDeadline** | ~76 | Approval hook. Rejects rulesets queued within DURATION seconds of start. Ships as 3h, 1d, 3d, 7d variants. | -- |
| **JBChainlinkV3PriceFeed** | ~74 | Chainlink v3 feed with staleness threshold. Rejects negative/zero/incomplete. | Chainlink AggregatorV3 |
| **JBChainlinkV3SequencerPriceFeed** | ~75 | L2 sequencer-aware Chainlink feed. Grace period after restart. | Chainlink AggregatorV3 + Sequencer feed |

## Key Flows

### Payment Flow (`pay`)

```
User -> JBMultiTerminal.pay()
  -> _acceptFundsFor()              // Transfer tokens in (or accept msg.value)
     -> [Optional] Permit2 decode from metadata
  -> JBTerminalStore.recordPaymentFrom()
     -> RULESETS.currentOf()        // Get current ruleset
     -> [If useDataHookForPay] dataHook.beforePayRecordedWith() -> returns (weight, hookSpecs)
     -> Calculate tokenCount = mulDiv(amount.value, weight, weightRatio)
     -> Increment balanceOf[terminal][projectId][token]
     -> Deduct hook specification amounts from balance
  -> JBController.mintTokensOf()
     -> Calculate reserved vs beneficiary tokens
     -> TOKENS.mintFor(beneficiary)
     -> Increment pendingReservedTokenBalanceOf
  -> [If hookSpecs] _fulfillPayHookSpecificationsFor()
     -> For each spec: transfer funds, call hook.afterPayRecordedWith()
```

**State at hook execution time**: Store balance updated (post-hook-deductions). Tokens minted. Pending reserved tokens accumulated. Hooks see the fully settled state.

### Cash Out Flow (`cashOutTokensOf`)

```
Holder -> JBMultiTerminal.cashOutTokensOf()
  -> JBTerminalStore.recordCashOutFor()
     -> RULESETS.currentOf()
     -> Calculate surplus (local or total, depending on useTotalSurplusForCashOuts)
     -> Get totalSupply (including pending reserved tokens)
     -> [If useDataHookForCashOut] dataHook.beforeCashOutRecordedWith()
        -> Returns (cashOutTaxRate, cashOutCount, totalSupply, hookSpecs)  // ALL overrideable
     -> JBCashOuts.cashOutFrom(surplus, cashOutCount, totalSupply, cashOutTaxRate)
     -> Deduct reclaimAmount + hookSpec amounts from balance
  -> JBController.burnTokensOf()
  -> Transfer reclaimAmount to beneficiary  // BEFORE hooks execute
  -> [If hookSpecs] _fulfillCashOutHookSpecificationsFor()
     -> For each spec: transfer funds, call hook.afterCashOutRecordedWith()
  -> _takeFeeFrom() on total amount eligible for fees
     -> Fee charged if cashOutTaxRate > 0, OR if cashOutTaxRate == 0 and _feeFreeSurplusOf[projectId][token] > 0 (up to that amount)
     -> Fee skipped if beneficiary is feeless
```

**Critical note**: The beneficiary receives the reclaim amount BEFORE cash out hooks execute. Fees are taken AFTER hooks. `_feeFreeSurplusOf[projectId][token]` accumulates the value of fee-free intra-terminal payouts. During zero-tax cashout, the 2.5% fee applies only up to this surplus amount (then depletes it), preventing a round-trip fee bypass (payout via same terminal → zero-tax cashout) while scoping fees precisely to the fee-free inflow.

### Payout Flow (`sendPayoutsOf`)

```
Anyone -> JBMultiTerminal.sendPayoutsOf()
  -> [If ownerMustSendPayouts] Require SEND_PAYOUTS permission
  -> JBTerminalStore.recordPayoutFor()
     -> Deduct amount from balance
     -> Increment usedPayoutLimitOf
     -> Validate against FUND_ACCESS_LIMITS.payoutLimitOf()
  -> _sendPayoutsToSplitGroupOf()
     -> Get splits from JBSplits.splitsOf()
     -> For each split (try-catch per split):
        -> Split to hook: deduct fee, call hook.processSplitWith() with funds
        -> Split to project: deduct fee, call terminal.pay() or terminal.addToBalanceOf()
        -> Split to address: deduct fee, transfer directly
        -> On failure: return amount to project balance, emit PayoutReverted
  -> Send leftover to project owner (try-catch)
  -> _takeFeeFrom() on total fee-eligible amount
```

**Key detail**: Payout limit is consumed even if splits fail. This is by design -- the project authorized the distribution. Failed splits return funds to the project balance.

### Surplus Allowance Flow (`useAllowanceOf`)

```
Owner -> JBMultiTerminal.useAllowanceOf()
  -> Require USE_ALLOWANCE permission
  -> JBTerminalStore.recordUsedAllowanceOf()
     -> Deduct from balance
     -> Increment usedSurplusAllowanceOf
     -> Validate against FUND_ACCESS_LIMITS.surplusAllowanceOf()
     -> Validate amount <= current surplus
  -> _takeFeeFrom() (fee subtracted from amount)
  -> Transfer net amount to beneficiary
```

### Reserved Token Distribution (`sendReservedTokensToSplitsOf`)

```
Anyone -> JBController.sendReservedTokensToSplitsOf()
  -> Read pendingReservedTokenBalanceOf (revert if 0)
  -> Zero out pendingReservedTokenBalanceOf  // BEFORE minting
  -> TOKENS.mintFor(controller, tokenCount)  // Mint to controller
  -> For each reserved token split:
     -> Split to hook: transfer tokens, call hook.processSplitWith()
     -> Split to project with terminal: call terminal.pay() with tokens (try-catch)
     -> Split to address: transfer tokens directly
     -> Split to 0xdead: burn tokens
  -> Send leftover tokens to project owner
```

## Storage Layout and State Management

### JBTerminalStore -- The Source of Truth

All financial state lives in `JBTerminalStore`:

```solidity
// Real balances -- the money
mapping(terminal => mapping(projectId => mapping(token => uint256))) public balanceOf;

// Consumption tracking -- limits enforcement
mapping(terminal => mapping(projectId => mapping(token => mapping(cycleNumber => mapping(currency => uint256)))))
    public usedPayoutLimitOf;

mapping(terminal => mapping(projectId => mapping(token => mapping(rulesetId => mapping(currency => uint256)))))
    public usedSurplusAllowanceOf;
```

Key observations:
- `balanceOf` is keyed by terminal address -- anyone can call `recordAddedBalanceFor`, but only registered terminals meaningfully interact
- `usedPayoutLimitOf` resets each cycle (keyed by `cycleNumber`). Payout limits refresh when the ruleset cycles.
- `usedSurplusAllowanceOf` resets each ruleset (keyed by `rulesetId`). Surplus allowances refresh when a new ruleset takes effect.

### JBRulesets -- Bit-Packed State

Rulesets are stored across three packed storage slots per ruleset:

| Slot | Name | Contents |
|------|------|----------|
| 1 | `_packedIntrinsicPropertiesOf` | `weight` (112 bits), `basedOnId` (48), `start` (48), `cycleNumber` (48) |
| 2 | `_packedUserPropertiesOf` | `approvalHook` (160), `duration` (32), `weightCutPercent` (32) |
| 3 | `_metadataOf` | 256-bit packed metadata (see below) |

### Metadata Bit Layout (`JBRulesetMetadataResolver`)

```
Bits 0-3:     version (4 bits) -- currently 0
Bits 4-19:    reservedPercent (16 bits, max 10,000)
Bits 20-35:   cashOutTaxRate (16 bits, max 10,000)
Bits 36-67:   baseCurrency (32 bits)
Bits 68-81:   14 boolean flags (1 bit each):
              pausePay, pauseCreditTransfers, allowOwnerMinting,
              allowSetCustomToken, allowTerminalMigration, allowSetTerminals,
              allowSetController, allowAddAccountingContext, allowAddPriceFeed,
              ownerMustSendPayouts, holdFees, useTotalSurplusForCashOuts,
              useDataHookForPay, useDataHookForCashOut
Bits 82-241:  dataHook address (160 bits)
Bits 242-255: metadata (14 bits, project-defined)
```

## Hook Interfaces

Five extension points, ordered by power:

| Hook | Interface | Called By | When | Power Level |
|------|-----------|-----------|------|-------------|
| **Data Hook (pay)** | `IJBRulesetDataHook.beforePayRecordedWith` | JBTerminalStore | During `recordPaymentFrom` | ABSOLUTE -- controls weight and fund allocation |
| **Data Hook (cashout)** | `IJBRulesetDataHook.beforeCashOutRecordedWith` | JBTerminalStore | During `recordCashOutFor` | ABSOLUTE -- controls tax rate, count, supply, fund allocation |
| **Pay Hook** | `IJBPayHook.afterPayRecordedWith` | JBMultiTerminal | After payment recorded + tokens minted | MEDIUM -- receives diverted funds, executes arbitrary logic |
| **Cash Out Hook** | `IJBCashOutHook.afterCashOutRecordedWith` | JBMultiTerminal | After cash out recorded + tokens burned + beneficiary paid | MEDIUM -- receives diverted funds |
| **Split Hook** | `IJBSplitHook.processSplitWith` | JBMultiTerminal (payouts) / JBController (reserved tokens) | During payout distribution or reserved token distribution | MEDIUM -- receives split funds |
| **Approval Hook** | `IJBRulesetApprovalHook.approvalStatusOf` | JBRulesets | During `currentOf()` / `upcomingOf()` | LOW -- can approve/reject/delay rulesets |

**Data hook security note**: `beforeCashOutRecordedWith` returns FOUR overrideable values: `cashOutTaxRate`, `cashOutCount`, `totalSupply`, and `hookSpecifications`. A malicious data hook can set `totalSupply = surplus` causing `reclaimAmount = cashOutCount`, completely bypassing the bonding curve.

## Library Dependencies

| Library | Used By | Purpose | Audit Focus |
|---------|---------|---------|-------------|
| `JBCashOuts` | JBTerminalStore | Bonding curve: `base * [(MAX-tax) + tax*(count/supply)] / MAX`. Binary search for inverse (`minCashOutCountFor`). | Rounding direction in `mulDiv`. Edge cases: count=0, supply=0, taxRate=MAX. |
| `JBFees` | JBMultiTerminal | Forward: `amount * FEE / MAX_FEE`. Backward: `amount * MAX_FEE / (MAX_FEE - FEE) - amount`. | Consistency between forward and backward. Rounding bounds. |
| `JBRulesetMetadataResolver` | JBController, JBMultiTerminal, JBTerminalStore | Packs/unpacks 256-bit metadata. Shift/mask operations for each field. | Bit overlap, off-by-one in shifts, mask correctness. |
| `JBMetadataResolver` | JBMultiTerminal | Variable-length `{id:data}` key-value metadata encoding with lookup table. Used for Permit2 data. | Malformed metadata handling, ID collision. |
| `JBFixedPointNumber` | JBTerminalStore (via JBSurplus) | Decimal adjustment: `value * 10^targetDecimals / 10^sourceDecimals` with fidelity cap. | Overflow in adjustment, precision loss. |
| `JBSurplus` | JBTerminalStore | Aggregates surplus across terminals. Calls each terminal's store for balance and payout limits. | Cross-terminal surplus consistency. |

## Key Constants

| Constant | Value | Context |
|----------|-------|---------|
| `FEE` | 25 | Fee percentage (out of MAX_FEE = 1000) = 2.5% |
| `MAX_FEE` | 1,000 | 100% fee cap |
| `MAX_RESERVED_PERCENT` | 10,000 | Basis points (100%) |
| `MAX_CASH_OUT_TAX_RATE` | 10,000 | Basis points (100%). Rate of 10,000 = nothing reclaimable. Rate of 0 = proportional (1:1). |
| `MAX_WEIGHT_CUT_PERCENT` | 1,000,000,000 | 9-decimal precision (100%) |
| `SPLITS_TOTAL_PERCENT` | 1,000,000,000 | 9-decimal precision (100%) |
| `NATIVE_TOKEN` | `0x...EEEe` | Sentinel address for native ETH (or native token on any chain) |
| `_FEE_BENEFICIARY_PROJECT_ID` | 1 | Project #1 receives all protocol fees |
| `_FEE_HOLDING_SECONDS` | 2,419,200 | 28 days |
| `_WEIGHT_CUT_MULTIPLE_CACHE_LOOKUP_THRESHOLD` | 20,000 | Max weight decay iterations per call |

### Special Values

| Value | Context | Meaning |
|-------|---------|---------|
| `weight = 0` | Ruleset | No token issuance for payments |
| `weight = 1` | Ruleset config | Inherit decayed weight from previous ruleset (sentinel) |
| `duration = 0` | Ruleset | Never expires; immediately replaced when new ruleset queued |
| `projectId = 0` | Permissions | Wildcard: permission applies to ALL projects. Cannot combine with ROOT. |
| `rulesetId = 0` | Splits | Fallback split group when no splits set for specific ruleset |
| `projectId = 0` | Prices | Protocol-wide default price feed (owner-only) |

## Gotchas for Auditors

These are the patterns that will trip you up if you are not aware of them:

1. **`controllerOf()` returns `IERC165`, not `address`** -- must cast: `IJBController(address(directory.controllerOf(projectId)))`
2. **`primaryTerminalOf()` returns `IJBTerminal`, not `address`** -- must cast
3. **`terminalsOf()` returns `IJBTerminal[]`, not `address[]`**
4. **`pricePerUnitOf()` is on `IJBPrices`, not `IJBController`**
5. **`baseCurrency` (1=ETH, 2=USD) != `JBAccountingContext.currency` (uint32(uint160(token)))** -- two different currency systems. `JBPrices` mediates between them.
6. **`groupId` (uint256) != `currency` (uint32)** -- both derived from token address but different bit widths. `groupId = uint256(uint160(token))`, `currency = uint32(uint160(token))`.
6b. **`setSplitGroupsOf` self-auth requires non-zero upper 96 bits.** The self-auth path (where `msg.sender` matches the lower 160 bits of the `groupId`) additionally requires `groupId >> 160 != 0`. Bare-address groupIds (upper 96 bits = 0) are protocol-reserved for terminal payout groups and always require controller auth. This prevents accepted token contracts from hijacking payout splits.
7. **Empty `fundAccessLimitGroups` = zero payouts, NOT unlimited** -- `sendPayoutsOf` reverts on any amount. Use `uint224.max` for unlimited.
8. **`sendPayoutsOf()` reverts when `amount > payout limit`** -- does NOT auto-cap to limit.
9. **Cash out tax rate semantics are inverted from what you might expect**: 0% = proportional (1:1) redemption. 100% = nothing reclaimable (all surplus locked).
10. **`recordPayoutFor` deducts balance and increments used limit BEFORE validation** -- safe because the entire transaction reverts atomically, but the ordering matters for reentrancy analysis.
11. **Try-catch on external calls** -- `_sendPayoutToSplit`, `_processFee`, `executePayReservedTokenToTerminal` all use try-catch. Failed calls return funds to project balance and emit events. This is NOT a bug -- it prevents single-point-of-failure DoS.
12. **Credits are burned before ERC-20 tokens** in `JBTokens.burnFrom()`.
13. **`JBERC20` is cloned via `Clones.clone()`** -- constructor sets invalid name/symbol; real values set in `initialize()`.
14. **Named returns auto-return** -- several functions use named return variables without explicit `return` statements.
15. **Preview functions call data hooks** -- `previewPayFor`, `previewCashOutFrom`, and their store-level counterparts invoke data hooks during simulation. A reverting data hook will cause the preview to revert. Preview functions are `view` but still make external calls to hooks.
16. **Store preview functions take an explicit terminal parameter** -- `JBTerminalStore.previewPayFrom` and `previewCashOutFrom` take an explicit `terminal` address for balance/surplus lookups. Callers must pass a registered terminal to get correct results. The terminal-level `JBMultiTerminal.previewPayFor` / `previewCashOutFrom` handle this automatically by passing `address(this)`.

## Priority Areas to Audit

Ordered by blast radius:

| Priority | Target | Why |
|----------|--------|-----|
| 1 | **JBMultiTerminal + JBTerminalStore** | All funds flow through here. No reentrancy guard. CEI ordering is the only defense. |
| 2 | **JBCashOuts bonding curve math** | Determines how much holders can extract. Edge cases with 0 supply, 0 count, MAX tax rate. `mulDiv` rounding direction. |
| 3 | **Data hook integration** | Data hooks have absolute control. Verify all constraints on hook return values are enforced. |
| 4 | **JBRulesets weight decay + transition logic** | Complex linked-list traversal with approval hook fallback. Weight cache threshold. Timing at ruleset boundaries. |
| 5 | **Fee arithmetic (JBFees)** | Forward/backward consistency. Held fee lifecycle. Fee return calculations in `_returnHeldFees`. |
| 6 | **Cross-terminal surplus** (`JBSurplus`) | Aggregation across terminals with price conversion. Verify surplus cannot be inflated across terminals. |
| 7 | **Permission system** | ROOT escalation, wildcard project scope, ERC-2771 spoofing. |
| 8 | **Permit2 metadata parsing** | Malformed metadata, amount mismatch between permit and payment. |

## How to Run Tests

```bash
cd nana-core-v6
npm install
forge build
forge test

# Run with high verbosity for debugging
forge test -vvvv --match-test testExploitName

# Write a PoC
forge test --match-path test/audit/ExploitPoC.t.sol -vvv

# Run invariant tests
forge test --match-contract Invariant

# Gas analysis
forge test --gas-report
```

The existing test suite has 185 test files including:
- **Integration tests**: Full flow tests for pay, cash out, payouts
- **Formal property tests**: 7 bonding curve properties + 6 fee properties
- **Invariant tests**: TerminalStore (5), Phase3Deep (8), Rulesets (4), Tokens (4)
- **Economic simulation**: 3 projects, 10 actors, 15 operations, 6 invariants
- **Flash loan attack tests**: 12 attack vectors in `FlashLoanAttacks.t.sol`

Review the invariant tests to understand what is already proven -- then try to break those invariants with configurations the tests do not cover.

## Invariants to Verify

These MUST hold. If you can break any of them, it is a finding:

1. **Balance conservation**: `terminal.balance(token) >= sum(store.balanceOf(projectId, terminal, token))` for all projects
2. **Inflow >= Outflow**: Total funds received by a project >= total funds distributed
3. **Fee monotonicity**: Project #1's balance only increases over time
4. **Token supply consistency**: `JBTokens.totalSupplyOf(projectId) == creditSupply + erc20.totalSupply()`
5. **Ruleset existence**: After `launchProjectFor()`, `currentOf(projectId)` always returns a valid ruleset
6. **No flash-loan profit**: Pay + cash out in same block should never yield more than was paid (minus fees)
7. **Payout limits**: A project cannot extract more than its configured payout limit per ruleset cycle
8. **Surplus allowance**: A project cannot withdraw more than its configured surplus allowance per ruleset

## How to Report Findings

For each finding:

1. **Title** -- one line, starts with severity (CRITICAL/HIGH/MEDIUM/LOW)
2. **Affected contract(s)** -- exact file path and line numbers
3. **Description** -- what is wrong, in plain language
4. **Trigger sequence** -- step-by-step, minimal steps to reproduce
5. **Impact** -- what an attacker gains, what a user loses (with numbers if possible)
6. **Proof** -- code trace showing the exact execution path, or a Foundry test
7. **Fix** -- minimal code change that resolves the issue

**Severity guide:**
- **CRITICAL**: Direct fund loss, permanent DoS, or system insolvency. Exploitable with no preconditions.
- **HIGH**: Conditional fund loss, privilege escalation, or broken core invariant. Requires specific but realistic setup.
- **MEDIUM**: Value leakage, griefing with cost to attacker, incorrect accounting, degraded functionality.
- **LOW**: Informational, cosmetic inconsistency, edge-case-only with no material impact.

## Attack Vectors

These are the attack patterns most likely to yield findings in core. Ordered by estimated likelihood of undiscovered bugs.

### 1. Hook Composition Attacks

Hooks execute after state is partially committed. Data hooks control weight and fund allocation absolutely. Pay/cashout hooks receive diverted funds and can re-enter the protocol.

**Specific sequences to test:**
- Data hook returns `totalSupply = surplus` during `beforeCashOutRecordedWith` → `reclaimAmount = cashOutCount`, completely bypassing the bonding curve. Verify all constraints on hook return values.
- Data hook sets `weight = type(uint256).max` during pay → can this overflow in `mulDiv(amount.value, weight, weightRatio)`?
- Pay hook calls `cashOutTokensOf` on the same project during `afterPayRecordedWith`. Tokens are minted and store is updated. Is the cashout profitable given the inflated balance?
- Split hook calls `pay()` on the same project during `sendPayoutsOf`. Payout limit is consumed but new payment adds to balance and mints tokens. Does this create a value loop?
- Cash out hook calls `pay()` on same project. Tokens are burned before hooks execute, but new tokens are minted. Can this inflate supply?

### 2. Bonding Curve Economic Attacks

The cash out formula: `reclaimAmount = (surplus * count / supply) * [(MAX - tax) + tax * (count / supply)] / MAX`

**Sequences:**
- Pay → immediate cash out in same block: should never profit after fees. Test with different hook configurations.
- Pay with data hook that inflates weight → cash out before reserved tokens are distributed. Pending reserved tokens inflate `totalSupply` (H-4 finding).
- Cash out with `cashOutCount >= totalSupply` returns entire surplus (C-5 finding, by design). Can you engineer this condition without being the last holder? (e.g., front-running a burn)
- Cross-terminal surplus aggregation: `useTotalSurplusForCashOuts` aggregates surplus across all terminals via `JBSurplus`. Can you manipulate surplus in one terminal to inflate cashout value in another?

### 3. Reentrancy Through CEI Ordering

No contract uses `ReentrancyGuard`. The protocol relies on checks-effects-interactions ordering.

**Critical surfaces (in order of risk):**
1. **Pay hook → cash out**: After `recordPaymentFrom` + `mintTokensOf`, the hook executes. It could call `cashOutTokensOf`. Store balance and tokens are updated. Is the resulting cashout computed against post-payment state correctly?
2. **Split hook → pay**: During `sendPayoutsOf`, splits receive funds. A hook could call `pay()`. Payout limit is consumed, but new payment updates state.
3. **Fee processing → re-entry**: `_processFee` calls `terminal.pay()` on project #1's terminal. If project #1 has a pay hook that calls back into the originating terminal, the fee is already deducted.
4. **processHeldFeesOf**: Re-reads storage index each iteration, updates index BEFORE external call. Verify this ordering prevents re-entrancy exploitation.

### 4. Ruleset Transition Timing

Rulesets transition at exact block timestamps. Transaction ordering at boundaries matters.

**What to test:**
- Payment at last second of ruleset vs. first second of next: both should execute with correct weights.
- Approval hook rejection at boundary: fallback to `basedOnId` chain simulates cycling from last approved ruleset. Is this always equivalent?
- `duration = 0` rulesets immediately replaced when new one queued. Can you pay and queue in the same tx to get old weight but new parameters?
- Weight decay across 20,000+ cycles without cache: `WeightCacheRequired` revert = DoS. Can an attacker force a project into this state?

## Anti-Patterns to Hunt

| Pattern | Where to Look | Why It's Dangerous |
|---------|--------------|-------------------|
| `try-catch` swallowing errors | JBMultiTerminal (hooks, fees, splits) | Failed external calls silently change control flow. Fee try-catch enables temporary fee avoidance. |
| `mulDiv` rounding direction | JBCashOuts, JBFees, JBTerminalStore | Rounding in attacker's favor compounds over many transactions. Verify rounding favors the protocol. |
| Currency type confusion | JBTerminalStore, JBFundAccessLimits | Abstract (1=ETH, 2=USD) vs concrete (`uint32(address)`) currencies. `groupId` (`uint256`) vs `currency` (`uint32`) truncation. |
| Named returns without explicit `return` | JBTerminalStore, JBRulesets | Auto-return of named variables. Easy to miss intermediate assignments that change the return value. |
| Bit-packed metadata shifts | JBRulesetMetadataResolver | Off-by-one in shift amounts or mask widths corrupts adjacent fields. 256-bit layout with 17 fields. |
| State before validation | `recordPayoutFor` | Balance deducted and limit incremented BEFORE validation. Safe due to atomic revert, but matters for reentrancy analysis. |
| Lazy evaluation of pending state | `pendingReservedTokenBalanceOf` | Reserved tokens accumulate but aren't minted until `sendReservedTokensToSplitsOf`. `totalSupply` includes pending. |
| External call in loop | Payout splits, `processHeldFeesOf` | Gas griefing via reverting external calls. Each caught by try-catch but still costs gas. |

## Previous Audit Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| C-5 | Critical | Known/Accepted | `cashOut(0)` with `totalSupply == 0` returns entire surplus. By design — last holder gets everything. Documented in `FlashLoanAttacks.t.sol`. |
| H-4 | High | Known/Accepted | Pending reserved tokens inflate `totalSupply` in bonding curve calculation, reducing cashout value by 50%+ in extreme cases. Distributing reserved tokens via `sendReservedTokensToSplitsOf` before cashing out mitigates. |
| FV-1 | Low | Known/Accepted | Bonding curve subadditivity violation from `mulDiv` rounding. Measured at <0.01%, economically insignificant. Proven bounded in formal property tests. |

## Coverage Gaps

The 185 test files cover most flows, but these areas have limited or no coverage:

- **Multi-hook composition**: No end-to-end tests for data hook + pay hook + cashout hook interacting in a single flow with reentrancy.
- **Extreme weight decay**: Weight decay beyond 20,000 cycles tested for revert, but not for precision loss at exactly the cache threshold boundary.
- **Cross-terminal surplus manipulation**: No tests where surplus is manipulated in terminal A to inflate cashout value in terminal B via `useTotalSurplusForCashOuts`.
- **Approval hook edge cases**: Limited testing of approval hook state changes between `queueRulesetsOf` and ruleset start time.
- **Concurrent held fee processing**: `processHeldFeesOf` tested sequentially but not under reentrancy from fee payment hooks.
- **ERC-2771 meta-tx spoofing**: No tests verifying that a malicious forwarder cannot spoof `_msgSender()` to bypass permissions.

## Compiler and Version Info

- **Solidity**: 0.8.26
- **EVM target**: Cancun (uses transient storage opcodes)
- **Optimizer**: 200 runs (no via-IR)
- **Dependencies**: OpenZeppelin 5.x, Solady, forge-std
- **Build**: `forge build` (Foundry)

Go break it.
