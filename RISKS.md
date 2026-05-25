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
- **Data hooks are highly trusted.** A data hook can change payment weight, cash-out tax rate, `effectiveTotalSupply`, `effectiveCashOutCount`, `effectiveSurplusValue`, and hook-forwarding amounts. The protocol only bounds the final amounts.
- **Price feeds are honest enough.** Surplus, payout conversions, and allowance math depend on `JBPrices`. Stale or manipulated feeds misprice the system. `pricePerUnitOf` skips feeds that revert or return zero, then fails closed if no direct, inverse, project, or default feed can produce a nonzero price.
- **Price feeds are append-only, and projects own that trust choice.** `JBPrices.addPriceFeedFor`
  appends feeds for an exact `(projectId, pricingCurrency, unitCurrency)` pair and rejects duplicate feed addresses
  for that exact pair. Existing entries cannot be edited, removed, or reprioritized: index `0` remains the primary
  feed, and later feeds are backups if earlier feeds are unavailable. The registering party, a project owner or the
  `JBPrices` owner for project `0` defaults, is responsible for selecting both the primary feed and any
  fallbacks. `DeployPeriphery.s.sol` and the canonical `deploy-all-v6` deploy both require the expected default
  feed to remain the primary feed, so a mismatched pre-existing default reverts loudly instead of being accepted as
  a backup. Projects that need governed oracle replacement should register a wrapper `IJBPriceFeed`; the wrapper's
  governance becomes the flexibility surface while `JBPrices` keeps append-only history.
- **Accepted ERC-20s behave like standard tokens.** Inbound fee-on-transfer handling is safer than outbound handling. Rebasing or nonstandard outbound behavior can still break accounting assumptions.
- **Accepted tokens are not actively adversarial.** Core does not harden against tokens that reenter or distort balance observations during transfer.
- **The trusted forwarder is not compromised.** If it is, `_msgSender()` can be spoofed across permission-gated contracts.
- **Project `#1` fee routing stays live enough.** If fee processing into project `#1` fails, core favors liveness and returns value to the originating project instead of trapping it. That can forgive fees.
- **`OMNICHAIN_RULESET_OPERATOR` is trusted, and binding the correct address is the deployer's responsibility.**
  The address is immutable on `JBController` and lets its holder bypass owner permission on `launchRulesetsFor` and
  `queueRulesetsOf` for every project. `DeployPeriphery.s.sol` hardcodes the constant and only nonzero-checks it
  before constructing the controller — there is no on-chain check inside the periphery script that the address
  matches the canonical omnichain deployer on the current chain. We accept this: the deploying party is
  responsible for setting the constant to the correct, deployed `JBOmnichainDeployer` on every chain they bring
  the protocol to, and a wrong constant is a prerequisite trust failure (the same actor controls the deploy keys).
  Post-deploy verification in `deploy-all-v6/script/Verify.s.sol` asserts
  `controller.OMNICHAIN_RULESET_OPERATOR() == address(omnichainDeployer)` at two checkpoints during the canonical
  ecosystem rollout; integrators relying on the standalone periphery deploy should perform an equivalent
  post-deploy assertion before treating the controller as canonical.

## 2. Economic Risks

### Bonding Curve

- **Zero cash-out guard.** `cashOutFrom` returns `0` when `cashOutCount == 0`. Verify no path bypasses that guard.
- **Pending reserved tokens lower cash-out value.** `totalTokenSupplyWithReservedTokensOf()` includes `pendingReservedTokenBalanceOf`, which can reduce per-token reclaim value until reserves are distributed.
- **Reserved-token project splits cannot point back to the source project.** A reserved-token split can route tokens to
  another project that accepts the token, but the source project is rejected so reserves cannot be recycled through its
  own terminal and minted again as a payment.
- **Voluntary burns are not hidden supply.** `burnTokensOf` destroys the holder's tokens or credits and lowers the live supply used by cash-out math. There is no separate hidden balance that can be removed from the denominator and later reclaimed. A burn can only benefit remaining holders by deleting the burner's own claim; if one holder already owns the entire outstanding supply, cashing out all tokens already returns the full surplus.
- **External token supply only affects that project.** If a project uses `setTokenFor(...)`, the external token's `totalSupply()` feeds that project's cash-out math.
- **`mulDiv` rounding exists.** Split cash outs can differ slightly from a combined cash out because of floor rounding.
- **`minCashOutCountFor` uses binary search.** Large supplies increase loop count. Gas should stay bounded.

