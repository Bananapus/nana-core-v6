# User Journeys

## Repo Purpose

This repo is the main runtime surface for Juicebox V6. It owns project identity, rulesets, terminal execution, treasury accounting, permissions, price feeds, and migration paths. Most other V6 repos build on this behavior instead of replacing it.

## Primary Actors

- founders launching and updating Juicebox projects
- supporters paying projects in assets that a terminal accepts
- token holders cashing out against project surplus
- operators managing permissions, splits, fund access limits, and rulesets
- integrators wiring hooks, terminals, price feeds, and migrations into core

## Key Surfaces

- `JBController`: project launch, ruleset queueing, token setup, splits, and controller migration
- `JBMultiTerminal`: pay, payout, allowance, preview, and cash-out entrypoints
- `JBTerminalStore`: balance, surplus, fee, and reclaim accounting
- `JBDirectory`: controller and terminal routing
- `JBPermissions`: packed operator-permission registry
- `JBProjects`, `JBRulesets`, `JBPrices`, `JBFundAccessLimits`, `JBSplits`, `JBTokens`: core state and helper surfaces

## Journey 1: Launch A Project With The Right Initial Setup

**Actor:** founder, deployer, or protocol integrator.

**Intent:** create a project with the right owner, terminal, ruleset, and hook assumptions from the start.

**Preconditions**
- the team knows who should own the project, which terminals it should use, and what the first ruleset should allow

**Main Flow**
1. Call `JBController.launchProjectFor(...)` with the owner, URI, ruleset config, terminal configs, and any split or hook metadata.
2. `JBProjects` mints the project NFT, `JBDirectory` records controller and terminal routing, and `JBRulesets` stores the first ruleset.
3. If the project wants ERC-20 tokens, reserved-rate behavior, or hook-driven behavior, that configuration is set at launch.
4. The project can now accept payments and queue future rulesets without changing project identity.

**Failure Modes**
- accounting contexts do not match the intended terminal asset
- hook metadata or split assumptions are invalid at launch
- ownership or permission assumptions are wrong and expensive to fix later

**Postconditions**
- the project NFT exists, the first ruleset is active, accepted terminals are installed, and hooks or splits can start immediately

## Journey 2: Accept A Payment And Issue The Right Token Exposure

**Actor:** payer or integration paying for a user.

**Intent:** settle a payment through the canonical terminal path and issue the correct token exposure.

**Preconditions**
- the project has an active ruleset and a terminal that accepts the payer's asset

**Main Flow**
1. A payer calls `pay(...)` on `JBMultiTerminal`.
2. The terminal validates the accounting context, records funds, and asks `JBTerminalStore` to derive issuance from the active ruleset.
3. `JBController` and `JBTokens` decide whether the beneficiary gets project credits, ERC-20s, or no issuance because weight is zero.
4. Any configured pay hooks or data hooks run around the accounting path.

**Failure Modes**
- payments are paused or the token is unsupported for the target accounting context
- fee-on-transfer behavior or price-feed assumptions break the intended issuance path
- hooks add side effects that the payer or integrator did not account for

**Postconditions**
- treasury balances increase, hooks run in the right order, and the beneficiary receives credits or ERC-20 tokens that match the ruleset

## Journey 3: Turn Credits Into ERC-20 Tokens

**Actor:** holder or operator acting for a holder.

**Intent:** convert non-transferable project credits into ERC-20 balances once the project exposes a token.

**Preconditions**
- users already have project token credits
- the project now wants an ERC-20 representation

**Main Flow**
1. Deploy or set the project's ERC-20 token through `JBController`.
2. Holders or operators call `claimTokensFor(...)` to convert credits into ERC-20 balances for a beneficiary.
3. Future issuance can continue under the same project identity while users now interact with a standard token surface.

**Failure Modes**
- the wrong token is installed for the project
- integrations assume credits automatically become ERC-20 balances after token installation

**Postconditions**
- the project has an ERC-20 token and holders can claim credits into transferable balances

## Journey 4: Distribute Treasury Funds Through Governed Paths

**Actor:** owner or authorized operator.

**Intent:** move value out of the treasury through configured payout or allowance paths.

**Preconditions**
- the project has terminal balances
- the caller is allowed to use payout or allowance paths

