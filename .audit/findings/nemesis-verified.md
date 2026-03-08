# N E M E S I S — Verified Findings

## Scope

- **Language:** Solidity 0.8.26
- **Modules analyzed:** 16 contracts + 7 libraries + 3 deploy scripts + all interfaces/structs/enums
- **Files:** `src/**/*.sol` (80 files), `script/**/*.sol` (3 files)
- **Functions analyzed:** ~120 entry points across all contracts
- **Coupled state pairs mapped:** 10
- **Mutation paths traced:** 45+
- **Nemesis loop iterations:** 3 (converged — no new findings on Pass 3)

## Nemesis Map (Phase 1 Cross-Reference)

### Core Coupled State Pairs

| Pair ID | State A | State B | Invariant |
|---------|---------|---------|-----------|
| CP-1 | `balanceOf[terminal][projectId][token]` | Terminal's actual token balance | Store balance <= actual token balance (held fees occupy the gap) |
| CP-2 | `creditBalanceOf[holder][projectId]` | `totalCreditSupplyOf[projectId]` | Sum of all credit balances == totalCreditSupply |
| CP-3 | `tokenOf[projectId]` | `projectIdOf[token]` | Bidirectional: tokenOf[pid] == token ⟺ projectIdOf[token] == pid |
| CP-4 | `usedPayoutLimitOf[..][cycleNumber]` | `payoutLimitOf[..][rulesetId]` | used <= limit (per cycle) |
| CP-5 | `usedSurplusAllowanceOf[..][rulesetId]` | `surplusAllowanceOf[..][rulesetId]` | used <= allowance (per ruleset) |
| CP-6 | `_heldFeesOf[projectId][token]` | `_nextHeldFeeIndexOf[projectId][token]` | index <= array.length; active fees = array[index..length] |
| CP-7 | `pendingReservedTokenBalanceOf[projectId]` | `TOKENS.totalSupplyOf(projectId)` | totalTokenSupplyWithReserved = actual + pending |
| CP-8 | `latestRulesetIdOf[projectId]` | `_packedIntrinsicPropertiesOf[projectId][rulesetId]` | Latest ID points to valid packed data |
| CP-9 | `_splitCountOf[projectId][rulesetId][groupId]` | `_packedSplitParts1Of/2Of[..][index]` | count matches actual stored splits |
| CP-10 | `balanceOf` (per token) | Sum of payout limits + surplus | surplus = balance - sum(remaining payout limits) |

### Function-State Sync Matrix (Critical Functions)

| Function | CP-1 | CP-2 | CP-3 | CP-4 | CP-5 | CP-6 | CP-7 | Status |
|----------|------|------|------|------|------|------|------|--------|
| `recordPaymentFrom` | W | — | — | — | — | — | — | SYNCED |
| `recordPayoutFor` | W | — | — | W | — | — | — | SYNCED |
| `recordCashOutFor` | W | — | — | — | — | — | — | SYNCED |
| `recordUsedAllowanceOf` | W | — | — | — | W | — | — | SYNCED |
| `recordTerminalMigration` | W | — | — | — | — | — | — | SYNCED |
| `recordAddedBalanceFor` | W | — | — | — | — | — | — | SYNCED |
| `mintFor` | — | W | — | — | — | — | — | SYNCED |
| `burnFrom` | — | W | — | — | — | — | — | SYNCED |
| `claimTokensFor` | — | W | R | — | — | — | — | SYNCED |
| `deployERC20For` | — | — | W | — | — | — | — | SYNCED |
| `setTokenFor` | — | — | W | — | — | — | — | SYNCED |
| `transferCreditsFrom` | — | W | — | — | — | — | — | SYNCED |
| `processHeldFeesOf` | — | — | — | — | — | W | — | SYNCED |
| `_returnHeldFees` | W | — | — | — | — | W | — | SYNCED |
| `mintTokensOf` | — | — | — | — | — | — | W | SYNCED |
| `sendReservedTokensToSplitsOf` | — | — | — | — | — | — | W | SYNCED |
| `_setSplitsOf` | — | — | — | — | — | — | — | SYNCED (CP-9) |
| `queueFor` | — | — | — | — | — | — | — | SYNCED (CP-8) |

