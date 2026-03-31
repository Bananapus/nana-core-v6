# User Journeys

## Who This Repo Serves

- founders launching and evolving Juicebox projects
- supporters paying projects in the asset a terminal accepts
- token holders cashing out against project surplus
- operators managing permissions, splits, fund access limits, and rulesets
- integrators wiring hooks, terminals, price feeds, and migrations into the canonical protocol surface

## Journey 1: Launch A Project With The Right Initial Shape

**Starting state:** you know who should own the project, which terminals it should use, and what the first ruleset should allow.

**Success:** the project NFT exists, the initial ruleset is active, accepted terminals are installed, and downstream hooks or splits can begin working immediately.

**Flow**
1. Call `JBController.launchProjectFor(...)` with the owner, URI, ruleset config, terminal configs, and any split or hook metadata.
2. `JBProjects` mints the project NFT, `JBDirectory` records controller and terminal routing, and `JBRulesets` stores the first ruleset.
3. If the project wants ERC-20 tokens, reserved-rate behavior, or hook-driven behavior, that configuration is committed at launch instead of being inferred later.
4. The project can now accept payments and queue future rulesets without changing project identity.

**Failure cases that matter:** mismatched accounting contexts, wrong terminals for the target asset, invalid hook metadata, and launching with permissions or ownership assumptions that cannot be repaired cleanly later.

## Journey 2: Accept A Payment And Issue The Right Token Exposure

**Starting state:** the project has an active ruleset and a terminal that accepts the payer's asset.

**Success:** treasury balances increase, hooks run in the right order, and the beneficiary receives credits or ERC-20 tokens consistent with the ruleset.

**Flow**
1. A payer calls `pay(...)` on `JBMultiTerminal`.
2. The terminal validates the accounting context, records funds, and asks `JBTerminalStore` to derive issuance from the active ruleset.
3. `JBController` and `JBTokens` decide whether the beneficiary gets project token credits, ERC-20s, or no issuance because weight is zero.
4. Any configured pay hooks or data hooks run around the accounting path.

**Edge conditions that change user experience:** paused payments, custom hook side effects, fee-on-transfer tokens, unsupported price feeds, zero-weight rulesets, and permit-based flows.

## Journey 3: Distribute Treasury Funds Through Governed Paths

**Starting state:** the project has terminal balances and the owner wants payouts or allowance-based withdrawals.

**Success:** treasury value leaves only through configured limits, recipients, and fee logic instead of arbitrary admin withdrawals.

**Flow**
1. Authorized actors call payout or allowance surfaces on the terminal.
2. `JBFundAccessLimits` bounds how much may leave for the current ruleset cycle.
3. `JBSplits` fans value out to beneficiaries, projects, hooks, or fee recipients as configured.
4. `JBTerminalStore` updates balances and fee accounting so later previews and cash outs remain consistent.

**Failure cases that matter:** stale split expectations, exceeding access limits, downstream hook failures, and assuming allowance withdrawals behave like payouts when fee treatment differs.

## Journey 4: Let Holders Cash Out Against Surplus

**Starting state:** a holder owns project token exposure and the project has reclaimable surplus in some terminal.

**Success:** the holder burns the intended amount of token exposure and receives the correct reclaim amount under the current ruleset.

**Flow**
1. The holder calls `cashOutTokensOf(...)` on the relevant terminal.
2. `JBTerminalStore` calculates reclaim value using surplus, outstanding token supply, cash-out tax rate, and any pending reserved token effects.
3. Cash-out hooks can modify behavior or side effects, but the core accounting remains anchored in the terminal store.
4. Tokens burn and value exits the treasury through the terminal that actually held the asset.

**Edge conditions that matter:** fee-free addresses, custom cash-out hooks, preview-versus-execution drift under volatile routing, and multi-terminal surplus that users may misread as single-pool liquidity.

## Journey 5: Queue New Rulesets Without Migrating The Project

**Starting state:** the project is live and future economics need to change.

**Success:** the next ruleset activates on schedule while the project keeps the same identity, treasury, and downstream integrations.

**Flow**
1. The owner or an operator with the right permission queues one or more new rulesets through `JBController`.
2. `JBRulesets` stores the proposed future configuration and any approval hook requirements.
3. When the active duration elapses, the next approved ruleset becomes live and future pays, payouts, and cash outs follow the new terms.
4. Existing balances and token history remain intact because only future behavior changed.

**Failure cases that matter:** forgetting approval hooks, queueing incompatible metadata for installed hooks, and assuming a ruleset change can retroactively repair prior accounting.

## Journey 6: Hand Off Authority Without Handing Out Root Access

**Starting state:** the project owner wants operators, delegates, or automation to manage only specific surfaces.

**Success:** permissions are narrow, auditable, and scoped to the actions the operator actually needs.

**Flow**
1. The owner configures operator permissions in `JBPermissions`.
2. Downstream calls check those packed permission bits instead of assuming project ownership.
3. Integrations such as ownable wrappers, hook deployers, and router registries can now respect project-scoped delegation without custom ACL logic.

## Hand-Offs

- Use [nana-permission-ids-v6](../nana-permission-ids-v6/USER_JOURNEYS.md) for the shared permission vocabulary that downstream repos import.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md), [nana-router-terminal-v6](../nana-router-terminal-v6/USER_JOURNEYS.md), and [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md) for opinionated layers on top of the core terminal and ruleset surfaces.