**Main Flow**
1. An authorized caller uses payout or allowance entrypoints on the terminal.
2. `JBFundAccessLimits` bounds how much may leave for the current ruleset cycle.
3. `JBSplits` routes value to beneficiaries, projects, hooks, or fee recipients as configured.
4. `JBTerminalStore` updates balances and fee accounting so later previews and cash outs stay consistent.

**Failure Modes**
- splits or access limits no longer match operator expectations
- downstream hook execution fails during payout fanout
- operators assume allowance withdrawals behave exactly like payouts when fee treatment differs

**Postconditions**
- value leaves the treasury only through configured limits, recipients, and fee logic

## Journey 5: Let Holders Cash Out Against Surplus

**Actor:** holder or integrator acting for a holder.

**Intent:** exit project-token exposure against available terminal surplus.

**Preconditions**
- a holder owns project token exposure
- the project has reclaimable surplus in some terminal

**Main Flow**
1. The holder calls `cashOutTokensOf(...)` on the relevant terminal.
2. `JBTerminalStore` calculates reclaim value using surplus, total supply, cash-out tax rate, and any pending reserved-token effects.
3. Cash-out hooks can change behavior or side effects, but core accounting still comes from the terminal store.
4. Tokens burn and value exits the treasury through the terminal that held the asset.

**Failure Modes**
- fee-free or custom hook paths produce different outcomes than the holder expected
- preview and execution drift under changing routing or multi-terminal liquidity
- users treat multi-terminal surplus like one simple pool when it is not

**Postconditions**
- the holder burns the intended token exposure and receives the reclaim amount allowed by the current ruleset

## Journey 6: Queue New Rulesets Without Migrating The Project

**Actor:** owner or authorized operator.

**Intent:** change future project economics without changing identity or existing balances.

**Preconditions**
- the project is live and future economics need to change

**Main Flow**
1. The owner or an allowed operator queues one or more new rulesets through `JBController`.
2. `JBRulesets` stores the future configuration and any approval-hook requirements.
3. When the active duration ends, the next approved ruleset becomes live and later pays, payouts, and cash outs follow the new terms.
4. Existing balances and token history stay intact because only future behavior changed.

**Failure Modes**
- approval-hook requirements are forgotten or misunderstood
- queued metadata is incompatible with installed hooks
- teams assume a ruleset change can fix past accounting

**Postconditions**
- the next ruleset activates on schedule while the project keeps the same identity, treasury, and integrations

## Journey 7: Migrate To New Terminal Or Controller Surfaces

**Actor:** owner or migration operator.

**Intent:** move a live project to new terminal or controller surfaces without corrupting balances, permissions, or routing history.

**Preconditions**
- the project needs to move to a new terminal or controller path
- the destination surface is understood and intended

**Main Flow**
1. Confirm the active ruleset allows migration and the destination is the intended successor.
2. Use `JBController.migrate(...)` and the terminal-store migration paths instead of manually repointing addresses.
3. Recheck directory routing and accepted accounting contexts after migration.

**Failure Modes**
- migration targets are wrong or only partly configured
- operators manually repoint routing without using protocol migration paths

**Postconditions**
- balances, permissions, and future routing stay coherent after migration

## Journey 8: Hand Off Authority Without Handing Out Root Access

**Actor:** project owner.

**Intent:** delegate narrow project operations instead of blanket control.

**Preconditions**
- the owner wants operators, delegates, or automation to manage only specific surfaces

**Main Flow**
1. The owner configures operator permissions in `JBPermissions`.
2. Downstream calls check those packed permission bits instead of assuming project ownership.
3. Ownable wrappers, hook deployers, and router registries can respect project-scoped delegation without custom ACL logic.

**Failure Modes**
- operators receive broader permissions than they need
- auditors assume downstream access still depends only on project ownership

**Postconditions**
- permissions are narrow, auditable, and scoped to the actions the operator actually needs

## Trust Boundaries

- `JBTerminalStore` is the accounting source of truth for balances, surplus, fees, and reclaim behavior
- hooks, approval hooks, pay hooks, and cash-out hooks are trusted extension surfaces
- price feeds and directory routing are critical shared-context surfaces

## Hand-Offs

- Use [nana-permission-ids-v6](../nana-permission-ids-v6/USER_JOURNEYS.md) for the shared permission vocabulary used by downstream repos.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md), [nana-router-terminal-v6](../nana-router-terminal-v6/USER_JOURNEYS.md), and [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md) for opinionated layers built on the core terminal and ruleset surfaces.
