# Juicebox Core Risk Register

This file focuses on the accounting, permission, and liveness risks inside the core protocol contracts that everything else in the V6 ecosystem composes with.

## How to use this file

- Read `Priority risks` first; these are the core failures that would propagate far beyond this repo.
- Use the detailed sections below for protocol accounting, reentrancy, access control, preview, and integration reasoning.
- Treat `Invariants to Verify` as ecosystem-critical properties, not optional test ideas.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Core accounting corruption | Terminal, store, and controller accounting are the source of truth for balances, surplus, fees, and supply. A bug here propagates everywhere. | Heavy invariant testing, previews aligned with settlement paths, and conservative external integrations. |
| P0 | Permission or migration mistakes | Controllers, terminals, and operators can redirect authority or value if access control or migration sequencing is wrong. | Strict permission review, migration tests, and scrutiny of wildcard or root-like authority. |
| P1 | Preview or settlement divergence | Many higher-level hooks and routers depend on previews matching reality closely enough to route safely. | Explicit preview analysis, regression tests, and downstream composition review. |

## 1. Trust Assumptions

- **Hooks do not exploit reentrancy.** No `ReentrancyGuard` anywhere in core. All safety relies on checks-effects-interactions ordering and the `JBTerminalStore_InadequateTerminalStoreBalance` backstop. If a hook finds a code path where state is read before a prior write has settled, value extraction may be possible.
- **Data hooks are honest.** A data hook has absolute control over payment weight, cash out tax rate, `effectiveTotalSupply`, `effectiveCashOutCount`, and fund-forwarding amounts. A malicious data hook can bypass the bonding curve entirely (e.g., set `effectiveTotalSupply = surplus` to get 1:1 redemptions) or divert 100% of incoming payments to external hooks. The protocol enforces `sum(hook.amount) <= payment.value` and `reclaimAmount + sum(hook.amount) <= project balance`, but within those bounds the hook is omnipotent. The terminal still burns the caller-supplied cash-out count; the hook-adjusted values affect pricing only.
- **Price feeds do not lie.** Surplus calculations, currency conversions for payouts, and surplus allowance all depend on `JBPrices`. A manipulated or stale feed causes incorrect surplus values. Chainlink feeds have staleness thresholds and sequencer checks, but project-specific feeds registered via `allowAddPriceFeed` have no such guarantee -- a project owner can register a feed that returns any value.
- **ERC-20 tokens behave standardly.** `_acceptFundsFor` uses a balance-before/after pattern, which handles fee-on-transfer tokens on ingress. However, outbound fee-on-transfer behavior and rebasing tokens that change balances between transactions will cause `balanceOf` in `JBTerminalStore` to diverge from actual terminal holdings. These accounting risks are limited to projects that opt into those accounting contexts. Missing-return-value tokens are handled by `SafeERC20`.
- **Reentrant or abusive ERC-20s are out of scope.** Projects choose which accounting contexts this terminal will accept. A token that reenters `pay` or `addToBalanceOf` from `transferFrom`, or otherwise manipulates terminal balance observations mid-transfer, can break the assumptions behind `_acceptFundsFor`'s balance-delta accounting. Core does not harden against intentionally adversarial tokens here; projects that want safe accounting must only accept standard ERC-20s.
- **Trusted forwarder is not compromised.** The ERC-2771 forwarder is immutable. If compromised, it can spoof `_msgSender()` for all permission-gated functions across `JBController`, `JBMultiTerminal`, `JBProjects`, `JBPrices`, and `JBPermissions`.
- **Project #1 terminal remains functional.** If the fee beneficiary project's terminal reverts, `_processFee` catches the error and returns the fee amount to the originating project's balance via `_recordAddedBalanceFor`. This is an intentional fail-open design: the fee is forgiven and a `FeeReverted` event is emitted. For held fees specifically, `processHeldFeesOf` deletes the held-fee entry and advances the index *before* calling `_processFee`, so there is no retry path — once a held fee fails to process, it is permanently forgiven. This prevents a broken fee route from locking project funds indefinitely. The tradeoff is that protocol revenue (project #1) can be lost if the fee terminal is misconfigured. Core deployment alone does not fully initialize fee collection for project `#1`; fee-bearing flows should be treated as fail-open until the fee project's controller, terminals, and accounting contexts are configured.
- **`OMNICHAIN_RULESET_OPERATOR` is trusted.** This immutable address bypasses owner permission checks for `launchRulesetsFor` and `queueRulesetsOf`. It can also indirectly set terminals through `launchRulesetsFor`, but cannot call `setTerminalsOf` directly. A compromised operator can queue arbitrary rulesets for any project. `DeployPeriphery` intentionally validates only that this address is nonzero, so correctness of the configured operator is an out-of-band deployment responsibility.

