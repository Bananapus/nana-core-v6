# nana-core-v6 -- Active Risk Vectors

Known security properties, trust assumptions, active vulnerability surfaces, and operational risks. Intended audience: experienced Solidity auditors looking for where to focus.

## 1. Trust Assumptions

What must be true for the system to remain safe:

- **Hooks do not exploit reentrancy.** No `ReentrancyGuard` anywhere in core. All safety relies on checks-effects-interactions ordering and the `JBTerminalStore_InadequateTerminalStoreBalance` backstop. If a hook finds a code path where state is read before a prior write has settled, value extraction may be possible.
- **Data hooks are honest.** A data hook has absolute control over payment weight, cash out tax rate, `totalSupply`, `cashOutCount`, and fund-forwarding amounts. A malicious data hook can bypass the bonding curve entirely (e.g., set `totalSupply = surplus` to get 1:1 redemptions) or divert 100% of incoming payments to external hooks. The protocol enforces `sum(hook.amount) <= payment.value` and `reclaimAmount + sum(hook.amount) <= project balance`, but within those bounds the hook is omnipotent.
- **Price feeds do not lie.** Surplus calculations, currency conversions for payouts, and surplus allowance all depend on `JBPrices`. A manipulated or stale feed causes incorrect surplus values. Chainlink feeds have staleness thresholds and sequencer checks, but project-specific feeds registered via `allowAddPriceFeed` have no such guarantee -- a project owner can register a feed that returns any value.
- **ERC-20 tokens behave standardly.** `_acceptFundsFor` uses a balance-before/after pattern, which handles fee-on-transfer tokens. However, rebasing tokens that change balances between transactions will cause `balanceOf` in `JBTerminalStore` to diverge from actual terminal holdings. Missing-return-value tokens are handled by `SafeERC20`.
- **Trusted forwarder is not compromised.** The ERC-2771 forwarder is immutable. If compromised, it can spoof `_msgSender()` for all permission-gated functions across `JBController`, `JBMultiTerminal`, `JBProjects`, `JBPrices`, and `JBPermissions`.
- **Project #1 terminal remains functional.** If the fee beneficiary project's terminal reverts, `_processFee` catches the error and returns the fee amount to the originating project's balance. This is safe but means fees are silently forgiven during outages.
- **`OMNICHAIN_RULESET_OPERATOR` is trusted.** This immutable address bypasses owner permission checks for `launchRulesetsFor`, `queueRulesetsOf`, and `setTerminalsOf`. A compromised operator can queue arbitrary rulesets for any project.

## 2. Economic Risks

### Bonding Curve

- **Zero cash out guard.** `cashOutFrom` returns 0 when `cashOutCount == 0` (line 31 early return). Auditors should verify no code path bypasses this guard or reaches the `cashOutCount >= totalSupply` branch (line 37) with both values at 0.
- **Pending reserved tokens inflate `totalSupply`.** `totalTokenSupplyWithReservedTokensOf()` adds `pendingReservedTokenBalanceOf` to `totalSupply`, reducing per-token cash out value. A project owner who delays calling `sendReservedTokensToSplitsOf()` can suppress cash out values. Auditors should model the magnitude of this effect for projects with large pending reserves.
- **`mulDiv` rounding.** The bonding curve's subadditivity property (`cashOutFrom(a) + cashOutFrom(b) <= cashOutFrom(a+b)`) can be violated by <0.01% due to floor rounding. Economically insignificant per operation but could accumulate across many small cash outs.
- **Binary search in `minCashOutCountFor`.** The inverse cash out function uses binary search over `[1, totalSupply]`. For large supplies (>2^128), this is ~128 iterations of `mulDiv` calls. Verify gas cost remains bounded.

### Fee Arithmetic