### Fee Arithmetic

- **Forward and backward fee math round differently.** `feeAmountFrom` and `feeAmountResultingIn` are close but not identical under rounding. Their interaction matters in held-fee paths.
- **Dust amounts below the fee rounding threshold pay zero fee.** For the 2.5% fee (`FEE=25, MAX_FEE=1000`), amounts below 40 wei produce a zero fee via floor division. This is intentional: rounding dust fees up to 1 wei causes a split-payout accounting bug where the fee consumes the entire payout amount, `netPayoutAmount` becomes 0, `JBPayoutSplitGroupLib` excludes the split from `amountEligibleForFees`, and the gross amount is orphaned in the terminal (credited to neither the project nor the fee project). The gas cost of exploiting dust fee bypass far exceeds the bypassed fee value.
- **Split fee aggregation is capped to per-split withholding.** Split payouts deduct the standard fee from each
  non-feeless split independently. `JBPayoutSplitGroupLib` rounds each split's fee-eligible basis down to the
  reduced standard-fee denominator before adding it to the aggregate fee basis, so `_sendPayoutsOf` cannot process or
  hold more fees than the individual splits actually withheld. The tradeoff is ordinary floor-rounding
  undercollection below one smallest token unit per fee-bearing split; highly fragmented dust payouts can avoid tiny
  fees, but they cannot create a pooled terminal shortfall through aggregate fee overcollection.
- **Held fee entries are mutated in place.** If the accounting is off by even one unit in the wrong direction, `_returnHeldFees` can corrupt the entry.
- **Fee-route failure is fail-open.** If the fee project terminal or fee route reverts, the terminal emits
  `FeeReverted` and credits the failed fee amount back to the originating project instead of reverting the user's
  payout, cash out, allowance use, held-fee processing, or terminal migration. This favors project liveness and
  migration ability over guaranteed fee collection. During migration, a failed migration fee remains as refunded
  source-terminal balance while the post-fee amount migrates; operators should monitor `FeeReverted` and restore fee
  routing so refunded residuals can be swept cleanly.
- **Fee referral attribution is accounting metadata, not fee custody.** `cashOutTokensOf`, `sendPayoutsOf`, and
  `useAllowanceOf` can carry a packed `(chainId << 48) | projectId` referrer. A bare project ID is resolved to the
  current chain. Held fees store that referral pair until processing, and `JBTerminalStore` records fee volume per
  terminal/referrer. Bad encoding misattributes volume but does not redirect the fee payment itself.

### Weight Decay

- **Stale weight cache can block a project.** Short-duration rulesets with nonzero `weightCutPercent` can hit `WeightCacheRequired` after 20,000 elapsed cycles (`_WEIGHT_CUT_MULTIPLE_CACHE_LOOKUP_THRESHOLD`). Projects approaching this limit must call `updateRulesetWeightCache()` to pre-cache decayed weights.
- **Weight-cache correctness matters more than overflow.** Overflow is already bounded at queue time. The real risk is stale or wrongly-updated cache state.

### Ruleset Duration

- **Durations greater than `block.timestamp` are not a supported configuration.** `JBRulesets._simulateCycledRulesetBasedOn` clamps `mustStartAtOrAfter` to `1` when `baseRuleset.duration >= block.timestamp`, which is the branch reached only for durations on the order of decades or longer (block.timestamp is Unix seconds). Project owners are expected to choose durations on human-meaningful scales (hours to years), so this edge case never triggers in practice.

### Surplus Manipulation

- **Cross-terminal surplus is a trust boundary.** Cash outs always aggregate surplus across all registered terminals, so one terminal can price a cash out using value reported by other terminals.
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
- **Terminal migration also depends on ruleset permission.** Held fees are not migrated, and migration into a
  non-feeless terminal attempts the normal protocol fee. Fee-route failure does not block migration; the failed fee is
  refunded to the source terminal and reported through `FeeReverted`.
