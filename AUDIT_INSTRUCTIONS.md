# Audit Instructions

This is the core Juicebox V6 protocol. Most ecosystem invariants reduce to this repo eventually.

## Objective

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

That order mirrors how most high-severity issues emerge:
- accounting is computed
- funds are moved
- tokens are minted or burned
- permissions and price context decide whether the move was legitimate

## System Model

Core roles:
- `JBMultiTerminal`: holds funds and executes pay, payout, cash-out, allowance, and fee-processing flows
- `JBTerminalStore`: accounting and surplus logic
- `JBController`: project lifecycle, token mint/burn, and permissions-sensitive operations
- `JBRulesets`: current and queued economic parameters
- `JBTokens`: ERC-20 and credit accounting
- `JBPermissions`: access-control backbone

The rest of the ecosystem plugs into these extension points:
- data hooks
- pay hooks
- cash-out hooks
- split hooks
- approval hooks

Core ordering to keep in mind:
- store records accounting before terminal fulfillment finishes
- controller mint and burn operations happen around terminal flows, not as a separate settlement layer
- hooks can turn what looks like a simple pay or cash-out into a multi-contract composition

## Critical Invariants

1. Terminal solvency
Internal balances and held-fee obligations must reconcile with actual terminal token balances.

2. No over-withdrawal
Payouts and allowance usage must never exceed configured per-cycle limits.

3. Cash-out correctness
Surplus, total supply, tax rate, fee treatment, and hook overrides must combine into the intended reclaim amount.

4. Ruleset integrity
The active ruleset and any fallback or cycling behavior must reflect exact timing and approval-hook semantics.

5. Token accounting consistency
Credits, ERC-20 total supply, reserved token balance, and burn/mint paths must remain internally coherent.

6. Privilege containment
Permissions, wildcard grants, controller migration, and terminal routing must not allow unauthorized project control or fund movement.

7. Held-fee correctness
When fee payment is deferred, later replenishment or migration behavior must not accidentally forgive, duplicate, or cross-charge the obligation.

8. Preview coherence
`previewPayFor` and `previewCashOutFrom` should not become meaningfully inconsistent with execution in ways downstream repos can exploit.

## Threat Model

Prioritize:
- hook-driven reentrancy or state-ordering issues
- price-feed failure and cross-currency conversions
- fee-processing failure paths
- migration and feeless-address edge cases
- ruleset-boundary timing attacks
- wildcard or root permission escalation

The highest-yield attacker mindsets here are:
- a malicious hook that receives control after balances move but before the full user flow is conceptually finished
- a project owner exploiting migration, limits, or feeless settings rather than breaking access control directly
- a cross-currency user extracting value from rounding or stale price conversions

## Hotspots

- `pay`, `cashOutTokensOf`, `sendPayoutsOf`, and `useAllowanceOf`
- `preview*` paths when downstream repos treat them as execution truth
- held-fee lifecycle and `_processFee`
- surplus aggregation across terminals
- controller migration and terminal migration
- `setPermissionsFor` and any wildcard semantics

## Sequences Worth Replaying

1. `pay` with a data hook that returns altered weight and hook specs, then re-enter through a pay hook.
2. `cashOutTokensOf` when `useTotalSurplusForCashOuts` or cross-terminal surplus logic matters.
3. `sendPayoutsOf` into splits that route to another project, hook, or failing beneficiary.
4. held-fee accumulation -> migration or balance depletion -> `processHeldFeesOf`.
5. permission grants involving operators, wildcard project IDs, or later controller changes.

## Finding Bar

The best findings in this repo usually prove one of these:
- the store records more value than the terminal can safely honor
- a limit is consumed too late, after externally controlled code can already profit
- a migration or held-fee edge path changes who ultimately bears an obligation
- permissions that look project-scoped become ecosystem-relevant through wildcard or routing semantics

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

The current test suite already targets:
- flash-loan and economic exploits
- permissions invariants
- ruleset transitions
- fee and migration edge cases
- multi-token and cross-currency surplus behavior

The highest-value findings in this repo are the ones that make downstream hooks or deployers unsafe even when those repos are otherwise correct.
