# N E M E S I S — Raw Findings (Pre-Verification)

## Phase 0: Attacker Recon

### Language
- **Solidity 0.8.26** — auto-checked overflow/underflow, no reentrancy guard via CEI pattern
- **Framework:** Foundry (forge)
- **Test suite:** Comprehensive (existing tests not re-run as part of this audit)

### Q0.1: Attack Goals (WORST outcomes)
1. **Drain terminal balances** — Extract ETH/ERC-20 held by JBMultiTerminal without paying
2. **Mint infinite tokens** — Manipulate weight/hooks to get unlimited project tokens
3. **Steal surplus via cash-out manipulation** — Exploit bonding curve or data hooks to reclaim more than entitled
4. **Corrupt accounting state** — Desync store balances from actual token balances, causing insolvency
5. **Grief projects** — Block payouts, prevent cash-outs, or brick governance via state manipulation

### Q0.2: Novel Code (highest bug density)
- **JBMultiTerminal** — Complex multi-token terminal with held fee system, split distribution, data hooks
- **JBTerminalStore** — Stateless bookkeeping scoped by `msg.sender` (terminal identity as implicit auth)
- **JBCashOuts** — Custom bonding curve with inverse binary search (`minCashOutCountFor`)
- **JBRulesets** — Iterative weight decay with caching, approval hook lifecycle
- **Held fee system** — Novel 28-day fee holding with partial return mechanism

### Q0.3: Value Stores
| Module | Value Held | Outflow Functions |
|--------|-----------|-------------------|
| JBMultiTerminal | ETH + ERC-20 tokens (actual custody) | `sendPayoutsOf`, `useAllowanceOf`, `cashOutTokensOf`, `migrateBalanceOf` |
| JBTerminalStore | Accounting balances (`balanceOf[terminal][pid][token]`) | `recordPayoutFor`, `recordCashOutFor`, `recordUsedAllowanceOf`, `recordTerminalMigration` |
| JBTokens | Token credits (`creditBalanceOf`) | `burnFrom`, `claimTokensFor`, `transferCreditsFrom` |
| JBController | Pending reserved tokens (`pendingReservedTokenBalanceOf`) | `sendReservedTokensToSplitsOf`, `burnTokensOf` |

### Q0.4: Complex Paths
1. **Cash-out flow**: `cashOutTokensOf` → `recordCashOutFor` (store) → `burnTokensOf` (controller) → `burnFrom` (tokens) → transfer funds → pay hooks → take fees — crosses 5 contracts
2. **Payout flow**: `sendPayoutsOf` → `recordPayoutFor` (store) → `_sendPayoutsToSplitGroupOf` → `executePayout` (per split) → `_takeFeeFrom` → `_processFee` — crosses 4 contracts with per-split branching
3. **Payment flow**: `pay` → `_pay` → `_acceptFundsFor` → `recordPaymentFrom` (store) → `mintTokensOf` (controller) → `mintFor` (tokens) → pay hooks — crosses 4 contracts

### Q0.5: Coupled Value (Initial Hypothesis)
- Store `balanceOf` ↔ terminal actual token balance (held fees fill the gap)
- `creditBalanceOf` ↔ `totalCreditSupplyOf` (must sum correctly)
- `tokenOf` ↔ `projectIdOf` (bidirectional mapping)
- `_heldFeesOf` ↔ `_nextHeldFeeIndexOf` (index tracks active subset)
- `pendingReservedTokenBalanceOf` ↔ actual minted supply (pending + actual = total supply for cash-out calculations)
- `usedPayoutLimitOf` ↔ `payoutLimitOf` (usage tracking within limits)
- `usedSurplusAllowanceOf` ↔ `surplusAllowanceOf` (usage tracking within limits)