- **Migrate balances before removing a terminal.** The store records migration for the calling terminal address and
  clears that terminal's ledger balance. If a terminal is removed while it still has a ledger balance, later calls from
  that terminal are no longer coupled to the directory's canonical terminal set. Operators should migrate through
  `JBMultiTerminal.migrateBalanceOf` before removal and confirm token custody and `JBTerminalStore.balanceOf`
  afterwards.
- **Directory updates are high-impact.** `setTerminalsOf` and `setControllerOf` can redirect a project's fund and authority flow.

### Ruleset Queuing

- Only the current controller can call `RULESETS.queueFor()`.
- The controller lets the owner, an allowed operator, or `OMNICHAIN_RULESET_OPERATOR` queue rulesets.
- For `duration = 0` projects, a queued ruleset can take effect immediately.
- Fund access limit groups must be unique per `(terminal, token)` pair, and each group's payout-limit and
  surplus-allowance currencies must be strictly increasing. This keeps duplicate currencies from being split across
  groups and making surplus views depend on malformed configuration.

### Project Launch Provenance

- **`launchProjectFor` is permissionless on behalf of an owner.** A third party can mint a project NFT to any address
  and choose that project's initial URI, rulesets, terminals, splits, and fund access limits. This does not grant the
  third party ongoing owner permissions, but it means project NFT ownership alone is not proof that the owner
  intentionally launched the initial configuration.
- **Project IDs are first-come-first-served.** Reading `JBProjects.count() + 1` is only a prediction until the launch
  transaction lands. Operators that need a specific ID should reserve it explicitly with `createFor(...)` and then use
  `launchRulesetsFor(...)`, or verify the returned `projectId` before wiring downstream contracts.

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
- Price feeds are append-only in `JBPrices`; the primary feed cannot be changed, but backups can be appended.

### Approval Hook Griefing

- A reverting approval hook is caught and treated as failed approval.
- A gas-burning approval hook can still DoS `currentOf()` by exhausting gas.
- Repeated approval-hook rejection at a ruleset boundary can create complex fallback behavior that needs testing.

### Locked Split Scope

- Locked splits are enforced when rewriting the same `(projectId, rulesetId, groupId)` split table. While a split is
  locked, the replacement table must include an exact matching split with the same percent, beneficiary, project ID,
  hook, and `preferAddToBalance`, and a `lockedUntil` that is at least as long. This prevents reducing or removing the
  locked split inside that table. Duplicate locked splits must be preserved with the same multiplicity; one matching
  replacement split cannot satisfy several identical locked entries.
- Locks do not automatically carry across different `rulesetId`s. Queueing a successor ruleset can change future split
  behavior before the old split's `lockedUntil`; applications that need cross-ruleset commitments must preserve those
  splits at the governance/configuration layer.

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
- **Payout failure reasons are copied in full.** `PayoutReverted` and `PayoutTransferReverted` preserve the callee's
  revert data for operator visibility. Because Solidity's `catch (bytes memory reason)` copies the full returndata
  before the catch body runs, a malicious recipient, token, or downstream terminal can return very large revert data
  and make the fail-open recovery path run out of gas before the refund event and balance restoration complete. This
  is an accepted edge-case DoS risk: split hooks already use a no-reason catch inside their partial-pull path, and
  replacing the remaining reason-preserving catches with low-level bounded-copy calls would spend scarce terminal
  bytecode for a niche griefing case. Operators should treat repeated payout failures to the same recipient or
  terminal as a configuration issue and rewire the split or owner-payout route.
