# Juicebox Core Risk Register

This file covers the main accounting, permission, and liveness risks in the core protocol contracts that the rest of V6 builds on.

## How To Use This File

- Read `Priority risks` first. Those are the failures with the widest blast radius.
- Use the later sections when you need detail on accounting, reentrancy, access control, previews, or integrations.
- Treat `Invariants to verify` as core properties, not optional test ideas.

## Priority Risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Core accounting corruption | Terminal, store, and controller accounting define balances, surplus, fees, and supply for the whole ecosystem. | Invariant tests, preview/settlement alignment, and conservative integrations. |
| P0 | Permission or migration mistakes | Controllers, terminals, and operators can redirect authority or value if checks or sequencing are wrong. | Permission review, migration tests, and scrutiny of wildcard or root-like authority. |
| P1 | Preview or settlement drift | Hooks and routers often depend on previews being close to execution. | Preview analysis, regression tests, and downstream composition review. |

## 1. Trust Assumptions

- **Hooks are not exploiting reentrancy.** Core does not use `ReentrancyGuard`. Safety depends on call ordering and the `JBTerminalStore_InadequateTerminalStoreBalance` backstop.
- **Data hooks are highly trusted.** A data hook can change payment weight, cash-out tax rate, `effectiveTotalSupply`, `effectiveCashOutCount`, and hook-forwarding amounts. The protocol only bounds the final amounts.
- **Price feeds are honest enough.** Surplus, payout conversions, and allowance math depend on `JBPrices`. Stale or manipulated feeds misprice the system.
- **Accepted ERC-20s behave like standard tokens.** Inbound fee-on-transfer handling is safer than outbound handling. Rebasing or nonstandard outbound behavior can still break accounting assumptions.
- **Accepted tokens are not actively adversarial.** Core does not harden against tokens that reenter or distort balance observations during transfer.
- **The trusted forwarder is not compromised.** If it is, `_msgSender()` can be spoofed across permission-gated contracts.
- **Project `#1` fee routing stays live enough.** If fee processing into project `#1` fails, core favors liveness and returns value to the originating project instead of trapping it. That can forgive fees.
- **`OMNICHAIN_RULESET_OPERATOR` is trusted.** This address can bypass some owner checks for ruleset flows and is a broad trust point.

## 2. Economic Risks

### Bonding Curve

- **Zero cash-out guard.** `cashOutFrom` returns `0` when `cashOutCount == 0`. Verify no path bypasses that guard.
- **Pending reserved tokens lower cash-out value.** `totalTokenSupplyWithReservedTokensOf()` includes `pendingReservedTokenBalanceOf`, which can reduce per-token reclaim value until reserves are distributed.
- **External token supply only affects that project.** If a project uses `setTokenFor(...)`, the external token's `totalSupply()` feeds that project's cash-out math.
- **`mulDiv` rounding exists.** Split cash outs can differ slightly from a combined cash out because of floor rounding.
- **`minCashOutCountFor` uses binary search.** Large supplies increase loop count. Gas should stay bounded.

### Fee Arithmetic

- **Forward and backward fee math round differently.** `feeAmountFrom` and `feeAmountResultingIn` are close but not identical under rounding. Their interaction matters in held-fee paths.
- **Dust amounts below the fee rounding threshold pay zero fee.** For the 2.5% fee (`FEE=25, MAX_FEE=1000`), amounts below 40 wei produce a zero fee via floor division. This is intentional: rounding dust fees up to 1 wei causes a split-payout accounting bug where the fee consumes the entire payout amount, `netPayoutAmount` becomes 0, `JBPayoutSplitGroupLib` excludes the split from `amountEligibleForFees`, and the gross amount is orphaned in the terminal (credited to neither the project nor the fee project). The gas cost of exploiting dust fee bypass far exceeds the bypassed fee value.
- **Held fee entries are mutated in place.** If the accounting is off by even one unit in the wrong direction, `_returnHeldFees` can corrupt the entry.

### Weight Decay