### Priority Order
1. **JBMultiTerminal + JBTerminalStore** — Holds all value, most complex interactions, most mutation paths
2. **JBController + JBTokens** — Token minting/burning, reserved token mechanics
3. **JBRulesets** — Weight calculation (determines token issuance rate)
4. **JBCashOuts + JBFees** — Core math libraries
5. **JBSplits, JBDirectory, JBFundAccessLimits, JBPermissions** — Access control and configuration
6. **Deploy scripts** — Initialization correctness

---

## Phase 1: Dual Mapping

### 1A: Function-State Matrix (Feynman Foundation)

#### JBMultiTerminal (Entry Points)

| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| `pay` | — | — | — | `_pay` → `STORE.recordPaymentFrom`, `CONTROLLER.mintTokensOf`, hooks |
| `addToBalanceOf` | — | — | — | `_addToBalanceOf` → `_returnHeldFees`, `STORE.recordAddedBalanceFor` |
| `sendPayoutsOf` | — | — | — | `STORE.recordPayoutFor`, `_sendPayoutsToSplitGroupOf`, `_takeFeeFrom` |
| `useAllowanceOf` | — | — | — | `STORE.recordUsedAllowanceOf`, `_takeFeeFrom`, `_transferFrom` |
| `cashOutTokensOf` | — | — | — | `STORE.recordCashOutFor`, `CONTROLLER.burnTokensOf`, hooks, `_takeFeeFrom` |
| `processHeldFeesOf` | `_heldFeesOf`, `_nextHeldFeeIndexOf` | `_nextHeldFeeIndexOf` | `_requirePermissionFrom` | `_processFee` per held fee |
| `executePayout` | — | — | `msg.sender == address(this)` | split hooks, `_pay` to terminal, `_transferFrom` |
| `executeProcessFee` | — | — | `msg.sender == address(this)` | `_pay` to fee project terminal |
| `executeTransferTo` | — | — | `msg.sender == address(this)` | token transfer |
| `migrateBalanceOf` | — | — | `_requirePermissionFrom` | `STORE.recordTerminalMigration`, `DIRECTORY.terminalsOf`, `_transferFrom` |

#### JBTerminalStore (Entry Points)

| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| `recordPaymentFrom` | `balanceOf`, rulesets, prices | `balanceOf` | `msg.sender` is terminal | data hooks |
| `recordPayoutFor` | `balanceOf`, `usedPayoutLimitOf`, rulesets, limits | `balanceOf`, `usedPayoutLimitOf` | `msg.sender` is terminal | rulesets, limits, prices |
| `recordCashOutFor` | `balanceOf`, rulesets, surplus | `balanceOf` | `msg.sender` is terminal | data hooks, surplus calc |
| `recordUsedAllowanceOf` | `balanceOf`, `usedSurplusAllowanceOf`, rulesets, limits | `balanceOf`, `usedSurplusAllowanceOf` | `msg.sender` is terminal | rulesets, limits, prices, surplus |
| `recordAddedBalanceFor` | `balanceOf` | `balanceOf` | `msg.sender` is terminal | — |
| `recordTerminalMigration` | `balanceOf` | `balanceOf` (→0) | `msg.sender` is terminal | — |

#### JBTokens (Entry Points)

| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| `mintFor` | `tokenOf`, `totalSupplyOf` | `creditBalanceOf`, `totalCreditSupplyOf` OR token.mint | `onlyControllerOf` | token.mint |
| `burnFrom` | `tokenOf`, `creditBalanceOf`, token.balanceOf | `creditBalanceOf`, `totalCreditSupplyOf` | `onlyControllerOf` | token.burn |
| `claimTokensFor` | `tokenOf`, `creditBalanceOf` | `creditBalanceOf`, `totalCreditSupplyOf` | `onlyControllerOf` | token.mint |
| `transferCreditsFrom` | `creditBalanceOf` | `creditBalanceOf` (2 accounts) | `onlyControllerOf` | — |
| `deployERC20For` | `tokenOf` | `tokenOf`, `projectIdOf` | `onlyControllerOf` | Clones.clone, token.initialize |
| `setTokenFor` | `tokenOf`, `projectIdOf` | `tokenOf`, `projectIdOf` | `onlyControllerOf` | token.decimals, token.canBeAddedTo |