**Result: All coupled state pairs are properly synchronized across all mutation paths.**

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Severity | Verdict |
|----|--------|-------------|-------------|----------|---------|
| NM-001 | Feynman Cat.3 | — | Fee split distribution | LOW | TRUE POS |
| NM-002 | State→Feynman | CP-6 | `_returnHeldFees` partial | INFORMATIONAL | TRUE POS |
| NM-003 | Feynman Cat.4 | — | Data hook override | INFORMATIONAL | TRUE POS (by design) |
| NM-004 | Feynman Cat.1 | — | Deploy script stale name | INFORMATIONAL | TRUE POS |
| NM-005 | Feynman Cat.4 | — | `OMNICHAIN_RULESET_OPERATOR` | INFORMATIONAL | TRUE POS |

## Verified Findings (TRUE POSITIVES only)

---

### Finding NM-001: Fee Rounding Discrepancy in Split Distribution

**Severity:** LOW
**Source:** Feynman Category 3 (Consistency) — Pass 1
**Verification:** Code trace (Method A)

**Description:**
When payouts are distributed through splits, the fee is calculated individually for each split recipient in `executePayout()`, then again as an aggregate in `_takeFeeFrom()`. Due to integer rounding in `mulDiv`, the sum of individual fee deductions can differ from the aggregate fee calculation by approximately 1 wei per split.

**Feynman Question that exposed it:**
> "WHY is the fee calculated twice — once per split (to determine netPayoutAmount) and once on the aggregate (to determine what to send to the fee project)? Are these guaranteed to match?"

**Breaking Operation:** `executePayout()` at `JBMultiTerminal.sol:556` and `_takeFeeFrom()` at `JBMultiTerminal.sol:1887`

**Mechanism:**
```solidity
// In executePayout (per split):
netPayoutAmount -= JBFees.feeAmountFrom({amountBeforeFee: amount, feePercent: FEE});
// Fee deducted per-split: sum(feeAmountFrom(splitAmount_i, FEE))

// In _takeFeeFrom (aggregate):
feeAmount = JBFees.feeAmountFrom({amountBeforeFee: amountEligibleForFees, feePercent: FEE});
// Fee sent to fee project: feeAmountFrom(sum(splitAmount_i), FEE)
```

Due to the linearity of `feeAmountFrom(x, p) = mulDiv(x, p, MAX_FEE)`, we have:
- `feeAmountFrom(a, p) + feeAmountFrom(b, p)` can differ from `feeAmountFrom(a+b, p)` by up to 1 wei per term due to integer division truncation.

**Impact:**
- ~1 wei per split recipient per payout operation
- The terminal retains slightly more (or less) tokens than the store balance tracks
- Over many operations, this can accumulate to a few wei of dust — negligible in practice

**Trigger Sequence:**
1. Project has 3 split recipients, each receiving 33.33% of a payout
2. `sendPayoutsOf()` distributes and deducts fees per-split
3. Aggregate fee sent to fee project differs by 1-2 wei from sum of per-split deductions

**Consequence:**
Terminal token balance drifts from store balance by dust amounts. No economic exploit possible.

**Fix:**
No fix necessary — this is inherent to integer arithmetic. The system is designed to tolerate wei-level rounding. The terminal always has *at least* as many tokens as the store balance (the rounding favors the terminal retaining dust).

---

### Finding NM-002: Held Fee Partial Return Rounding Asymmetry

**Severity:** INFORMATIONAL
**Source:** State Cross-Check (CP-6) → Feynman Re-interrogation — Pass 2→3
**Verification:** Code trace (Method A)

**Coupled Pair:** `_heldFeesOf` ↔ `balanceOf` (via `_returnHeldFees`)

**Description:**
In `_returnHeldFees()`, when an incoming amount partially covers a held fee, the code uses `feeAmountResultingIn()` (the reverse fee function) to calculate the fee portion. This reverse calculation can produce a result that differs by 1 wei from the forward calculation `feeAmountFrom()` due to the different rounding directions of the two `mulDiv` operations.

**Location:** `JBMultiTerminal.sol:1635`
```solidity
// Forward: feeAmountFrom(amount, p) = mulDiv(amount, p, MAX_FEE)
// Reverse: feeAmountResultingIn(net, p) = mulDiv(net, MAX_FEE, MAX_FEE - p) - net
```

