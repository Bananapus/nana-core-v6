# Review Guide

This is the core Juicebox V6 protocol. Most ecosystem invariants eventually reduce to this repo.

## Review Objective

Find issues that:

- break terminal solvency or internal accounting
- let projects extract more than payout or surplus-allowance limits
- miscompute payment minting, reserved tokens, or cash-out reclaim amounts
- corrupt ruleset transitions, approvals, or decay behavior
- bypass the permission model, migrations, or fee lifecycle

## Scope

In scope:

- all Solidity under `src/`
- deployment scripts in `script/`
- price-feed setup and periphery contracts under `src/periphery/`

Especially critical contracts:

- `JBMultiTerminal`
- `JBTerminalStore`
- `JBController`
- `JBRulesets`
- `JBTokens`
- `JBPermissions`
- `JBPrices`
- `JBSplits`
- `JBFundAccessLimits`

## Start Here

For the fastest serious review, read in this order:

- `JBTerminalStore`
- `JBMultiTerminal`
- `JBController`
- `JBRulesets`
- `JBPermissions`
- `JBPrices`

That order mirrors how most high-severity issues appear:

- accounting is computed
- funds move
- tokens mint or burn
- permissions and price context determine whether the move is allowed

## Security Model

Core roles:

- `JBMultiTerminal`: holds funds and executes pay, payout, cash-out, allowance, and fee-processing flows
- `JBTerminalStore`: owns accounting and surplus logic
- `JBController`: owns project lifecycle, token mint and burn, and permission-sensitive operations
- `JBRulesets`: stores current and queued economic parameters
- `JBTokens`: handles ERC-20 and credit accounting
- `JBPermissions`: provides the access-control backbone

Extension points:

- data hooks
- pay hooks
- cash-out hooks
- split hooks
- approval hooks

Ordering to keep in mind:

- the store records accounting before terminal fulfillment is finished
- controller mint and burn operations happen inside terminal flows, not in a separate settlement layer
- hooks can turn a simple pay or cash-out into a multi-contract flow

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project owner and operators | Configure rulesets, limits, routing, and permissions | Must stay inside the explicit permission model |
| Terminal | Hold funds and execute settlement | Must stay solvent relative to internal accounting |
| Controller | Mint, burn, and manage project lifecycle | Must not bypass project-scoped authorization |
| Hooks and splits | Extend pay and cash-out behavior | Must not make previews and accounting irreconcilable |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| Price feeds | Currency conversions are fresh and coherent | Cross-currency flows misprice |
| Hook ecosystem | External hooks obey documented interfaces | Settlement becomes unsafe after control transfer |
| Directory and migration surfaces | Canonical routing changes are authentic | Funds or permissions shift to the wrong place |

## Critical Invariants

1. Terminal solvency  
   Internal balances and held-fee obligations must reconcile with actual terminal token balances.
2. No over-withdrawal  
   Payouts and allowance usage must never exceed configured per-cycle limits.
3. Cash-out correctness  
   Surplus, total supply, tax rate, fee treatment, and hook overrides must combine into the intended reclaim amount.
4. Ruleset integrity  
   The active ruleset and any fallback or cycling behavior must match exact timing and approval-hook semantics.
5. Token accounting consistency  
   Credits, ERC-20 total supply, reserved token balance, and burn/mint paths must stay coherent.
6. Privilege containment  
   Permissions, wildcard grants, controller migration, and terminal routing must not allow unauthorized control or fund movement.
7. Held-fee correctness  
   Deferred fees must not be accidentally forgiven, duplicated, or charged to the wrong place.
8. Preview coherence  
   `previewPayFor` and `previewCashOutFrom` should not drift from execution in ways downstream repos can exploit.

## Attack Surfaces

- `pay`, `cashOutTokensOf`, `sendPayoutsOf`, and `useAllowanceOf`
- `preview*` paths when downstream repos treat them as execution truth
- held-fee lifecycle and `_processFee`
- surplus aggregation across terminals
- controller migration and terminal migration
- `setPermissionsFor` and wildcard semantics

Replay these sequences:

1. `pay` with a data hook that changes weight or hook specs and then reenters through a pay hook
2. `cashOutTokensOf` when cross-terminal surplus and `useTotalSurplusForCashOuts` matter
3. `sendPayoutsOf` into splits that route to another project, hook, or failing beneficiary
4. held-fee accumulation followed by migration or balance depletion
5. permission grants involving operators, wildcard project IDs, or later controller changes

## Accepted Risks Or Behaviors

- Hooks are intentionally powerful. Safety comes from clear ordering and bounded trust, not from avoiding composition.

## Verification

- `npm install`
- `forge build`
- `forge test`