## 2. Economic Risks

### Bonding Curve

- **Zero cash out guard.** `cashOutFrom` returns 0 when `cashOutCount == 0` (early return). Auditors should verify no code path bypasses this guard or reaches the `cashOutCount >= totalSupply` branch with both values at 0.
- **Pending reserved tokens inflate `totalSupply`.** `totalTokenSupplyWithReservedTokensOf()` adds `pendingReservedTokenBalanceOf` to `totalSupply`, reducing per-token cash out value. A project owner who delays calling `sendReservedTokensToSplitsOf()` can suppress cash out values. Auditors should model the magnitude of this effect for projects with large pending reserves.
- **Externally managed token supply affects only that project's cash-out pricing.** If a project opts into `setTokenFor(...)`, `JBTokens.totalSupplyOf()` trusts the attached token's `totalSupply()`. Any minting, burning, rebasing, or other supply changes on that external token affect only that project's supply-sensitive pricing and cash-out math. Projects that want protocol-controlled supply should use `deployERC20For(...)` instead.
- **`mulDiv` rounding.** The bonding curve's subadditivity property (`cashOutFrom(a) + cashOutFrom(b) <= cashOutFrom(a+b)`) can be violated by <0.01% due to floor rounding. Economically insignificant per operation but could accumulate across many small cash outs.
- **Binary search in `minCashOutCountFor`.** The inverse cash out function uses binary search over `[1, totalSupply]`. For large supplies (>2^128), this is ~128 iterations of `mulDiv` calls. Verify gas cost remains bounded.

### Fee Arithmetic

- **Forward vs. backward fee asymmetry.** `feeAmountFrom` (forward) uses `mulDiv(amount, 25, 1000)`. `feeAmountResultingIn` (backward) uses `mulDiv(amount, 1000, 975) - amount`. These are algebraically equivalent but rounding differs. In `_returnHeldFees`, both are used on the same held fee entry (forward to compute `feeAmount`, backward when partially returning). Verify the interplay never undercharges.
- **Held fee amount mutation.** `_returnHeldFees` mutates `heldFee.amount` in-place via unchecked subtraction. If the accounting is off by even 1 wei in the wrong direction, this underflows and corrupts the held fee entry.

### Weight Decay

- **Weight cache starvation as DoS.** Projects with short duration and nonzero `weightCutPercent` that run >20,000 cycles without a cache update will revert on `currentOf()` with `WeightCacheRequired`. This blocks all operations (pay, cash out, payouts). Anyone can call `updateRulesetWeightCache()` to fix it, but an attacker could create projects designed to hit this.
- **Weight-cache correctness matters more than overflow.** Rulesets reject weights above `type(uint112).max` at queue time, and weight decay only reduces weight over time. The real risk surface is stale or missing cache progress causing `WeightCacheRequired` reverts or incorrect long-horizon simulations if cache updates are applied to the wrong base ruleset.

### Surplus Manipulation

- **Cross-terminal surplus aggregation.** When `useTotalSurplusForCashOuts` is enabled, `recordCashOutFor` aggregates surplus across all terminals via `JBSurplus.currentSurplusOf()`, which calls `terminal.currentSurplusOf()` on each. This is an explicit trust boundary, not a local-accounting guarantee: projects should only enable it when every listed terminal is mutually trusted to report economically compatible surplus. Defense: `InadequateTerminalStoreBalance` still prevents extracting more than the paying terminal's actual local balance, but partial burns can reclaim more from that terminal than a purely local-surplus model would allow. When `useTotalSurplusForCashOuts` is false, only the single token being reclaimed contributes to the surplus calculation.
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
| `_sendReservedTokensToSplitsOf` | `pendingReservedTokenBalanceOf` zeroed, tokens minted to controller | Split hooks (try-catch), terminal payments | LOW -- pending balance cleared before minting prevents double-distribution. Split hook `processSplitWith` is wrapped in try-catch; a reverting hook emits `SplitHookReverted` but does not block distribution. Tokens already transferred to the hook via `safeTransfer` remain with the hook. |
| `_useAllowanceOf` | `STORE.recordUsedAllowanceOf` (allowance consumed, balance decremented) | `_takeFeeFrom` (fee payment/holding), `_transferFrom` (beneficiary) | LOW -- allowance consumed before calls |
| `migrateBalanceOf` | `STORE.recordTerminalMigration` (balance zeroed), `_takeFeeFrom` (if non-feeless destination) | `to.addToBalanceOf` | LOW -- balance zeroed before transfer, fee deducted before transfer |

