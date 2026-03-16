# nana-core-v6 -- Risks

Known security properties, trust assumptions, vulnerability vectors, and operational risks for Juicebox V6 core contracts. Intended audience: experienced Solidity auditors.

## Trust Model

### What You Trust

| Trust Assumption | Blast Radius | Notes |
|-----------------|-------------|-------|
| **Shared infrastructure** | All projects | All projects share the same `JBMultiTerminal`, `JBController`, `JBTerminalStore`. A bug in any of these affects every project. |
| **Project owner** (ERC-721 holder) | Single project | Can queue new rulesets, set terminals/controller, configure splits, delegate permissions. A malicious owner can fundamentally change project economics between rulesets. |
| **Data hooks** | Single project | Absolute control over token minting weights and cash out parameters. Can override `totalSupply`, `cashOutCount`, `cashOutTaxRate` to arbitrary values. A malicious data hook can drain the entire project treasury. |
| **Approval hooks** | Single project | Approve or reject ruleset transitions. A reverting hook triggers fallback to `basedOnId` chain (try-catch). A malicious hook could allow or block unexpected transitions. |
| **Price feeds** | Multi-currency projects | Surplus calculations depend on price feeds. Stale/manipulated feeds cause reverts (DoS), not direct fund loss. Single-currency projects are unaffected. |
| **Fee project (#1)** | Protocol-wide | 2.5% fees route to project #1. If project #1's terminal reverts, fees are returned to originating project's balance (try-catch fallback). |
| **Trusted forwarder** (ERC-2771) | Protocol-wide | Meta-tx forwarder is immutable. A compromised forwarder could spoof `_msgSender()` for all permission-gated functions. |

### What You Do NOT Need to Trust

- **Other projects**: Balances isolated by `(terminal, projectId, token)` in `JBTerminalStore`
- **Token holders**: Can only cash out proportional to bonding curve
- **Permit2**: Optional; projects work without it

## Known Bugs

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| **C-5** | CRITICAL (by design) | `cashOutTokensOf(count=0)` with `totalSupply == 0` returns entire surplus. `JBCashOuts.cashOutFrom()` line 37: `if (cashOutCount >= totalSupply) return surplus` -- when both are 0, `0 >= 0` is true. | CONFIRMED. Known, documented. Requires totalSupply to reach 0 (all tokens burned). |
| **H-4** | HIGH | Pending reserved tokens inflate `totalSupply` via `totalTokenSupplyWithReservedTokensOf()`, reducing cash out value. In extreme cases (large pending reserves), cash out value drops 50%+. | CONFIRMED. Mitigation: call `sendReservedTokensToSplitsOf()` regularly. |
| **FV-1** | LOW | Bonding curve subadditivity violation from `mulDiv` rounding. `cashOutFrom(a) + cashOutFrom(b) <= cashOutFrom(a+b)` can be violated by <0.01%. | KNOWN. Economically insignificant. |

## Reentrancy Analysis

No `ReentrancyGuard` anywhere in core. Relies entirely on checks-effects-interactions (CEI) ordering.

### Per-Function Analysis

| Function | What Happens Before External Calls | External Calls | Risk Level | Notes |
|----------|-----------------------------------|----------------|------------|-------|
| `_pay` | Store balance incremented, tokens minted | Pay hooks (`afterPayRecordedWith`) | LOW | Hooks execute after full state settlement. Hook could re-enter `cashOutTokensOf` on same project -- tokens already minted, balance already updated. |
| `_cashOutTokensOf` | Store balance decremented, tokens burned, reclaim transferred to beneficiary | Cash out hooks (`afterCashOutRecordedWith`), fee processing | MEDIUM | Beneficiary receives funds BEFORE hooks execute. Hooks could re-enter `pay`. Fees taken AFTER hooks. |
| `executePayout` | Payout limit already consumed in store | Split hook (`processSplitWith`), project terminal (`pay`/`addToBalance`) | MEDIUM | Split hook receives funds and could re-enter. Payout limit already recorded prevents double-payout within same cycle. Try-catch wraps each split. |
| `processHeldFeesOf` | Index updated BEFORE external call, fee entry deleted | `_processFee` -> `executeProcessFee` -> `terminal.pay` | LOW | Re-reads storage index each iteration. Index incremented before external call. Smart reentrancy protection. |
| `_sendReservedTokensToSplitsOf` | `pendingReservedTokenBalanceOf` zeroed, tokens minted to controller | Split hooks, terminal payments | LOW | Pending balance cleared before minting prevents double-distribution. |
| `_useAllowanceOf` | Store balance decremented, allowance consumed | `_takeFeeFrom` (fee processing), `_transferFrom` (beneficiary transfer) | LOW | Allowance fully consumed before any external call. |
| `migrateBalanceOf` | Store balance zeroed | `to.addToBalanceOf` on destination terminal | LOW | Full balance returned by `recordTerminalMigration` before transfer. |

### Cross-Function Reentrancy Gaps

The primary gap is **hook -> different terminal function** reentrancy:

1. **Pay hook -> cashOutTokensOf**: During `_pay`, after tokens are minted, a pay hook could call `cashOutTokensOf`. The cash out would see the post-payment balance and post-mint supply. Not exploitable for profit (tested), but worth verifying with data hook configurations that modify weights.

2. **Split hook -> pay**: During `sendPayoutsOf`, a split hook receives funds and could call `pay()` on the same project. The payout limit is already consumed, but the payment adds to balance and mints tokens. No value loop because the split hook's funds came from the project's own balance.

3. **Fee processing -> re-entry**: `_processFee` calls `terminal.pay()` on project #1's terminal. If project #1 has a pay hook that calls back into the originating terminal, the fee amount is already deducted from the originating project's balance.

### Key Defense

`JBTerminalStore_InadequateTerminalStoreBalance` revert prevents extracting more than the recorded balance regardless of reentrancy state. This is the backstop for all value extraction paths.

## Data Hook Omnipotence

Data hooks have **absolute control** over two critical flows:

### Payment Data Hook (`beforePayRecordedWith`)
- Returns `weight` (overrides ruleset weight for token minting)
- Returns `JBPayHookSpecification[]` with `amount` fields that divert funds from the project balance to hooks
- Constraint: `sum(specification.amount) <= payment.value` (enforced by store)

### Cash Out Data Hook (`beforeCashOutRecordedWith`)
- Returns `cashOutTaxRate` (overrides ruleset tax rate)
- Returns `cashOutCount` (overrides actual burn count)
- Returns `totalSupply` (overrides actual supply for curve calculation)
- Returns `JBCashOutHookSpecification[]` with `amount` fields
- Constraint: `reclaimAmount + sum(specification.amount) <= project balance` (enforced by store)

**Attack surface**: A malicious data hook can set `totalSupply = surplus` to make `reclaimAmount = cashOutCount`, effectively bypassing the bonding curve entirely. Project owners MUST audit their data hooks.

## Price Feed Risks

| Risk | Trigger | Impact | Mitigation |
|------|---------|--------|------------|
| **Staleness DoS** | Chainlink feed stale beyond `THRESHOLD` | All multi-currency operations revert (pay, cash out, payouts) | `JBChainlinkV3PriceFeed` reverts on stale data. Single-currency projects unaffected. |
| **Sequencer downtime** | L2 sequencer goes down (Optimism/Arbitrum) | `JBChainlinkV3SequencerPriceFeed` reverts during downtime + grace period | By design. Prevents stale-price exploitation during sequencer outages. |
| **Project-specific feed manipulation** | Project owner registers a malicious price feed | Surplus calculations skewed, cash out values manipulated | Feeds are immutable once set. `allowAddPriceFeed` ruleset flag gates addition. |
| **Inverse auto-calculation** | No explicit A->B feed but B->A exists | `JBPrices` auto-calculates inverse. Rounding may differ from direct feed. | Precision loss bounded by `mulDiv` rounding (<1 wei per operation). |
| **Feed lookup fallback** | Project-specific feed missing | Falls back to `DEFAULT_PROJECT_ID = 0` (protocol defaults) | Project owner should verify correct feeds are registered. |

## Unbounded Array Risks

| Array | Location | Bound | Gas Risk | Mitigation |
|-------|----------|-------|----------|------------|
| `_heldFeesOf[projectId][token]` | `JBMultiTerminal` | Grows with each fee-holding operation | MODERATE at 100+ entries | `_nextHeldFeeIndexOf` pointer skips processed entries. Full cleanup when all processed. `processHeldFeesOf` takes `count` parameter. |
| `_accountingContextsOf[projectId]` | `JBMultiTerminal` | Grows with each `addAccountingContextsFor` call | LOW -- realistic max ~100 tokens | Duplicate prevention (`AccountingContextAlreadySet`). |
| `splits` arrays | `JBSplits` | No explicit cap | MODERATE at 100+ splits (~100k gas per split during payout) | Percentage constraint (`SPLITS_TOTAL_PERCENT`) limits useful count to ~300-500. |
| Payout limits / surplus allowances | `JBFundAccessLimits` | Currency ordering constraint | LOW -- max ~30-50 entries | Strictly increasing currency order prevents duplicates. |
| `_terminalsOf[projectId]` | `JBDirectory` | Duplicate check | LOW -- realistic max 5-10 | `DuplicateTerminals` revert on set. |

## Ruleset Transition Timing Attacks

| Vector | Description | Risk |
|--------|-------------|------|
| **Boundary payment** | Payment landing at exact ruleset transition timestamp receives new ruleset's weight | LOW -- `currentOf()` is deterministic based on `block.timestamp` |
| **Approval hook rejection at boundary** | Rejected ruleset falls back to `basedOnId` chain; protocol simulates cycling from last approved ruleset | MEDIUM -- fallback behavior is complex; verify it always matches intended economics |
| **duration=0 immediate replacement** | Queuing a new ruleset for a duration=0 project takes effect immediately | LOW -- by design, but allows same-transaction weight change if owner queues + pays |
| **Weight cache starvation** | >20,000 cycles without cache update causes `WeightCacheRequired` revert | MEDIUM (DoS) -- anyone can call `updateRulesetWeightCache()` to fix, but attacker could create project designed to hit this |
| **mustStartAtOrAfter manipulation** | Queued ruleset with `mustStartAtOrAfter` in distant future delays all subsequent rulesets | LOW -- only owner can queue; approval hooks can reject |

## Cross-Terminal Surplus Aggregation

When `useTotalSurplusForCashOuts` is enabled in the ruleset:

1. `JBTerminalStore.recordCashOutFor()` calls `JBSurplus.currentSurplusOf()` across ALL project terminals
2. Each terminal's surplus is converted via `JBPrices` to the target currency
3. The reclaim amount is computed against this aggregated surplus
4. But the actual reclaim comes only from the terminal being cashed out from

**Risk**: If price feeds between terminals are inconsistent or manipulable, the aggregated surplus could be inflated, causing a cash out from one terminal to extract more value than that terminal actually holds.

**Defense**: `JBTerminalStore_InadequateTerminalStoreBalance` revert prevents extracting more than the terminal's recorded balance. The over-claiming would revert.

## Permission Security

| Property | Status |
|----------|--------|
| ROOT (ID 1) grants all permissions | Enforced |
| ROOT cannot be set for wildcard `projectId = 0` | Enforced (`CantSetRootPermissionForWildcardProject`) |
| ROOT operators cannot grant ROOT to others | Enforced (checked in `setPermissionsFor`) |
| Permission 0 is reserved and cannot be set | Enforced (`NoZeroPermission`) |
| All permission checks support ERC-2771 | Enforced via `_msgSender()` |
| Empty permission arrays pass `hasPermissions` check | By design (vacuous truth). Callers must validate non-empty arrays if needed. |

## Fee Arithmetic

| Property | Formula | Notes |
|----------|---------|-------|
| Forward fee | `amount * FEE / MAX_FEE` = `amount * 25 / 1000` = 2.5% | Rounds via `mulDiv` (rounds down -- safe for fee beneficiary since it's taking less) |
| Backward fee | `amountAfterFee * MAX_FEE / (MAX_FEE - FEE) - amountAfterFee` | Used in `_returnHeldFees` |
| Fee rounding error | Bounded by N-1 wei for N splits | Economically insignificant |
| Held fees | Stored as `amount` (pre-fee gross), held for 28 days (2,419,200s) | Fee calculated at processing time, not holding time |
| Fee-on-fee | No unbounded recursion. Fee processing calls `terminal.pay()` which itself may trigger hooks, but each layer is bounded by the fee amount. | Try-catch prevents cascading failures. |

## Proven Invariants

These are verified by the test suite (165 test files):

1. **No flash-loan profit**: Pay + cashout in same block never profitable after fees (12 attack vectors tested)
2. **Balance conservation**: `terminal.balance(token) >= sum(store.balanceOf(projectId, terminal, token))` for all projects
3. **Inflow >= Outflow**: Total funds received by a project >= total funds distributed
4. **Fee monotonicity**: Fee project (#1) balance only increases over time
5. **Token supply consistency**: `creditSupply + erc20.totalSupply() == totalSupply` at all times
6. **Ruleset existence**: After `launchProjectFor()`, `currentOf(projectId)` always returns a valid ruleset
7. **Fee accuracy**: Forward and backward fee calculations consistent within rounding bounds