- **Forward vs. backward fee asymmetry.** `feeAmountFrom` (forward) uses `mulDiv(amount, 25, 1000)`. `feeAmountResultingIn` (backward) uses `mulDiv(amount, 1000, 975) - amount`. These are algebraically equivalent but rounding differs. In `_returnHeldFees`, both are used on the same held fee entry (forward to compute `feeAmount`, backward when partially returning). Verify the interplay never undercharges.
- **Held fee amount mutation.** `_returnHeldFees` mutates `heldFee.amount` in-place via unchecked subtraction (line 1583). If the accounting is off by even 1 wei in the wrong direction, this underflows and corrupts the held fee entry.

### First Cycle Behavior

- **`currentOf()` returns the stored ruleset directly in the first cycle.** The first cycle (`cycleNumber == 1`) uses the original weight with no decay applied. Weight decay via `weightCutPercent` only takes effect from the second cycle onward. This is by design and verified by test (`TestAuditResponseDesignProofs.test_currentOf_firstCycle_returnsOriginalWeight`).

### Weight Decay

- **Weight cache starvation as DoS.** Projects with short duration and nonzero `weightCutPercent` that run >20,000 cycles without a cache update will revert on `currentOf()` with `WeightCacheRequired`. This blocks all operations (pay, cash out, payouts). Anyone can call `updateRulesetWeightCache()` to fix it, but an attacker could create projects designed to hit this.
- **Weight truncation.** Derived weight is cast to `uint112` in `_simulateCycledRulesetBasedOn`. If the derived weight exceeds `type(uint112).max` (unlikely but theoretically possible if cache state is corrupted), silent truncation occurs.

### Surplus Manipulation

- **Cross-terminal surplus aggregation.** When `useTotalSurplusForCashOuts` is enabled, `recordCashOutFor` aggregates surplus across all terminals via `JBSurplus.currentSurplusOf()`, which calls `terminal.currentSurplusOf()` on each. If a malicious terminal is added to the project's directory, it could report inflated surplus. Defense: `InadequateTerminalStoreBalance` revert prevents extracting more than the actual terminal balance.
- **Price feed inconsistency across terminals.** Different tokens in different terminals are converted to a common currency via `JBPrices`. If price feeds between terminals are stale or inconsistent, aggregated surplus can be inflated/deflated, affecting cash out reclaim amounts.

## 3. Reentrancy Surface

No `ReentrancyGuard` is used. The system relies on state ordering and the `InadequateTerminalStoreBalance` backstop.

### External Call Map

| Function | State Changes Before External Call | External Calls | Risk |
|----------|-----------------------------------|----------------|------|
| `_pay` | `STORE.recordPaymentFrom` (balance incremented), `controller.mintTokensOf` (tokens minted) | Pay hooks via `_fulfillPayHookSpecificationsFor` | LOW -- full state settlement before hooks |
| `_cashOutTokensOf` | `STORE.recordCashOutFor` (balance decremented), `controller.burnTokensOf` (tokens burned), `_transferFrom` (beneficiary paid) | Cash out hooks via `_fulfillCashOutHookSpecificationsFor`, then `_takeFeeFrom` | MEDIUM -- beneficiary receives funds before hooks execute; hooks run before fees are taken |
| `executePayout` | `STORE.recordPayoutFor` already consumed payout limit | `split.hook.processSplitWith`, `terminal.pay/addToBalance` | MEDIUM -- split hook receives funds and can re-enter; payout limit already consumed prevents double-payout |
| `processHeldFeesOf` | `delete _heldFeesOf[...][currentIndex]`, `_nextHeldFeeIndexOf` incremented | `_processFee` -> `this.executeProcessFee` -> `terminal.pay` | LOW -- index advanced before external call; re-reads from storage each iteration |
| `_sendReservedTokensToSplitsOf` | `pendingReservedTokenBalanceOf` zeroed, tokens minted to controller | Split hooks, terminal payments | LOW -- pending balance cleared before minting prevents double-distribution |
| `_useAllowanceOf` | `STORE.recordUsedAllowanceOf` (allowance consumed, balance decremented) | `_takeFeeFrom` (fee payment/holding), `_transferFrom` (beneficiary) | LOW -- allowance consumed before calls |
| `migrateBalanceOf` | `STORE.recordTerminalMigration` (balance zeroed) | `to.addToBalanceOf` | LOW -- balance zeroed before transfer |