#### JBController (Entry Points)

| Function | Reads | Writes | Guards | External Calls |
|----------|-------|--------|--------|----------------|
| `mintTokensOf` | rulesets | `pendingReservedTokenBalanceOf` | `_requirePermissionFrom` | `TOKENS.mintFor` |
| `burnTokensOf` | — | — | `_requirePermissionFrom` | `TOKENS.burnFrom` |
| `sendReservedTokensToSplitsOf` | `pendingReservedTokenBalanceOf`, rulesets, splits | `pendingReservedTokenBalanceOf` (→0) | — | `TOKENS.mintFor`, `_sendSplitsTo` |
| `launchProjectFor` | — | — | — | `PROJECTS.createFor`, `DIRECTORY.setControllerOf`, `queueRulesetsOf` |
| `queueRulesetsOf` | — | — | `_requirePermissionFrom` | `RULESETS.queueFor`, `SPLITS.setSplitsOf`, `FUND_ACCESS_LIMITS.setFundAccessLimitsFor` |

### 1B: Coupled State Dependency Map

See verified report (CP-1 through CP-10).

### 1C: Cross-Reference

| Function | CP-1 (store↔actual) | CP-2 (credit↔total) | CP-6 (held↔index) | CP-7 (pending↔supply) | Sync |
|----------|---------------------|---------------------|--------------------|-----------------------|------|
| `recordPaymentFrom` | W store | — | — | — | OK |
| `_acceptFundsFor` | W actual | — | — | — | OK |
| `mintFor` (credits path) | — | W both | — | — | OK |
| `mintFor` (token path) | — | — | — | — | OK (token.mint handles) |
| `burnFrom` | — | W both | — | — | OK |
| `claimTokensFor` | — | W both | — | — | OK |
| `transferCreditsFrom` | — | W balance only | — | — | OK (totalCreditSupply unchanged) |
| `processHeldFeesOf` | — | — | W index | — | OK |
| `_returnHeldFees` | W store (via record) | — | W index | — | OK |
| `mintTokensOf` | — | — | — | W pending | OK |
| `sendReservedTokensToSplitsOf` | — | — | — | W pending→0, mint | OK |
| `recordPayoutFor` | W store | — | — | — | OK |
| `recordCashOutFor` | W store | — | — | — | OK |

**No gaps found in the cross-reference.**

---

## Pass 1: Feynman Interrogation — Raw Findings

### Candidate F-001: Fee Rounding Discrepancy (CONFIRMED → NM-001)

**Category 3 (Consistency)**

**Q3.3:** "If `feeAmountFrom` is called N times on individual split amounts vs once on the aggregate, are they guaranteed equal?"

**Answer:** No. `mulDiv(a, p, MAX_FEE) + mulDiv(b, p, MAX_FEE)` can differ from `mulDiv(a+b, p, MAX_FEE)` by up to 1 wei per term due to integer truncation.

**Location:**
- Per-split fee deduction: `JBMultiTerminal.sol:556` (`executePayout`)
- Aggregate fee processing: `JBMultiTerminal.sol:1887` (`_takeFeeFrom`)

**Assessment:** LOW — dust-level impact only.

---

### Candidate F-002: Data Hook Unconstrained Override (CONFIRMED → NM-003)

**Category 4 (Assumptions)**

**Q4.2:** "What does the store assume about the data hook's return values?"

**Answer:** Complete trust. Data hooks can:
- Override weight (payment) → control token minting rate
- Override cashOutCount, totalSupply, cashOutTaxRate (cash-out) → bypass bonding curve
- Specify hook amounts that divert funds