- **Stale weight cache can block a project.** Short-duration rulesets with nonzero `weightCutPercent` can hit `WeightCacheRequired` after 20,000 elapsed cycles (`_WEIGHT_CUT_MULTIPLE_CACHE_LOOKUP_THRESHOLD`). Projects approaching this limit must call `updateRulesetWeightCache()` to pre-cache decayed weights.
- **Weight-cache correctness matters more than overflow.** Overflow is already bounded at queue time. The real risk is stale or wrongly-updated cache state.

### Surplus Manipulation

- **Cross-terminal surplus is a trust boundary.** When `useTotalSurplusForCashOuts` is enabled, one terminal can price a cash out using value reported by other terminals.
- **Cross-terminal price-feed mismatch changes reclaim values.** If feeds differ or go stale across terminals, aggregated surplus can be wrong.

## 3. Reentrancy Surface

Core does not use `ReentrancyGuard`. It relies on state ordering plus `InadequateTerminalStoreBalance` as the last balance-extraction backstop.

### External Call Map

| Function | State Changes Before External Call | External Calls | Risk |
|----------|-----------------------------------|----------------|------|
| `_pay` | `STORE.recordPaymentFrom`, `controller.mintTokensOf` | Pay hooks | LOW |
| `_cashOutTokensOf` | `STORE.recordCashOutFor`, `controller.burnTokensOf`, beneficiary transfer | Cash-out hooks, then fee processing | MEDIUM |
| `executePayout` | `STORE.recordPayoutFor` already consumed payout limit | Split hooks, terminal pay/addToBalance | MEDIUM |
| `processHeldFeesOf` | Held-fee entry deleted and index advanced | `_processFee` -> `this.executeProcessFee` -> `terminal.pay` | LOW |
| `_sendReservedTokensToSplitsOf` | Pending reserved balance zeroed, tokens minted. ERC-20 tokens approved to hook via `forceApprove`; unconsumed allowance revoked and tokens burned after hook call. Credits still transferred directly. | Split hooks, terminal payments | LOW |
| `_useAllowanceOf` | `STORE.recordUsedAllowanceOf` | Fee processing, beneficiary transfer | LOW |
| `migrateBalanceOf` | `STORE.recordTerminalMigration` | `to.addToBalanceOf` | LOW |

### Cross-Function Reentrancy To Explore

- **Pay hook -> `cashOutTokensOf`.** The hook sees post-payment balance and post-mint supply.
- **Cash-out hook -> `pay`.** The hook runs after burn and payout but before fee processing completes.
- **Split hook -> `pay` on the same project.** Core now reverts same-project intra-terminal self-pay minting, but the path is still worth checking.
- **Reserved-token split hook reentry.** Hooks see post-mint state after pending reserved balance is zeroed. For ERC-20 tokens, the hook receives an allowance (not a direct transfer) and can pull tokens during `processSplitWith`; any unconsumed allowance is revoked afterward. For credits, tokens are transferred directly before the hook call.
- **Fee processing reentry.** `_processFee` makes an external fee payment into project `#1`; hook behavior there still matters.

### Key Backstop

`JBTerminalStore_InadequateTerminalStoreBalance` should stop any path from pulling more than the terminal's recorded balance. Reviewers should verify no caller can inflate that recorded balance without the terminal actually holding the funds.

## 4. Access Control

### Permission System

- **ROOT grants all permissions.** That includes permissions added in the future.
- **ROOT plus wildcard is allowed only for self-grants.** An account can delegate broad power over its own projects, but third parties should not be able to escalate into it.
- **Empty permission arrays pass `hasPermissions`.** Callers must check for non-empty arrays if that matters to their logic.
- **`OMNICHAIN_RULESET_OPERATOR` is a broad bypass.** It can queue or launch rulesets for any project.

### Directory Terminal Addition

- **`setPrimaryTerminalOf` can also add a terminal.** When the terminal is not already installed, the call must satisfy `ADD_TERMINALS` as well as the primary-terminal permission.

### Migration

- **Controller migration depends on ruleset permission.** `allowSetController` must be active, and migration fails if reserved tokens are still pending.
- **Terminal migration also depends on ruleset permission.** Held fees are not migrated, and migration into a non-feeless terminal charges the normal protocol fee.
- **Directory updates are high-impact.** `setTerminalsOf` and `setControllerOf` can redirect a project's fund and authority flow.