### Cross-Function Reentrancy to Explore

- **Pay hook -> `cashOutTokensOf`**: After `_pay` mints tokens, a pay hook could call `cashOutTokensOf`. The cash out sees post-payment balance and post-mint supply. Not profitable after fees in tested scenarios, but verify with data hooks that modify weights.
- **Cash out hook -> `pay`**: During `_cashOutTokensOf`, after tokens are burned and beneficiary is paid, a cash out hook could call `pay()` adding to the balance. Fees haven't been taken yet at this point. Verify the fee calculation on `amountEligibleForFees` isn't affected.
- **Split hook -> `pay` on same project**: During `sendPayoutsOf`, a split hook receives funds and calls `pay()` on the same project. Payout limit is consumed, but the payment increases balance and mints tokens. The funds came from the project's own balance, so no value creation -- but verify the accounting.
- **Fee processing -> any re-entry**: `_processFee` uses `this.executeProcessFee` (external call via try-catch). Inside, it calls `terminal.pay()` on project #1. If project #1 has a pay hook that calls back, the fee amount is already deducted.

### Key Backstop

`JBTerminalStore_InadequateTerminalStoreBalance` revert prevents extracting more than the recorded balance from any terminal regardless of reentrancy state. This is the final defense for all value extraction paths. Auditors should verify this check cannot be bypassed by manipulating the recorded balance (e.g., via `recordAddedBalanceFor`, which has no access control -- balance is keyed by `msg.sender`, so only a terminal can inflate its own balance).

## 4. Access Control

### Permission System

- **ROOT (ID 1) grants all permissions.** Including permissions not yet defined. Future permission IDs automatically fall under ROOT.
- **ROOT cannot be set for wildcard `projectId = 0`.** The actual enforcement in `setPermissionsFor` is: if the caller is not the account itself, they must have ROOT for the target project, AND they cannot set ROOT for others, AND they cannot set any permissions on the wildcard project. ROOT holders for a specific project can set non-ROOT permissions for operators on that project. Auditors should verify the exact boundary -- particularly whether a ROOT operator on project X can escalate to ROOT on project Y through any indirect path.
- **Empty permission arrays pass `hasPermissions`.** By design (vacuous truth). Any caller that expects "the operator has at least one of these permissions" must validate the array is non-empty.
- **`OMNICHAIN_RULESET_OPERATOR` bypass.** This immutable address can `launchRulesetsFor`, `queueRulesetsOf`, and set terminals for any project without owner permission. The trust assumption is that this operator only queues rulesets that the omnichain deployer's logic permits. If this address is an EOA or an upgradeable contract, it is a single point of failure for all projects.

### Splits GroupId Namespace

- **GroupId namespace overlap between terminals and token contracts is prevented.** Terminals use `uint160(tokenAddress)` as the `groupId` for payout split groups -- these have zero upper 96 bits. The self-auth path in `setSplitGroupsOf` now requires the upper 96 bits of the `groupId` to be non-zero (in addition to the lower 160 bits matching `msg.sender`). This means bare-address groupIds (upper 96 bits = 0) are protocol-reserved and always require controller authorization. Without this restriction, an accepted token contract could call `setSplitGroupsOf` to overwrite the terminal's payout splits for its own address. The 721 hook is unaffected since it uses `hookAddress | tierId << 160` (non-zero upper bits).

### Migration