**Impact:**
- 1 wei per partial held fee return operation
- Rounding direction favors the project (slightly more fee is "returned" than would be charged forward)
- Economically negligible

---

### Finding NM-003: Data Hook Absolute Control Over Economics (Trust Assumption)

**Severity:** INFORMATIONAL
**Source:** Feynman Category 4 (Assumptions) — Pass 1
**Verification:** Code trace (Method A)

**Description:**
Data hooks have absolute, unconstrained control over payment and cash-out economics:

**Payment hooks** (`JBTerminalStore.sol:668`):
- Can return arbitrary `weight` (overriding ruleset weight → controlling token minting rate)
- Can return `hookSpecifications` that divert payment funds to external contracts before they reach the project's balance

**Cash-out hooks** (`JBTerminalStore.sol:558`):
- Can override `cashOutTaxRate`, `cashOutCount`, and `totalSupply`
- Setting `totalSupply = surplus` makes `reclaimAmount = cashOutCount`, bypassing the bonding curve entirely
- Can return `hookSpecifications` that send additional funds to external contracts

**Feynman Question that exposed it:**
> "What is implicitly TRUSTED about the data hook's return values? Are there any bounds checks?"

**Answer:** There are no bounds on the data hook's return values except that hook specification amounts cannot exceed the available balance. The data hook is fully trusted by design.

**Impact:**
A malicious or buggy data hook can:
- Drain the project's balance via hook specifications
- Mint unlimited tokens by returning an inflated weight
- Allow full surplus withdrawal by manipulating cash-out parameters

This is **by design** — project owners opt into data hooks, and the trust model is documented. However, it represents the single largest trust assumption in the protocol.

---

### Finding NM-004: Deploy Script Stale Version Reference

**Severity:** INFORMATIONAL
**Source:** Feynman Category 1 (Purpose) — Pass 1
**Verification:** Code trace (Method A)

**Location:** `script/Deploy.s.sol:32` and `script/helpers/CoreDeploymentLib.sol:10`

```solidity
// Deploy.s.sol
sphinxConfig.projectName = "nana-core-v5"; // Should be v6

// CoreDeploymentLib.sol
string constant PROJECT_NAME = "nana-core-v5"; // Should be v6
```

**Impact:**
These stale references to "v5" in a v6 codebase may cause:
- Confusion during deployment (Sphinx project name mismatch)
- Incorrect deployment address resolution if CoreDeploymentLib is used to find previously deployed contracts

Not a security vulnerability, but a deployment hygiene issue.

---

### Finding NM-005: Hardcoded Omnichain Ruleset Operator

**Severity:** INFORMATIONAL
**Source:** Feynman Category 4 (Assumptions) — Pass 1
**Verification:** Code trace (Method A)

**Location:** `script/DeployPeriphery.s.sol:20`

```solidity
address constant OMNICHAIN_RULESET_OPERATOR = address(0x8f5DED85c40b50d223269C1F922A056E72101590);
```

**Impact:**
This address receives privileged cross-chain ruleset management capabilities. If this address is compromised, incorrect, or not controlled by the intended party on a given deployment chain, it could affect cross-chain ruleset operations. This is a standard deployment concern but worth noting for operational awareness.

---

## False Positives Eliminated

The following 20+ candidates were analyzed and determined to be false positives:

| Candidate | Why False Positive |
|-----------|-------------------|
| `recordPayoutFor` decrement-then-validate | Safe: Solidity transaction atomicity — entire tx reverts if validation fails |
| `recordUsedAllowanceOf` decrement-then-validate | Same as above — atomic revert guarantees correctness |
| `_returnHeldFees` unchecked arithmetic | Safe: `leftoverAmount -= amountPaidOut` is guarded by `leftoverAmount >= amountPaidOut` check |
| Fee double-counting (per-split + aggregate) | Not a bug: `feeAmountFrom` is linear, aggregate fee correctly represents sum of per-split fees (within rounding) |
| Cash-out token burn ordering (reentrancy) | Safe: `burnTokensOf` is called on controller (trusted), no exploitable reentrancy window |
| `_processFee` try/catch swallowing | By design: fee processing failures should not block project operations |
| `migrateBalanceOf` doesn't migrate held fees | By design: held fees are terminal obligations, not project balance; fees process independently |
| Leftover transfer revert balance accounting | Correct: full `leftoverPayoutAmount` added back on failure, `amountEligibleForFees` not incremented |
| `beneficiaryTokenCount` measurement via balance diff | Correct approach: measures actual tokens received, accounting for any hook interactions |
| Reserved token split vs payout split rounding | Different mechanisms, not comparable — reserved tokens use `mulDiv` with different divisors |
| Deploy script project #1 not created | By design: project #1 is created separately; fee processing gracefully handles missing project via try/catch |
| Permit2 failure silently ignored | By design: `_transferFrom` uses Permit2 as fallback after standard approval check |
| Price feed projectId=0 for global feeds | By design: projectId=0 is the global namespace for system-wide price feeds |
| Split payout failure balance/fee accounting | Correct: failed payout amount is added back to balance, fee not charged |
| `executePayReservedTokenToTerminal` flow | Safe: forceApprove + pay + allowance check prevents token leakage |
| `_tokenSurplusFrom` payout limit underflow | Safe: `payoutLimit.amount - usedPayoutLimitOf[..]` is valid because used <= limit is enforced on write |
| `recordCashOutFor` hookSpecifications bounds | Safe: `balanceDiff > balanceOf` check prevents over-withdrawal |
| Front-running cash-out with surplus manipulation | Not exploitable: payment increases both surplus AND totalSupply proportionally |
| Sandwich attack on surplus allowance | Not exploitable: attacker loses money to fees and bonding curve |
| Weight manipulation across rulesets | Not exploitable: weight is deterministic based on ruleset parameters |

## Feedback Loop Discoveries

No additional findings emerged from the cross-feed between auditors beyond what was identified in Pass 1 and Pass 2. The iterative loop converged on Pass 3 with no new coupled pairs, suspects, or gaps discovered.

**Pass 1 (Feynman):** Identified NM-001 (fee rounding), NM-003 (data hook trust), NM-004 (stale deploy name), NM-005 (hardcoded operator). 20+ false positive candidates eliminated.

**Pass 2 (State):** Confirmed all 10 coupled pairs are properly synchronized. Identified NM-002 (held fee return rounding) by tracing CP-6 mutation paths. No state gaps found in the cross-reference matrix.

**Pass 3 (Feynman re-interrogation on Pass 2 targets):** No new findings. All coupled pairs interrogated for "WHY" — answers confirmed by-design behavior and lazy reconciliation patterns.

**Convergence:** Achieved on Pass 3 — no new suspects, coupled pairs, or gaps.

## Summary

- Total functions analyzed: ~120
- Coupled state pairs mapped: 10
- Nemesis loop iterations: 3 (converged)
- Raw findings (pre-verification): 0 C | 0 H | 0 M | 5 L/Info
- Feedback loop discoveries: 1 (NM-002 found via State→Feynman cross-feed)
- After verification: 5 TRUE POSITIVE | 0 FALSE POSITIVE | 0 DOWNGRADED
- **Final: 0 CRITICAL | 0 HIGH | 0 MEDIUM | 1 LOW | 4 INFORMATIONAL**

## Assessment

The nana-core-v6 codebase demonstrates strong security properties:

1. **Consistent state synchronization** — All 10 identified coupled state pairs are properly maintained across all mutation paths. No state gaps were found.

2. **Correct fee accounting** — The two-step fee pattern (deduct from individual payouts, process aggregate fee) is mathematically sound due to the linearity of the fee function. Wei-level rounding is the only discrepancy.

3. **Robust failure handling** — All external calls that could fail are wrapped in try/catch with correct balance restoration and fee accounting.

4. **Sound bonding curve economics** — The cash-out mechanism correctly prevents economic attacks through proportional surplus/supply accounting and includes pending reserved tokens in total supply calculations.

5. **Proper access control** — All state-mutating functions enforce appropriate permission checks via `onlyControllerOf`, `_requirePermissionFrom`, or self-call guards.

The primary trust assumptions are:
- Data hooks are trusted implicitly (by design — project owners opt in)
- `OMNICHAIN_RULESET_OPERATOR` is a trusted address
- Price feeds return accurate exchange rates
- ERC-20 tokens behave predictably (fee-on-transfer IS handled via balance-delta measurement in `_acceptFundsFor`, but rebasing tokens that change balances outside of transfers are not accounted for)