### Ruleset Queuing

- Only the current controller can call `RULESETS.queueFor()`.
- The controller lets the owner, an allowed operator, or `OMNICHAIN_RULESET_OPERATOR` queue rulesets.
- For `duration = 0` projects, a queued ruleset can take effect immediately.

## 5. DoS Vectors

### Unbounded Arrays

| Array | Growth Mechanism | Cleanup | Risk |
|-------|-----------------|---------|------|
| `_heldFeesOf[projectId][token]` | Each held-fee payout appends | Index pointer skips processed entries | MODERATE |
| `splits[]` | Set by project owner per ruleset | Replaced wholesale | MODERATE |
| `_accountingContextsOf[projectId]` | `addAccountingContextsFor` append-only | Never shrinks | LOW |
| Payout limits / surplus allowances | Set per ruleset | Replaced per ruleset | LOW |
| `_terminalsOf[projectId]` | `setTerminalsOf` replace-only | Replaced | LOW |

### Price Feed Reverts

- Stale or incomplete Chainlink data can block multi-currency operations.
- L2 sequencer downtime can also block feeds behind a sequencer-check wrapper.
- Single-currency projects are unaffected when they do not need conversion.
- Price feeds are immutable once set in `JBPrices`.

### Approval Hook Griefing

- A reverting approval hook is caught and treated as failed approval.
- A gas-burning approval hook can still DoS `currentOf()` by exhausting gas.
- Repeated approval-hook rejection at a ruleset boundary can create complex fallback behavior that needs testing.

### Duplicate Locked Splits Collapse

- When `setSplitGroupsOf` is called, locked splits from the previous configuration are carried forward. If the new configuration includes a split with the same `(beneficiary, projectId, hook)` tuple as an existing locked split, the locked split is replaced — the new entry takes precedence. This is by design (locked splits protect beneficiaries from removal, not from updates by the project owner within the same tuple). However, it means a project owner can effectively reduce a locked split's percentage by submitting a duplicate with a lower percent before the lock expires.

### Other DoS Surfaces

- Failed split payouts consume payout limit even when value is returned to project balance.
- `addAccountingContextsFor` is append-only, so projects that add many contexts over time can make some loops more expensive.

## 6. Preview Functions

`JBMultiTerminal.previewPayFor`, `JBMultiTerminal.previewCashOutFrom`, and `JBController.previewMintOf` are read-only simulations of state-changing operations.

- **Previews call data hooks.** A reverting or gas-heavy hook can break previews.
- **Store previews require the correct terminal input.** Passing the wrong terminal gives the wrong answer.
- **Previews do not mutate state.** They cannot consume limits, move funds, or mint and burn tokens.
- **Preview and execution can still drift.** Shared logic helps, but state can change between calls and hooks can be stateful.
- **Some read-only surplus views are not hook-aware.** `currentReclaimableSurplusOf` and `currentTotalReclaimableSurplusOf` intentionally skip data hooks.

## 7. Integration Risks

### Non-Standard ERC-20s

- **Fee-on-transfer tokens.** Inbound handling is safer than outbound handling. Outbound transfer fees can leave store accounting higher than real holdings.
- **ERC-777 reentrancy in `_acceptFundsFor`.** Tokens with transfer hooks (ERC-777, ERC-1363) can reenter during `_acceptFundsFor`. The balance-delta pattern correctly captures the received amount, but a reentrant call during the transfer could interact with mid-update state. Projects accepting ERC-777 tokens should be aware of this surface.
- **Reentrant transfer hooks.** Core treats them as an accepted integration risk, not a hardened invariant.
- **Rebasing tokens.** Positive or negative rebases can desync terminal balances from store balances.
- **Blocklist tokens.** Beneficiary-specific transfer failures can revert user cash outs or return payout value to the project.
- **Low-decimal tokens.** Fixed-point conversions can lose meaningful precision. For tokens with very few decimals (e.g., 2), fee calculations via `feeAmountFrom` can round to zero, allowing fee-free transactions below the rounding threshold.