- **Split-hook payouts allow partial consumption.** `JBPayoutSplitGroupLib.invokeSplitHookWithPartial` grants the hook an ERC-20 allowance (or pushes ETH via `msg.value`), calls `processSplitWith` inside a try/catch, then revokes any unconsumed allowance. The hook keeps whatever it actually pulled; the unsent portion routes back to the project's balance via `recordAddedBalanceFor`, scaled to include the proportional fee allocation so the held fee is effectively charged only on what the hook consumed. Three outcomes: (1) full consumption — fee held on the full gross intent; (2) full failure (revert or zero pull) — entire gross refunded, no fee held; (3) partial pull — hook keeps `X`, project gets `amount × (net − X) / net` back, fee held on the gross-equivalent of `X`. Hooks observe `msg.sender == terminal` (the library is delegatecalled from `JBMultiTerminal`).
- Reserved-token split hook reverts: for ERC-20 tokens, the controller uses an allowance model — it approves the hook, calls `processSplitWith`, and if the hook reverts or does not consume the full allowance the controller revokes the approval and burns the remainder. Tokens are not stranded at the hook. **The burn is deliberate, not a fallback gap.** A split routed through a hook treats `split.beneficiary` as a hint passed to the hook, not as a sender-side recipient identity the controller can re-target on failure. Routing the unconsumed allocation to `beneficiary` on hook revert would grow `totalSupply` against a recipient the hook itself never accepted, diluting existing holders toward an unspecified destination. Burning preserves the holder-protection invariant — reserved tokens that fail to land at their declared destination do not enter circulation. This is the opposite design choice from the project-pay-fail path further down the same function (which transfers to `beneficiary` on revert), and the asymmetry is principled: in the project-pay case, `beneficiary` IS the natural sender-side recipient (the address that would have received minted tokens on the recipient project), so the fallback transfer is semantically clean. `SplitHookReverted` is emitted on every failure so operators monitoring events detect and rewire — the failure is loud. Hooks that revert under transient conditions (LP pool not yet initialized, pause states, internal liquidity) should be made fault-tolerant on the hook side rather than relying on a controller-side recovery path. For credit-only projects (no ERC-20 deployed), credits are still transferred directly before the hook call, so a revert can strand credits at the hook — credits have no allowance mechanism, so symmetric recovery is not available; the hook is responsible for accepting the credits it was sent.

### Terminal Migration Resets Used Payout Limits

`usedPayoutLimitOf` and `usedSurplusAllowanceOf` are keyed by terminal address. This is intentional terminal-scoped accounting, not a global project-wide cap. When a project migrates to a new terminal via `migrateBalanceOf`, the used counters on the destination terminal start from that terminal's own usage. If a project owner pre-configured payout limits or surplus allowances for both the old and new terminal addresses in the same ruleset's `fundAccessLimitGroups`, migrating mid-cycle lets them use each terminal's configured access independently. This requires the project owner to be the actor (or collude), since only the owner can configure both fund access limit groups and trigger migration. The 2.5% migration fee on non-feeless terminals provides friction.

## 8. Accepted Behaviors

### 8.1 Cross-terminal surplus is opt-in shared trust

Cash outs always aggregate surplus across all registered terminals (shared treasury semantics). This improves pricing, but it also means each listed terminal is part of the trust boundary. The `scopeCashOutsToLocalBalances` metadata flag controls only cross-chain aggregation — local multi-terminal aggregation is always on.

### 8.2 Failed fee routing is intentionally fail-open

If project `#1` cannot accept a fee payment, core prefers liveness over strict fee collection. For held fees, a failed processing attempt can forgive the fee permanently.

### 8.3 Surplus allowance is keyed by ruleset, not by an abstract cycle

`usedSurplusAllowanceOf` is keyed by `ruleset.id`. If a ruleset auto-rolls without a new ID, allowance usage carries forward.

### 8.4 Fee routing starts fail-open until the wider deployment is wired

Core can be deployed before project `#1` is fully ready. During that period, fee-bearing flows may forgive fees instead of trapping funds.

### 8.5 Held fees can be returned even after the 28-day unlock has elapsed

`_returnHeldFees` does not check `unlockTimestamp`. A project can erase a held fee that has matured past the 28-day holding window by calling `addToBalanceOf` (or any path that triggers a return) before someone calls `processHeldFeesOf`. This is intentional: the held fee is a contingent claim against funds that left the project, and the project can always rescind that claim by putting the funds back. Holding fee replenishment costs the project the full amount it withdrew, so the project must keep the funds in the protocol to avoid the fee — which is the same trade-off held fees were designed to express. The only difference between pre-maturity and post-maturity return is that anyone can call `processHeldFeesOf` after 28 days to force collection, so projects that want to keep delaying the fee must repeatedly front-run that processing.

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
- **Referral integrity:** fee volume credited by `recordFeeReferralCreditOf` should match successful fee payments and preserved held-fee referral context.