- **Controller migration** requires `allowSetController` in the current ruleset. During migration, `JBController.migrate()` reverts if there are pending reserved tokens. An attacker cannot front-run migration to inflate pending reserves (they'd need mint permission), but a project with organic pending reserves must distribute them first.
- **Terminal migration** requires `allowTerminalMigration` in the current ruleset. Held fees are intentionally NOT migrated -- they belong to project #1. Verify that a project owner cannot use migration to escape held fee obligations.
- **Directory updates** (`setTerminalsOf`, `setControllerOf`) are gated by `IJBDirectoryAccessControl` checks that read from the current ruleset's metadata flags. If the current ruleset allows these changes, anyone with the appropriate permission can redirect all of a project's fund flows.

### Ruleset Queuing

- Only the project's controller can call `RULESETS.queueFor()` (enforced by `onlyControllerOf` modifier).
- The controller allows queuing by the project owner, anyone with `QUEUE_RULESETS` permission, or the `OMNICHAIN_RULESET_OPERATOR`.
- For `duration = 0` projects, a queued ruleset takes effect immediately. This means an owner can atomically change all project economics (weight, tax rate, splits, payout limits) in the same transaction as other operations.

## 5. DoS Vectors

### Unbounded Arrays

| Array | Growth Mechanism | Cleanup | Risk |
|-------|-----------------|---------|------|
| `_heldFeesOf[projectId][token]` | Each held-fee payout appends | `_nextHeldFeeIndexOf` pointer skips processed; full delete when all processed | MODERATE -- if held fees accumulate faster than the 28-day unlock window, the array grows unboundedly. `processHeldFeesOf` takes a `count` param, so partial processing is possible. |
| `splits[]` | Set by project owner per ruleset | Replaced wholesale | MODERATE -- no explicit cap. At 100+ splits, `_sendPayoutsToSplitGroupOf` gas exceeds 10M. Percentage constraint limits useful splits to ~300-500 but doesn't prevent a malicious owner from setting more. |
| `_accountingContextsOf[projectId]` | `addAccountingContextsFor` (append-only) | Never shrinks | LOW -- duplicate prevention limits growth; realistic max ~100 tokens. But since it's append-only, a project that accepts many tokens over time cannot remove old ones. |
| Payout limits / surplus allowances | Set per ruleset | Replaced per ruleset | LOW -- currency ordering constraint limits ~30-50. |
| `_terminalsOf[projectId]` | `setTerminalsOf` (replaced wholesale) | Replaced | LOW -- realistic max 5-10. |

### Price Feed Reverts

- If a Chainlink feed is stale beyond its threshold, `JBChainlinkV3PriceFeed` reverts. This blocks all multi-currency operations for projects using that feed: `pay`, `cashOutTokensOf`, `sendPayoutsOf`, `useAllowanceOf`.
- L2 sequencer downtime triggers `JBChainlinkV3SequencerPriceFeed` to revert during downtime + grace period.
- Single-currency projects (where `amount.currency == ruleset.baseCurrency()`) are unaffected.
- Price feeds are immutable once set in `JBPrices` -- a broken feed cannot be replaced.

### Approval Hook Griefing

- A reverting approval hook is caught by try-catch and treated as `Failed`. This causes fallback to `basedOnId` chain.
- A gas-consuming approval hook (e.g., infinite loop) can DoS `currentOf()` via gas exhaustion. The try-catch does not limit gas. This is accepted risk since the project owner chose their own approval hook, but it means a malicious approval hook can permanently freeze its project's operations.
- Approval hook rejection at a ruleset boundary triggers complex fallback behavior: the protocol simulates cycling from the last approved ruleset. Verify this simulation always produces economically correct results, especially when multiple rulesets are queued and rejected in sequence.

### Other DoS Surfaces

- `sendPayoutsOf` is callable by anyone (unless `ownerMustSendPayouts` is set). A split recipient that always reverts will cause that split's payout to fail, but the try-catch returns the amount to the project balance. Payout limit is still consumed. The project owner must wait until the next cycle.
- `addAccountingContextsFor` is gated by `allowAddAccountingContext` in the ruleset, but the contexts array is append-only and never shrinks. Over many rulesets, this could grow large enough to cause gas issues in functions that iterate over all contexts (e.g., `currentSurplusOf` when no explicit contexts are passed).

## 6. Preview Functions

`JBMultiTerminal.previewPayFor`, `JBMultiTerminal.previewCashOutFrom`, and `JBController.previewMintOf` are `view` functions that simulate operations without modifying state. They compose the same computation paths as the real operations.

- **Data hooks are called during previews.** `previewPayFor` and `previewCashOutFrom` invoke `beforePayRecordedWith` and `beforeCashOutRecordedWith` on data hooks. A reverting data hook causes the preview to revert. A gas-consuming hook can cause the preview to run out of gas.
- **Store previews use `msg.sender` as terminal.** `JBTerminalStore.previewPayFrom` and `previewCashOutFrom` use `msg.sender` for balance/surplus lookups. Only a registered terminal calling these will get correct results. External callers should use the terminal-level functions (`JBMultiTerminal.previewPayFor` / `previewCashOutFrom`) which handle this automatically.
- **No state modification risk.** Preview functions cannot change balances, mint/burn tokens, or consume limits. They are safe to call from any context.

## 7. Integration Risks

### Non-Standard ERC-20s

- **Fee-on-transfer tokens**: Handled by `_acceptFundsFor` using balance-before/after pattern. The actual received amount is used, not the passed `amount`. However, `_transferFrom` for outbound transfers uses the nominal amount. If the token charges fees on transfer-out, the terminal's actual balance decreases more than `balanceOf` in the store records. Over time, `terminal.balance(token) < sum(store.balanceOf(projectId, terminal, token))`, breaking the balance conservation invariant.
- **Rebasing tokens**: Tokens that change balances (e.g., stETH, AMPL) will cause `JBTerminalStore.balanceOf` to diverge from actual terminal holdings. Positive rebases create untracked surplus; negative rebases can cause `InadequateTerminalStoreBalance` reverts on withdrawals.
- **Tokens with blocklists** (e.g., USDC, USDT): If a split beneficiary or cash out beneficiary is blocklisted, the transfer reverts. For split payouts, try-catch returns the amount to the project. For cash out beneficiaries, the entire `cashOutTokensOf` call reverts.
- **Low-decimal tokens** (e.g., USDC with 6 decimals): Weight and token counts use 18 decimals internally. The fixed-point conversion in `recordPaymentFrom` uses `mulDiv(amount.value, weight, weightRatio)`. With large weight values and small decimal tokens, precision loss may be significant.

### Permit2 Interactions

- `_acceptFundsFor` tries direct ERC-20 `transferFrom` first (if allowance is sufficient), then falls back to Permit2. The Permit2 `permit` call is wrapped in try-catch -- failure emits an event but doesn't revert the payment.
- `_transferFrom` for outbound transfers also falls back to Permit2 if direct allowance is insufficient. This means outbound transfers (to beneficiaries, split hooks) may unexpectedly use Permit2 state.
- The `uint160` cast on line 1897 of `JBMultiTerminal.sol` limits Permit2 transfers to `type(uint160).max`. Amounts above this revert with `OverflowAlert`.

### Cross-Terminal Surplus Aggregation

- `JBSurplus.currentSurplusOf` calls `terminal.currentSurplusOf()` on each terminal. These are external view calls with no gas limit. A malicious or gas-expensive terminal can cause this aggregation to revert, blocking cash outs for any project that has `useTotalSurplusForCashOuts` enabled and uses that terminal.
- The surplus calculation converts each terminal's balance to a common currency via price feeds. Rounding accumulates across terminals. With N terminals and M tokens each, there are N*M price conversions, each with up to 1 wei of rounding error.

### `recordAddedBalanceFor` Access Control

- `JBTerminalStore.recordAddedBalanceFor` has **no access control**. Any address can call it. The balance is keyed by `msg.sender` (the terminal address), so only a terminal can inflate its own recorded balance. This is safe as long as all terminals correctly track their actual holdings. A buggy or malicious terminal implementation could call `recordAddedBalanceFor` without actually receiving tokens, inflating the recorded balance above actual holdings.

## 8. Invariants to Verify

These should hold at all times and are the most productive targets for formal verification or invariant testing:

### Balance Conservation
- `terminal.balance(token) >= sum(store.balanceOf(projectId, terminal, token))` for all projects sharing a terminal. Fee amounts held but not yet processed are included in the terminal's actual balance but not in any project's store balance. Violation indicates a bug in fee handling or reentrancy.

### Fund Conservation
- Total inflows to a project (payments + `addToBalance`) >= total outflows (payouts + cash outs + surplus allowance usage + fees). Rounding should favor the protocol (fees round up, reclaims round down).

### Fee Monotonicity
- Project #1 balance only increases over time (fees flow in, never out via protocol mechanics). Exception: project #1 itself can pay out or cash out.

### Token Supply Consistency
- `TOKENS.totalSupplyOf(projectId) == creditSupply + erc20.totalSupply()` at all times.
- `totalTokenSupplyWithReservedTokensOf(projectId) == TOKENS.totalSupplyOf(projectId) + pendingReservedTokenBalanceOf[projectId]`.

### Payout Limit Enforcement
- `usedPayoutLimitOf[terminal][projectId][token][cycleNumber][currency] <= payoutLimitOf(...)` after every `recordPayoutFor`. Verify this holds even when the same project pays out from multiple terminals in the same cycle.

### Surplus Allowance Enforcement
- `usedSurplusAllowanceOf[terminal][projectId][token][rulesetId][currency] <= surplusAllowanceOf(...)` after every `recordUsedAllowanceOf`.

### Cash Out Bound
- `reclaimAmount + sum(hookSpecification.amounts) <= balanceOf[terminal][projectId][token]` after every `recordCashOutFor`. This is the `InadequateTerminalStoreBalance` check. Verify it is never circumvented.

### Ruleset Existence
- After `launchProjectFor()`, `RULESETS.currentOf(projectId)` always returns a valid ruleset (non-zero `cycleNumber`). A project in a state where `currentOf` returns an empty ruleset cannot accept payments (`RulesetNotFound` revert), but verify this cannot happen accidentally.

### No Flash-Loan Profit
- `pay() + cashOutTokensOf()` in the same transaction should never be profitable after fees. The 2.5% fee should make single-block round-trips unprofitable. Verify this holds when data hooks modify weights or cash out parameters.

### Same-Terminal Fee Exemption

- **Payouts between projects on the same terminal are fee-exempt by design.** When `executePayout` sends funds to a split's project that uses the same `JBMultiTerminal`, no fee is charged — the payout is routed via `addToBalanceOf` (internal accounting) rather than requiring an external transfer. Fees only apply when funds leave the terminal (sent to an EOA beneficiary or a different terminal). This is intentional: fees protect against fund egress, not intra-terminal accounting moves. Verified by test (`TestAuditResponseDesignProofs.test_sameTerminal_payoutNoFee`).
- **Fee-free surplus tracking prevents round-trip fee bypass.** When a project receives a fee-free intra-terminal payout, `_feeFreeSurplusOf[projectId][token]` is incremented by the payout amount. During cashout with `cashOutTaxRate == 0`, the 2.5% fee is applied only up to this accumulated surplus — then decremented. Once depleted, subsequent cashouts are fee-free again. This scopes the fee precisely to the fee-free inflow: a 1 wei griefing payout only costs the victim fees on 1 wei, not their entire balance. Without this, an attacker could route payouts through a pass-through project with `cashOutTaxRate=0` and cash out fee-free. When `cashOutTaxRate != 0`, the fee applies to the full reclaim amount regardless of surplus. Verified by 7 tests in `TestFeeFreeCashOutBypass.sol`.

### Held Fee Integrity
- `sum(heldFee.amount for active entries) + sum(processed fees) == total fees ever taken with shouldHoldFees=true`. Active entries are those from `_nextHeldFeeIndexOf` to end of array. Verify `_returnHeldFees`' in-place mutation of `heldFee.amount` preserves this invariant.