No bounds checks on any return value except `hookSpecifications` total amount vs available balance.

**Assessment:** INFORMATIONAL — by design, documented trust model.

---

### Candidate F-003: `_processFee` try/catch Swallowing Errors

**Category 6 (Return/Error)**

**Q6.2:** "What happens when `_processFee` fails? Is the fee lost?"

**Answer:** The fee amount is held (added to `_heldFeesOf`). The try/catch at `JBMultiTerminal.sol:1902-1918` catches the revert, records the fee as held, and continues. The fee is NOT lost — it can be processed later via `processHeldFeesOf`.

**Assessment:** FALSE POSITIVE — graceful degradation by design.

---

### Candidate F-004: `recordPayoutFor` / `recordUsedAllowanceOf` State Update Before Validation

**Category 2 (Ordering)**

**Q2.1:** "What if the balance decrement at `JBTerminalStore.sol:352` happens before the payout limit check?"

**Answer:** The function:
1. Reads balance
2. Computes distributedAmount (capped by payout limit)
3. Decrements balance: `balanceOf[..] -= distributedAmount`
4. Increments used: `usedPayoutLimitOf[..] += distributedAmount`

The decrement is safe because `distributedAmount` is already capped by `payoutLimitOf - usedPayoutLimitOf` (line 322-339), and the balance itself was read before the computation. Solidity 0.8.26 would revert on underflow.

**Assessment:** FALSE POSITIVE — ordering is correct; cap applied before decrement.

---

### Candidate F-005: `_returnHeldFees` Unchecked Subtraction

**Category 5 (Boundaries)**

**Q5.1:** "Can `leftoverAmount -= amountPaidOut` underflow?"

**Answer:** No.
- `amountPaidOut = feeAmount + feeAmountResultingIn(feeAmount, FEE)`
- `feeAmountResultingIn(x, p) = mulDiv(x, MAX_FEE, MAX_FEE - p) - x`
- For FEE=25, MAX_FEE=1000: `feeAmountResultingIn(x, 25) = mulDiv(x, 1000, 975) - x ≈ x * 25/975 ≈ 0.02564x`
- `amountPaidOut = feeAmount + feeAmount * 25/975 = feeAmount * 1000/975`
- Since `leftoverAmount` comes from `addToBalanceOf` amount which includes both fee and net portions, and we iterate through held fees that were originally taken from amounts flowing through this terminal, `leftoverAmount >= amountPaidOut` is enforced by the check at line 1641.

**Assessment:** FALSE POSITIVE — guarded by explicit check.

---

### Candidate F-006: Cash-Out Hook Reentrancy Window

**Category 7 (External Call Reordering)**

**Q7.3:** "In `_cashOutTokensOf`, after `burnTokensOf` burns the holder's tokens and before `_transferFrom` sends reclaimed funds, can a hook re-enter?"

**Answer:** The sequence is:
1. `STORE.recordCashOutFor` — decrements store balance (effects)
2. `CONTROLLER.burnTokensOf` — burns tokens (effects)
3. `_transferFrom` to beneficiary — sends reclaimed amount (interaction)
4. Hook calls (if any) — with `afterCashOutRecordedContext` (interaction)
5. `_takeFeeFrom` — processes fees (interaction)

This follows checks-effects-interactions. By step 3, the store balance and token supply are already updated. A re-entrant call would see the correct post-cash-out state.

**Assessment:** FALSE POSITIVE — CEI pattern correctly applied.

---

### Candidate F-007: `beneficiaryTokenCount` Measurement

**Category 4 (Assumptions)**

**Q4.2:** "In `_pay`, the beneficiary token count is measured via `TOKENS.totalBalanceOf` before and after. What if the hook mints additional tokens?"

**Answer:** The measurement at `JBMultiTerminal.sol:780-785` captures the ACTUAL token count received by the beneficiary, including any hook-minted tokens. This is intentional — it reports what the beneficiary actually received. The `controller.mintTokensOf` call may route tokens through reserved splits, so the beneficiary's share may differ from the total minted.