### Cross-Function Reentrancy to Explore

- **Pay hook -> `cashOutTokensOf`**: After `_pay` mints tokens, a pay hook could call `cashOutTokensOf`. The cash out sees post-payment balance and post-mint supply. Not profitable after fees in tested scenarios, but verify with data hooks that modify weights.
- **Cash out hook -> `pay`**: During `_cashOutTokensOf`, after tokens are burned and beneficiary is paid, a cash out hook could call `pay()` adding to the balance. Fees haven't been taken yet at this point. Verify the fee calculation on `amountEligibleForFees` isn't affected.
- **Split hook -> `pay` on same project**: During `sendPayoutsOf`, a split hook receives funds and calls `pay()` on the same project. Payout limit is consumed, but the payment increases balance and mints tokens. The funds came from the project's own balance, so no value creation -- but verify the accounting. Note: `_pay` now reverts with `MintNotAllowed` when `payer == address(this)` to prevent same-project intra-terminal payout splits from minting tokens against existing balance. The try-catch in the split group lib catches this and restores the balance.
- **Reserved token split hook -> re-entry**: During `_sendReservedTokensToSplitsOf`, a split hook's `processSplitWith` is now wrapped in try-catch. A reverting hook emits `SplitHookReverted` and does not block distribution. Tokens transferred to the hook before the call remain with it. A hook that re-enters during `processSplitWith` sees post-mint state (pending reserved balance already zeroed).
- **Fee processing -> any re-entry**: `_processFee` uses `this.executeProcessFee` (external call via try-catch). Inside, it calls `terminal.pay()` on project #1. If project #1 has a pay hook that calls back, the fee amount is already deducted.

### Key Backstop

`JBTerminalStore_InadequateTerminalStoreBalance` revert prevents extracting more than the recorded balance from any terminal regardless of reentrancy state. This is the final defense for all value extraction paths. Auditors should verify this check cannot be bypassed by manipulating the recorded balance (e.g., via `recordAddedBalanceFor`, which has no access control -- balance is keyed by `msg.sender`, so only a terminal can inflate its own balance).

## 4. Access Control

### Permission System

- **ROOT (ID 1) grants all permissions.** Including permissions not yet defined. Future permission IDs automatically fall under ROOT.
- **ROOT + wildcard (`projectId = 0`) is allowed for self-grants only.** An account can grant its own operator ROOT on the wildcard project, giving that operator god-mode across all of the account's projects. This is powerful but legitimate — the account owner is explicitly choosing to delegate full control. However, a third-party caller who holds ROOT for a specific project **cannot** grant ROOT to others or set any permissions on the wildcard project on someone else's behalf. This prevents ROOT operators from escalating their own privileges beyond what the account owner originally granted. Auditors should verify that no indirect path allows a ROOT operator on project X to escalate to ROOT on project Y without the account owner's direct action.
- **Empty permission arrays pass `hasPermissions`.** By design (vacuous truth). Any caller that expects "the operator has at least one of these permissions" must validate the array is non-empty.
- **`OMNICHAIN_RULESET_OPERATOR` bypass.** This immutable address can `launchRulesetsFor`, `queueRulesetsOf`, and set terminals for any project without owner permission. The trust assumption is that this operator only queues rulesets that the omnichain deployer's logic permits. If this address is an EOA or an upgradeable contract, it is a single point of failure for all projects.

### Directory Terminal Addition

- **`setPrimaryTerminalOf` implicit terminal addition** now requires the `ADD_TERMINALS` permission when the terminal is not already in the project's terminal list. This closes a gap where `SET_PRIMARY_TERMINAL` alone could silently add a new terminal without the `ADD_TERMINALS` permission check. If the terminal is already in the list, no additional permission is needed.

### Migration

