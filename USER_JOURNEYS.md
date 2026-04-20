# User Journeys

## Repo Purpose

This repo is the canonical Juicebox V6 runtime surface.
It owns project identity, rulesets, terminal execution, treasury accounting, permissions, price feeds, and migration
paths. Most other V6 repos wrap or extend this behavior rather than replacing it.

## Primary Actors

- founders launching and evolving Juicebox projects
- supporters paying projects in the asset a terminal accepts
- token holders cashing out against project surplus
- operators managing permissions, splits, fund access limits, and rulesets
- integrators wiring hooks, terminals, price feeds, and migrations into the canonical protocol surface

## Key Surfaces

- `JBController`: project launch, ruleset queueing, token setup, splits, and controller migration
- `JBMultiTerminal`: pay, payout, allowance, preview, and cash-out entrypoint
- `JBTerminalStore`: balance, surplus, fee, and reclaim accounting
- `JBDirectory`: controller and terminal routing
- `JBPermissions`: packed operator-permission registry
- `JBProjects`, `JBRulesets`, `JBPrices`, `JBFundAccessLimits`, `JBSplits`, `JBTokens`: core state and helper surfaces

## Journey 1: Launch A Project With The Right Initial Shape

**Actor:** founder, deployer, or protocol integrator.

**Intent:** create a project with the right owner, terminal, ruleset, and hook assumptions from block zero.

**Preconditions**
- the team knows who should own the project, which terminals it should use, and what the first ruleset should allow

**Main Flow**
1. Call `JBController.launchProjectFor(...)` with the owner, URI, ruleset config, terminal configs, and any split or hook metadata.
2. `JBProjects` mints the project NFT, `JBDirectory` records controller and terminal routing, and `JBRulesets` stores the first ruleset.
3. If the project wants ERC-20 tokens, reserved-rate behavior, or hook-driven behavior, that configuration is committed at launch instead of being inferred later.
4. The project can now accept payments and queue future rulesets without changing project identity.

**Failure Modes**
- accounting contexts do not match the intended terminal asset
- hook metadata or split assumptions are invalid at launch
- ownership or permission assumptions are wrong and expensive to repair later

**Postconditions**
- the project NFT exists, the initial ruleset is active, accepted terminals are installed, and downstream hooks or splits can begin working immediately

## Journey 2: Accept A Payment And Issue The Right Token Exposure

**Actor:** payer or integration paying on a user's behalf.

**Intent:** settle a payment through the canonical terminal path and issue the correct token exposure.

**Preconditions**
- the project has an active ruleset and a terminal that accepts the payer's asset

**Main Flow**
1. A payer calls `pay(...)` on `JBMultiTerminal`.
2. The terminal validates the accounting context, records funds, and asks `JBTerminalStore` to derive issuance from the active ruleset.
3. `JBController` and `JBTokens` decide whether the beneficiary gets project token credits, ERC-20s, or no issuance because weight is zero.
4. Any configured pay hooks or data hooks run around the accounting path.

**Failure Modes**
- payments are paused or the token is unsupported for the target accounting context
- fee-on-transfer behavior or price-feed assumptions break the intended issuance path
- hooks add side effects the payer or integrator did not account for

**Postconditions**
- treasury balances increase, hooks run in the right order, and the beneficiary receives credits or ERC-20 tokens consistent with the ruleset

## Journey 3: Turn Credits Into ERC-20 Tokens Once A Project Wants A Transferable Token

**Actor:** holder or operator acting for a holder.

**Intent:** convert non-transferable project credits into ERC-20 balances once the project exposes a token.

**Preconditions**
- users already have project token credits
- the project now wants an ERC-20 representation

**Main Flow**
1. Deploy or set the project's ERC-20 token through `JBController`.
2. Holders or operators call `claimTokensFor(...)` to convert credits into ERC-20 balances for a beneficiary.
3. Future issuance can continue using the same project identity while users now interact with a standard token surface.

**Failure Modes**
- the wrong token is installed for the project
- integrations assume credits are automatically ERC-20 balances after token installation

**Postconditions**
- the project deploys or installs its ERC-20 token and holders can claim credits into transferable balances

## Journey 4: Distribute Treasury Funds Through Governed Paths

**Actor:** owner or authorized operator.

**Intent:** move value out of the treasury through configured payouts or allowance surfaces.

**Preconditions**
- the project has terminal balances
- the caller is allowed to use payout or allowance paths

