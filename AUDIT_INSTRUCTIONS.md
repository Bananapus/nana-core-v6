# Audit Instructions

This is the core Juicebox V6 protocol. Most ecosystem invariants reduce to this repo eventually.

## Audit Objective

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

## Security Model

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

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Project owner and operators | Configure rulesets, limits, routing, and permissions | Must stay inside the explicit permission model |
| Terminal | Hold funds and execute settlement | Must remain solvent relative to internal accounting |
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
The active ruleset and any fallback or cycling behavior must reflect exact timing and approval-hook semantics.

5. Token accounting consistency
Credits, ERC-20 total supply, reserved token balance, and burn/mint paths must remain internally coherent.

6. Privilege containment
Permissions, wildcard grants, controller migration, and terminal routing must not allow unauthorized project control or fund movement.

7. Held-fee correctness
When fee payment is deferred, later replenishment or migration behavior must not accidentally forgive, duplicate, or cross-charge the obligation.

8. Preview coherence
`previewPayFor` and `previewCashOutFrom` should not become meaningfully inconsistent with execution in ways downstream repos can exploit.

## Attack Surfaces

- `pay`, `cashOutTokensOf`, `sendPayoutsOf`, and `useAllowanceOf`
- `preview*` paths when downstream repos treat them as execution truth
- held-fee lifecycle and `_processFee`
- surplus aggregation across terminals
- controller migration and terminal migration
- `setPermissionsFor` and any wildcard semantics

Replay these sequences:
1. `pay` with a data hook that alters weight or hook specs and then reenters through a pay hook
2. `cashOutTokensOf` when cross-terminal surplus and `useTotalSurplusForCashOuts` matter
3. `sendPayoutsOf` into splits that route to another project, hook, or failing beneficiary
4. held-fee accumulation followed by migration or balance depletion
5. permission grants involving operators, wildcard project IDs, or later controller changes

## Accepted Risks Or Behaviors

- Hooks are intentionally powerful extension points; safety depends on clear sequencing and bounded trust, not on avoiding composition.

## Verification

- `npm install`
- `forge build`
- `forge test`