- **Controller migration** requires `allowSetController` in the current ruleset. During migration, `JBController.migrate()` reverts if there are pending reserved tokens. An attacker cannot front-run migration to inflate pending reserves (they'd need mint permission), but a project with organic pending reserves must distribute them first.
- **Terminal migration** requires `allowTerminalMigration` in the current ruleset. Held fees are intentionally NOT migrated -- they belong to project #1. Migration to a non-feeless terminal charges the standard 2.5% protocol fee on the full balance, settling any `_feeFreeSurplusOf` liability.
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

- If a Chainlink feed is stale beyond its threshold, `JBChainlinkV3PriceFeed` reverts. This blocks all multi-currency operations for projects using that feed: `pay`, `cashOutTokensOf`, `sendPayoutsOf`, `useAllowanceOf`. The feed also reverts with `IncompleteRound` when `answeredInRound < roundId` (answer carried from a previous round).
- L2 sequencer downtime triggers `JBChainlinkV3SequencerPriceFeed` to revert during downtime + grace period. The sequencer check uses `answer != 0` (any non-zero value = down), which is forward-compatible with future Chainlink feed versions that may use values other than `1` for the down state.
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
- **Store previews take an explicit terminal parameter.** `JBTerminalStore.previewPayFrom` and `previewCashOutFrom` take an explicit `terminal` address for balance/surplus lookups. Callers must pass a registered terminal to get correct results. The terminal-level functions (`JBMultiTerminal.previewPayFor` / `previewCashOutFrom`) handle this automatically by passing `address(this)`.
- **No state modification risk.** Preview functions cannot change balances, mint/burn tokens, or consume limits. They are safe to call from any context.
- **Preview-execution divergence.** Preview functions and their corresponding real operations share computation logic but execute in different contexts. `previewPayFor` calls `STORE.previewPayFrom` which invokes the data hook's `beforePayRecordedWith` via `staticcall`. The real `pay` path invokes the same hook but state changes between preview and execution (other payments, cash outs, ruleset transitions) can change the data hook's response. Callers should treat preview results as estimates, not guarantees — especially for projects with stateful data hooks.
- **Gas griefing via data hooks in previews.** Since `previewPayFor` and `previewCashOutFrom` invoke data hooks, a gas-expensive data hook can make preview calls prohibitively expensive. This affects frontends and indexers that rely on preview functions for quote display. Unlike the real operations (which have economic incentive to complete), preview calls have no built-in gas limit on the data hook invocation.

## 7. Integration Risks

### Non-Standard ERC-20s

- **Fee-on-transfer tokens**: Handled by `_acceptFundsFor` using balance-before/after pattern. The actual received amount is used, not the passed `amount`. However, `_transferFrom` for outbound transfers uses the nominal amount. If the token charges fees on transfer-out, the terminal's actual balance decreases more than `balanceOf` in the store records. Over time, `terminal.balance(token) < sum(store.balanceOf(projectId, terminal, token))`, breaking the balance conservation invariant for the projects that choose to use that token.
- **Reentrant transfer hooks**: `_acceptFundsFor` assumes the token transfer itself does not recursively create another accepted inflow before the outer balance delta is finalized. This is treated as an accepted integration risk rather than a core invariant. Projects should not register ERC-20s with ERC-777-style hooks, reentrant `transferFrom`, or other adversarial transfer behavior as terminal accounting contexts.
- **Rebasing tokens**: Tokens that change balances (e.g., stETH, AMPL) will cause `JBTerminalStore.balanceOf` to diverge from actual terminal holdings. Positive rebases create untracked surplus; negative rebases can cause `InadequateTerminalStoreBalance` reverts on withdrawals. This risk is limited to projects that opt into those rebasing accounting contexts.
- **Tokens with blocklists** (e.g., USDC, USDT): If a split beneficiary or cash out beneficiary is blocklisted, the transfer reverts. For split payouts, try-catch returns the amount to the project. For cash out beneficiaries, the entire `cashOutTokensOf` call reverts.
- **Low-decimal tokens** (e.g., USDC with 6 decimals): Weight and token counts use 18 decimals internally. The fixed-point conversion in `recordPaymentFrom` uses `mulDiv(amount.value, weight, weightRatio)`. With large weight values and small decimal tokens, precision loss may be significant.

### Permit2 Interactions

- **Permit2 is only used for inbound transfers.** `_acceptFundsFor` tries direct ERC-20 `transferFrom` first (if allowance is sufficient), then falls back to Permit2. The Permit2 `permit` call is wrapped in try-catch -- failure emits an event but doesn't revert the payment.
- **Outbound transfers never use Permit2.** All outbound `_transferFrom` calls pass `from: address(this)`, which takes the direct transfer path (`safeTransfer` for ERC-20s, `Address.sendValue` for native token) and returns before reaching the Permit2 fallback. The Permit2 fallback in `_transferFrom` only exists for the inbound case where `from` is the payer (`_msgSender()`).
- The `uint160` cast in `JBMultiTerminal._acceptFundsFor` limits Permit2 transfers to `type(uint160).max`. Amounts above this revert with `OverflowAlert`.

### Cross-Terminal Surplus Aggregation

- `JBSurplus.currentSurplusOf` calls `terminal.currentSurplusOf()` on each terminal. These are external view calls with no gas limit. A malicious or gas-expensive terminal can cause this aggregation to revert, blocking cash outs for any project that has `useTotalSurplusForCashOuts` enabled and uses that terminal. When `useTotalSurplusForCashOuts` is false, surplus is computed internally by the store for only the reclaimed token, avoiding cross-terminal external calls.
- The surplus calculation converts each terminal's balance to a common currency via price feeds. Rounding accumulates across terminals. With N terminals and M tokens each, there are N*M price conversions, each with up to 1 wei of rounding error.

### `addToBalanceOf` with Arbitrary Metadata

- `addToBalanceOf` accepts arbitrary `metadata` which is not validated by the terminal or store. The metadata is passed through to `afterAddToBalanceRecordedWith` callbacks. If a project's data hook or terminal extension interprets this metadata, malformed metadata could cause unexpected behavior. The core protocol ignores metadata in `addToBalanceOf` — it only affects hook processing.

### `recordAddedBalanceFor` Access Control

- `JBTerminalStore.recordAddedBalanceFor` has **no access control**. Any address can call it. The balance is keyed by `msg.sender` (the terminal address), so only a terminal can inflate its own recorded balance. This is safe as long as all terminals correctly track their actual holdings. A buggy or malicious terminal implementation could call `recordAddedBalanceFor` without actually receiving tokens, inflating the recorded balance above actual holdings.

## 8. Accepted Behaviors

### 8.1 Cross-terminal surplus is an explicit trust boundary

When a project enables `useTotalSurplusForCashOuts`, core intentionally stops treating a single terminal's local
balance as the full economic truth and instead trusts every registered terminal's reported surplus. This means a
project can get richer cash-out pricing from value held elsewhere, but it also means a bad or economically
incompatible terminal can distort the aggregate. This is accepted because cross-terminal projects explicitly opt into
shared treasury semantics; the alternative is forcing every terminal to behave as an isolated silo. Projects should
only enable this mode when all participating terminals are mutually trusted and economically compatible.

### 8.2 Held-fee forgiveness on failed fee routing is fail-open by design

Core intentionally prefers liveness over strict protocol fee collection. If project `#1` cannot accept a fee payment,
`_processFee` returns the fee amount to the originating project's balance instead of locking funds. For held fees,
`processHeldFeesOf` advances the queue before retrying the payment, so a failed held-fee processing attempt
permanently forgives that fee. This is accepted because a broken fee route should not brick project treasury flows.
The tradeoff is explicit revenue leakage for the fee beneficiary when the fee route is unavailable or incompletely
wired.

### 8.3 Surplus allowance is ruleset-scoped, not implicit-cycle-scoped

`usedSurplusAllowanceOf` is keyed by terminal, project, token, ruleset, and currency rather than by an independently
incrementing "cycle" counter. For projects whose rulesets roll forward implicitly without a new ruleset ID, allowance
usage carries forward until a new ruleset actually takes effect. This is accepted because surplus allowance is meant
to be tied to the active ruleset's economics, not to a synthetic cycle abstraction layered on top of an unchanged
ruleset. Integrators that expect per-cycle resets should queue distinct rulesets instead of relying on implicit
rollover.

### 8.4 Core deployment alone leaves fee routing fail-open until periphery wiring completes

Core contracts are intentionally deployable before project `#1` is fully operational. Until the fee project's
controller, terminals, and accounting contexts are wired, fee-bearing flows remain fail-open: fees are forgiven back
to the originating project rather than trapped. This is accepted because deployment sequencing across repos is staged,
and the protocol prioritizes keeping project flows live during rollout over enforcing fee collection before the fee
beneficiary is ready.

## 9. Invariants to Verify

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

### Held Fee Integrity
- `sum(heldFee.amount for active entries) + sum(processed fees) == total fees ever taken with shouldHoldFees=true`. Active entries are those from `_nextHeldFeeIndexOf` to end of array. Verify `_returnHeldFees`' in-place mutation of `heldFee.amount` preserves this invariant.