**Main Flow**
1. Authorized actors call payout or allowance surfaces on the terminal.
2. `JBFundAccessLimits` bounds how much may leave for the current ruleset cycle.
3. `JBSplits` fans value out to beneficiaries, projects, hooks, or fee recipients as configured.
4. `JBTerminalStore` updates balances and fee accounting so later previews and cash outs remain consistent.

**Failure Modes**
- splits or access limits no longer match operator expectations
- downstream hook execution fails during payout fanout
- operators assume allowance withdrawals behave exactly like payouts when fee treatment differs

**Postconditions**
- treasury value leaves only through configured limits, recipients, and fee logic instead of arbitrary admin withdrawals

## Journey 5: Let Holders Cash Out Against Surplus

**Actor:** holder or integrator acting for a holder.

**Intent:** exit project-token exposure against available terminal surplus.

**Preconditions**
- a holder owns project token exposure
- the project has reclaimable surplus in some terminal

**Main Flow**
1. The holder calls `cashOutTokensOf(...)` on the relevant terminal.
2. `JBTerminalStore` calculates reclaim value using surplus, outstanding token supply, cash-out tax rate, and any pending reserved token effects.
3. Cash-out hooks can modify behavior or side effects, but the core accounting remains anchored in the terminal store.
4. Tokens burn and value exits the treasury through the terminal that actually held the asset.

**Failure Modes**
- fee-free or custom hook paths produce different outcomes than the holder expected
- preview-versus-execution drift appears under volatile routing or multi-terminal liquidity
- users misread multi-terminal surplus as one homogeneous pool

**Postconditions**
- the holder burns the intended amount of token exposure and receives the correct reclaim amount under the current ruleset

## Journey 6: Queue New Rulesets Without Migrating The Project

**Actor:** owner or authorized operator.

**Intent:** change future project economics without changing the project's identity or existing balances.

**Preconditions**
- the project is live and future economics need to change

**Main Flow**
1. The owner or an operator with the right permission queues one or more new rulesets through `JBController`.
2. `JBRulesets` stores the proposed future configuration and any approval hook requirements.
3. When the active duration elapses, the next approved ruleset becomes live and future pays, payouts, and cash outs follow the new terms.
4. Existing balances and token history remain intact because only future behavior changed.

**Failure Modes**
- approval-hook requirements are forgotten or misunderstood
- queued metadata is incompatible with installed hooks
- teams assume a ruleset change can retroactively fix prior accounting

**Postconditions**
- the next ruleset activates on schedule while the project keeps the same identity, treasury, and downstream integrations

## Journey 7: Migrate A Project To New Terminal Or Controller Surfaces Deliberately

**Actor:** owner or migration operator.

**Intent:** move a live project to new terminal or controller surfaces without corrupting balances, permissions, or routing history.

**Preconditions**
- the project needs to move to a new terminal or controller path
- the destination surface is understood and intended

**Main Flow**
1. Confirm the active ruleset permits migration and the destination surface is the intended successor.
2. Use `JBController.migrate(...)` and the terminal-store migration paths instead of manually repointing addresses.
3. Recheck directory routing and accepted accounting contexts after migration completes.

**Failure Modes**
- migration targets are wrong or only partially configured
- operators manually repoint routing without using the protocol's migration surfaces

**Postconditions**
- balances, permissions, and future routing stay coherent after migration

## Journey 8: Hand Off Authority Without Handing Out Root Access

**Actor:** project owner.

**Intent:** delegate project operations narrowly instead of transferring blanket control.

**Preconditions**
- the owner wants operators, delegates, or automation to manage only specific surfaces

**Main Flow**
1. The owner configures operator permissions in `JBPermissions`.
2. Downstream calls check those packed permission bits instead of assuming project ownership.
3. Integrations such as ownable wrappers, hook deployers, and router registries can now respect project-scoped delegation without custom ACL logic.

**Failure Modes**
- operators receive permissions broader than they need
- auditors assume downstream access still depends only on project ownership

**Postconditions**
- permissions are narrow, auditable, and scoped to the actions the operator actually needs

## Trust Boundaries

- `JBTerminalStore` is the accounting truth for balances, surplus, fees, and reclaim behavior
- hooks, approval hooks, pay hooks, and cash-out hooks are trusted extension surfaces, not cosmetic plugins
- price feeds and directory routing are critical external-context surfaces inherited by many downstream repos

## Hand-Offs

- Use [nana-permission-ids-v6](../nana-permission-ids-v6/USER_JOURNEYS.md) for the shared permission vocabulary that downstream repos import.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md), [nana-router-terminal-v6](../nana-router-terminal-v6/USER_JOURNEYS.md), and [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md) for opinionated layers on top of the core terminal and ruleset surfaces.