**Assessment:** FALSE POSITIVE — correct measurement by design.

---

### Candidate F-008: `migrateBalanceOf` Doesn't Migrate Held Fees

**Category 1 (Purpose)**

**Q1.1:** "Why doesn't `migrateBalanceOf` transfer held fees to the new terminal?"

**Answer:** Held fees are obligations of the terminal to the fee project (project #1). They are not part of the project's balance — they are amounts that have already been deducted from the project's balance but not yet sent to the fee project. The project's `balanceOf` in the store is already net of these fees. Migration correctly transfers only the project's balance.

**Assessment:** FALSE POSITIVE — held fees are terminal obligations, not project balance.

---

### Candidate F-009: Reserved Token Splits Use Current Ruleset

**Category 3 (Consistency)**

**Q3.2:** "`sendReservedTokensToSplitsOf` uses the CURRENT ruleset's splits, not the ruleset that was active when payments were made. Is this correct?"

**Answer:** Yes — this is a governance design choice. Reserved tokens accumulate across rulesets and are distributed according to the current ruleset's split configuration. This allows projects to update their split recipients without losing accumulated reservations.

**Assessment:** FALSE POSITIVE — design choice, not bug. Documented behavior.

---

### Candidate F-010: `totalTokenSupplyWithReservedTokensOf` Double-Counting

**Category 1 (Purpose)**

**Q1.2:** "Does `totalTokenSupplyWithReservedTokensOf` double-count tokens?"

**Answer:** No.
- `TOKENS.totalSupplyOf(projectId)` = actual minted tokens (ERC-20 + credits)
- `pendingReservedTokenBalanceOf[projectId]` = tokens not yet minted but owed
- Sum = total supply for cash-out calculations

This is used in `recordCashOutFor` (line 522) as the `totalSupply` for the bonding curve. The pending reserved tokens are correctly included to prevent cash-out holders from claiming surplus that's owed to reserved token recipients.

**Assessment:** FALSE POSITIVE — correct accounting.

---

### Candidate F-011: Deploy Script Stale "v5" References (CONFIRMED → NM-004)

**Category 1 (Purpose)**

**Q1.1:** "Why does a v6 deploy script reference 'nana-core-v5'?"

**Answer:** Stale references. The Sphinx project name and CoreDeploymentLib constant should reference v6.

**Locations:**
- `script/Deploy.s.sol:44`: `sphinxConfig.projectName = "nana-core-v5"`
- `script/DeployPeriphery.s.sol:50`: `sphinxConfig.projectName = "nana-core-v5"`
- `script/helpers/CoreDeploymentLib.sol:43`: `string constant PROJECT_NAME = "nana-core-v5"`

**Assessment:** INFORMATIONAL — deployment hygiene, not a security vulnerability.

---

### Candidate F-012: Hardcoded Omnichain Operator (CONFIRMED → NM-005)

**Category 4 (Assumptions)**

**Q4.1:** "Who controls the `OMNICHAIN_RULESET_OPERATOR` address? What if it's compromised?"

**Answer:** Hardcoded at `script/DeployPeriphery.s.sol:20`. This address receives cross-chain ruleset management privileges. Operational concern for deployment awareness.

**Assessment:** INFORMATIONAL.

---

### Candidate F-013: Front-Running Cash-Out with Surplus Manipulation

**Category 7 (Multi-Tx)**

**Q7.8:** "Can an attacker pay into a project to inflate surplus, then cash out to extract more than they put in?"

**Answer:** No. The bonding curve ensures that:
- Payment increases both surplus AND totalSupply proportionally (via new tokens minted)
- Cash-out reclaims proportional to `cashOutCount/totalSupply * surplus * tax_factor`
- The attacker's new tokens dilute their share of the surplus proportionally
- The 2.5% fee on cash-out means the attacker always loses money on a pay→cashOut cycle

**Assessment:** FALSE POSITIVE — bonding curve economics prevent this.

---

### Candidate F-014: Sandwich Attack on Surplus Allowance

**Category 7 (Multi-Tx)**

**Q7.8:** "Can an attacker sandwich a `useAllowanceOf` call to profit?"

**Answer:** No. `useAllowanceOf` withdraws from surplus, reducing future cash-out values. An attacker who buys tokens before the allowance use and sells after would:
- Pay the bonding curve premium to buy
- See reduced surplus after the allowance use
- Sell at a lower bonding curve price
- Net result: loss (plus fees)

**Assessment:** FALSE POSITIVE — economically unprofitable.

---

### Candidate F-015: `leftoverPayoutAmount` Accounting on Failed Split Payout

**Category 6 (Return/Error)**

**Q6.2:** "If `executePayout` reverts in the try/catch at line 595, is the leftover correctly restored?"

**Answer:** Yes.
- `JBMultiTerminal.sol:596-599`: On failure, `leftoverPayoutAmount += payoutAmount`
- The failed payout amount is added back to leftover (which goes to the project owner)
- `amountEligibleForFees` is NOT incremented for the failed payout
- Accounting is correct: the failed split's amount returns to the project, no fee charged

**Assessment:** FALSE POSITIVE — correct failure handling.

---

### Candidate F-016: `executePayReservedTokenToTerminal` Token Leakage

**Category 7 (External Call Reordering)**

**Q7.3:** "In `executePayReservedTokenToTerminal`, after `forceApprove` and `terminal.pay`, could tokens be left approved?"

**Answer:** No. The function at line 505-523:
1. `forceApprove(terminal, tokenCount)` — sets approval
2. `terminal.pay(...)` — pays (consuming approval)
3. `token.allowance(this, terminal)` check — verifies approval was consumed
4. If allowance remains, reverts with `JBController_PayReservedTokenToTerminalFailed`

**Assessment:** FALSE POSITIVE — explicit allowance check prevents leakage.

---

### Candidate F-017: Weight Decay Iteration Threshold

**Category 5 (Boundaries)**

**Q5.2:** "What happens when `deriveWeightFrom` exceeds the 20,000 iteration threshold?"

**Answer:** `JBRulesets.sol:829` — the function reverts with `JBRulesets_WeightNotFound()` if it iterates more than 20,000 times without finding a cached weight. This is a safety limit. The `updateRulesetWeightCache` function allows projects to cache their current weight at any time, resetting the iteration count for future calls.

**Assessment:** FALSE POSITIVE — safety limit with escape hatch (weight caching).

---

### Candidate F-018: Permit2 Failure Silently Ignored

**Category 6 (Return/Error)**

**Q6.3:** "In `_acceptFundsFor`, the Permit2 call is wrapped in try/catch. What if it fails?"

**Answer:** The function tries Permit2 permit first, and if it fails, continues with the standard `_transferFrom`. If the user already has a standard ERC-20 approval set, the transfer succeeds without Permit2. The try/catch is intentional to allow fallback to standard approvals.

**Assessment:** FALSE POSITIVE — graceful fallback by design.

---

### Candidate F-019: `_tokenSurplusFrom` Payout Limit Underflow

**Category 5 (Boundaries)**

**Q5.1:** "Can `payoutLimit.amount - usedPayoutLimitOf[..]` underflow?"

**Answer:** No. `usedPayoutLimitOf` is only incremented in `recordPayoutFor`, which caps the increment at `payoutLimit.amount - usedPayoutLimitOf[..]` (line 322-339). Therefore `used <= limit` is always true, and the subtraction is safe.

**Assessment:** FALSE POSITIVE — invariant maintained by write-side cap.

---

### Candidate F-020: `recordCashOutFor` hookSpecifications Over-Withdrawal

**Category 4 (Assumptions)**

**Q4.2:** "Can data hook `hookSpecifications` amounts exceed available balance?"

**Answer:** Checked at `JBTerminalStore.sol:571-577`:
```solidity
uint256 balanceDiff = reclaimAmount + hookSpecificationsTotalAmount;
if (balanceDiff > balanceOf[msg.sender][projectId][tokenAddress])
    revert JBTerminalStore_InadequateTerminalStoreBalance();
```

**Assessment:** FALSE POSITIVE — explicit bounds check prevents over-withdrawal.

---

## Pass 2: State Inconsistency Audit

### Coupled State Pairs (from Phase 1B)

All 10 pairs (CP-1 through CP-10) analyzed. See verified report for the full matrix.

### Mutation Matrix — Full Analysis

Every mutation path for every coupled state variable was traced. No gaps found.

Key verification points:
- **CP-2 (`creditBalanceOf ↔ totalCreditSupplyOf`)**: Updated atomically in `mintFor` (L304-305), `burnFrom` (L158-159), `claimTokensFor` (L205-208). `transferCreditsFrom` correctly doesn't modify `totalCreditSupplyOf` since it's a transfer between holders.
- **CP-3 (`tokenOf ↔ projectIdOf`)**: Set together in `deployERC20For` (L258-261) and `setTokenFor` (L334-337). Never unset (by design — once a token is set, it persists).
- **CP-6 (`_heldFeesOf ↔ _nextHeldFeeIndexOf`)**: Index only advances in `processHeldFeesOf` (L496) and `_returnHeldFees` (L1633). Array only grows in `_takeFeeFrom` (L1912). Index is bounded by array length.
- **CP-7 (`pendingReservedTokenBalanceOf ↔ totalSupply`)**: Pending incremented in `mintTokensOf`, zeroed and minted in `sendReservedTokensToSplitsOf`. Cash-out uses `totalTokenSupplyWithReservedTokensOf` which sums both.

### Parallel Path Comparison

| Coupled State | `pay` | `addToBalance` | `sendPayouts` | `useAllowance` | `cashOut` | `migrate` |
|---------------|-------|----------------|---------------|----------------|-----------|-----------|
| store balance | W (+) | W (+) | W (-) | W (-) | W (-) | W (→0) |
| actual balance | W (+) | W (+) | W (-) | W (-) | W (-) | W (-) |
| held fees | — | return | — | — | — | — |
| used payout | — | — | W (+) | — | — | — |
| used allowance | — | — | — | W (+) | — | — |

All paths consistently update their relevant coupled state.

### Masking Code Audit

**Pattern found at `JBMultiTerminal.sol:1645`:**
```solidity
// In _returnHeldFees, within the loop:
if (leftoverAmount >= amountPaidOut) {
    leftoverAmount -= amountPaidOut;
    returnedFees += fee.amount;
    // ...
} else {
    // Partial return path
}
```

This is NOT masking a broken invariant — it's correctly handling the case where the incoming amount only partially covers outstanding held fees. The `>=` check is the correct guard for the subtraction.

**Pattern found at `JBCashOuts.sol:37`:**
```solidity
if (cashOutCount >= totalSupply) return surplus;
```

This is NOT masking — it's the edge case where someone cashes out everything. Returning full surplus is the correct mathematical result of the bonding curve formula at this boundary.

**No masking patterns hiding broken invariants found.**

---

## Pass 2 Finding: Held Fee Return Rounding (→ NM-002)

During mutation matrix analysis of CP-6, the `_returnHeldFees` function was found to use `feeAmountResultingIn` (reverse fee calculation) which can produce a 1-wei difference from the forward calculation `feeAmountFrom`. This is inherent to integer arithmetic and produces an INFORMATIONAL-level rounding asymmetry favoring the project (slightly more fee is "returned").

---

## Pass 3: Convergence Check

### Targeted Re-interrogation on Pass 2 Outputs

**Pass 2 produced no new coupled pairs, no new suspects, no masking patterns hiding bugs.**

The only new item was NM-002 (held fee rounding), which was immediately verified as INFORMATIONAL.

Re-interrogation of NM-002 via Feynman:
- **Q:** "WHY does `feeAmountResultingIn` produce a different result than `feeAmountFrom`?"
- **A:** Different `mulDiv` operations with different rounding directions. `feeAmountFrom(x,p) = floor(x*p/M)`. `feeAmountResultingIn(net,p) = ceil(net*M/(M-p)) - net`. The ceiling in the reverse direction gives a result that is 0 or 1 wei larger than the forward direction.
- **Impact:** 1 wei per held fee return. Economically negligible.
- **No new suspects or coupled pairs emerged.**

**CONVERGENCE ACHIEVED — No new findings in Pass 3.**

---

## Phase 5: Multi-Transaction Journey Tracing

### Journey 1: Deposit → Partial Withdraw → Claim Rewards
1. Alice pays 1000 USDC to project → gets 1000 tokens (weight=1, no tax)
2. Bob pays 1000 USDC → gets 1000 tokens
3. Project owner sends payouts (500 USDC payout limit)
4. Alice cashes out 500 tokens → gets `cashOutFrom(1500, 500, 2000, rate)` USDC
5. Alice cashes out remaining 500 tokens → gets `cashOutFrom(1500-prev, 500, 1500, rate)` USDC

**Result:** Accounting correct at each step. Store balance tracks correctly. Bonding curve provides correct proportional claims. Pending reserved tokens included in totalSupply.

### Journey 2: Stake → Unstake Half → Restake → Unstake All
1. Alice pays 1000 tokens worth → gets tokens
2. Alice cashes out half → gets proportional surplus
3. Alice pays again → gets new tokens at CURRENT weight/rate
4. Alice cashes out all → gets proportional surplus of remaining balance

**Result:** Each step correctly uses CURRENT state. No stale state accumulation.

### Journey 3: Payout with Fee → addToBalance → Payout Again
1. Project sends 1000 USDC payout → 25 USDC fee taken → 975 to recipient
2. Someone calls `addToBalanceOf(500 USDC)` → `_returnHeldFees` returns some fees
3. Next cycle: project sends another 1000 USDC payout

**Result:** Held fees correctly tracked. Return mechanism correctly computes reverse fees. No double-charging.

### Journey 4: Fee Holding → Processing → Migration
1. Fees accumulated and held (28-day period)
2. `processHeldFeesOf` called → fees sent to project #1
3. Project migrates to new terminal

**Result:** Migration transfers `balanceOf` (net of fees). Held fees remain with old terminal and can still be processed. No value loss.

### Journey 5: Data Hook Override Cash-Out
1. Project sets a data hook
2. Data hook overrides `cashOutTaxRate = 0` (no tax)
3. User cashes out → gets full linear proportion
4. Data hook changes to `cashOutTaxRate = MAX` (100% tax)
5. User cashes out → gets 0

**Result:** Data hook has full control by design. No invariant violation — the trust assumption is documented.

### No adversarial sequences found that produce incorrect results.

---

## Phase 6: Verification Gate

All 5 findings verified via Method A (code trace). No findings required PoC (no C/H/M severity findings).

See verified report for verification details.

---

## Summary

- **Raw candidates analyzed:** 20
- **Confirmed findings:** 5 (1 LOW + 4 INFORMATIONAL)
- **False positives eliminated:** 15
- **Feedback loop discoveries:** 1 (NM-002 from State→Feynman cross-feed)
- **Convergence:** Pass 3 (no new findings)
- **Final severity distribution:** 0 CRITICAL | 0 HIGH | 0 MEDIUM | 1 LOW | 4 INFORMATIONAL