### Permit2 Interactions

- Permit2 is only used for inbound transfers.
- Outbound transfers never rely on Permit2.
- The `uint160` cast in `_acceptFundsFor` caps Permit2 transfer size.

### Cross-Terminal Surplus Aggregation

- `JBSurplus.currentSurplusOf` makes external view calls into each terminal with no gas cap.
- Aggregated surplus also compounds price-conversion rounding across terminals.

### `addToBalanceOf` Metadata

- `addToBalanceOf` accepts arbitrary metadata.
- Core ignores that metadata directly, but hooks may interpret it.

### `recordAddedBalanceFor` Access Control

- `JBTerminalStore.recordAddedBalanceFor` has no explicit access control.
- The balance key includes `msg.sender`, so only a terminal can inflate its own recorded balance.
- A buggy or malicious terminal can still lie about funds it received.

### Split And Owner-Payout Failure Semantics

- Failed split payouts still consume payout limit.
- Failed owner payouts also still consume payout limit.
- Reserved-token split hook reverts: for ERC-20 tokens, the controller uses an allowance model — it approves the hook, calls `processSplitWith`, and if the hook reverts or does not consume the full allowance the controller revokes the approval and burns the remainder. Tokens are not stranded at the hook. For credit-only projects (no ERC-20 deployed), credits are still transferred directly before the hook call, so a revert can strand credits at the hook.

### Terminal Migration Resets Used Payout Limits

`usedPayoutLimitOf` and `usedSurplusAllowanceOf` are keyed by terminal address. When a project migrates to a new terminal via `migrateBalanceOf`, the used counters on the new terminal start at zero. If a project owner pre-configured payout limits for both the old and new terminal addresses in the same ruleset's `fundAccessLimitGroups`, they could exceed per-cycle payout limits by migrating mid-cycle. This requires the project owner to be the attacker (or collude), since only the owner can configure both fund access limit groups and trigger migration. The 2.5% migration fee on non-feeless terminals provides friction.

## 8. Accepted Behaviors

### 8.1 Cross-terminal surplus is opt-in shared trust

When a project enables `useTotalSurplusForCashOuts`, it is choosing shared treasury semantics across terminals. That can improve pricing, but it also means each listed terminal is part of the trust boundary.

### 8.2 Failed fee routing is intentionally fail-open

If project `#1` cannot accept a fee payment, core prefers liveness over strict fee collection. For held fees, a failed processing attempt can forgive the fee permanently.

### 8.3 Surplus allowance is keyed by ruleset, not by an abstract cycle

`usedSurplusAllowanceOf` is keyed by `ruleset.id`. If a ruleset auto-rolls without a new ID, allowance usage carries forward.

### 8.4 Fee routing starts fail-open until the wider deployment is wired

Core can be deployed before project `#1` is fully ready. During that period, fee-bearing flows may forgive fees instead of trapping funds.

## 9. Invariants To Verify

- **Balance conservation:** `terminal.balance(token) >= sum(store.balanceOf(projectId, terminal, token))` for projects sharing a terminal.
- **Fund conservation:** project inflows should cover project outflows plus fees, with rounding favoring the protocol.
- **Fee monotonicity:** project `#1` should only gain protocol fees through normal mechanics.
- **Token supply consistency:** protocol credit supply, ERC-20 supply, and pending reserved supply should reconcile.
- **Payout-limit enforcement:** `usedPayoutLimitOf(...)` must stay `<= payoutLimitOf(...)`.
- **Surplus-allowance enforcement:** `usedSurplusAllowanceOf(...)` must stay `<= surplusAllowanceOf(...)`.
- **Cash-out bound:** reclaim plus hook-forwarded amounts must not exceed recorded balance.
- **Ruleset existence:** after launch, `RULESETS.currentOf(projectId)` should not accidentally go empty.
- **No flash-loan profit:** `pay()` followed by `cashOutTokensOf()` in one transaction should not be profitable after fees.
- **Held-fee integrity:** active held-fee entries plus processed fees should equal all fees ever taken under held-fee mode.
