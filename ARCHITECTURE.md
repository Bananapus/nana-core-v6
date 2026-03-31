# Architecture

## Purpose

`nana-core-v6` is the protocol root. It owns project identity, permissions, rulesets, token supply, treasury balances, payout limits, fee logic, and the hook interfaces that every extension repo composes with.

If a change affects accounting, supply, fee behavior, terminal routing, or permission semantics, this is the repo that defines the source of truth.

## Boundaries

- The core owns balance and supply transitions.
- Extensions may adjust economics through hooks, but they should not invent competing ledgers.
- The core deliberately avoids app-specific behaviors like NFT composition, DEX routing strategy, or bridge-specific message transport.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBMultiTerminal` | Entry point for payments, cash outs, payouts, balance additions, and fee handling |
| `JBTerminalStore` | Bookkeeping and preview math for payment, payout, allowance, and cash-out paths |
| `JBController` | Project launch, ruleset queueing, token minting and burning, split-group updates |
| `JBDirectory` | Maps projects to controllers and terminals |
| `JBRulesets` | Time-ordered ruleset lifecycle and approval-hook integration |
| `JBTokens`, `JBERC20`, `JBProjects` | Token and project identity surfaces |
| `JBSplits`, `JBFundAccessLimits`, `JBPrices`, `JBPermissions` | Shared state for distribution, limits, price conversion, and authorization |

## Runtime Model

### Payment

```text
terminal receives funds
  -> terminal store reads the current ruleset and optional data hooks
  -> store computes weight-based minting results
  -> controller mints beneficiary tokens and accrues reserved tokens
  -> pay hooks execute only after settlement
```

### Cash Out

```text
holder requests redemption
  -> terminal store computes reclaim amount from surplus, supply, and tax settings
  -> optional data hooks can adjust the calculation inputs
  -> controller burns tokens
  -> terminal pays the reclaim amount and routes protocol fees
  -> cash-out hooks execute only after settlement
```

### Payouts And Allowances

```text
authorized caller
  -> consumes payout limits or surplus allowances
  -> funds move to splits, projects, hooks, or direct recipients
```

## Critical Invariants

- Preview functions must remain behaviorally aligned with state-changing functions.
- Data hooks run before settlement and may alter the economics; pay and cash-out hooks run after settlement. That phase boundary is intentional.
- Reserved tokens and pending reserves affect supply-sensitive math even before distribution.
- Terminal balances, fee accounting, and surplus calculations must agree. Any drift here contaminates every product repo.
- Rulesets are time-ordered and approval-aware; deployment wrappers depend on predictable ID progression and activation semantics.
- Permission checks are not a UI concern. They are part of protocol state transition validity.

## Where Complexity Lives

- `JBMultiTerminal`, `JBTerminalStore`, and `JBController` form one accounting pipeline and are easiest to misunderstand when read separately.
- Preview paths deliberately mirror state-changing paths; keeping them aligned is a permanent maintenance burden.
- Fee-free surplus, held fees, and payout/allowance interactions create edge cases that are small in code size but large in blast radius.

## Dependencies

- `nana-permission-ids-v6` for the shared permission namespace
- OpenZeppelin, PRBMath, Chainlink, and Permit2 for standards and math utilities

## Safe Change Guide

- Start any nontrivial change by tracing both the preview path and the state-changing path.
- Read downstream hook repos before changing hook interfaces or metadata expectations.
- Keep fee logic, balance logic, and surplus logic in sync; "small" tweaks here are almost always ecosystem-wide changes.
- When adding permissions or changing who is checked against a permission, update ecosystem docs and downstream assumptions immediately.
- If a change seems local inside core, assume it is not until proven otherwise.
