# Architecture

## Purpose

`nana-core-v6` is the root of the V6 stack. It owns project identity, rulesets, permissions, treasury balances, token issuance, fee behavior, fee-referral accounting, payout limits, and the hook interfaces that extension repos use.

If a change affects accounting, token supply, fees, terminal routing, or permission semantics, this repo is the source of truth.

## System Overview

`JBController`, `JBMultiTerminal`, and `JBTerminalStore` form the main execution and accounting path. `JBDirectory`, `JBRulesets`, `JBProjects`, `JBTokens`, `JBPermissions`, `JBSplits`, and related contracts provide routing, identity, and shared state for downstream repos.

`JBTerminalStore` is terminal-scoped through `msg.sender`, so each terminal tracks its own balances and usage while sharing the same ruleset and price surfaces. Hooks can change economics or add side effects, but they should not create a second ledger.

## Core Invariants

- Preview functions should stay aligned with the state-changing functions they mirror.
- Data hooks run before settlement and may change economics. Pay and cash-out hooks run after settlement.
- Reserved tokens and other pending supply affect supply-sensitive math before distribution.
- Terminal balances, fee accounting, reclaim math, and surplus calculations must agree.
- Fee logic taxes value leaving the system, not every internal rebalance.
- Fee referral credits must track fee volume without changing fee custody.
- Rulesets are time-ordered and approval-aware, and downstream deployers depend on predictable ID progression.
- Permission checks are protocol safety checks, not just UI hints.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBMultiTerminal` | Payment, cash-out, payout, allowance, and fee entrypoints | Execution surface |
| `JBTerminalStore` | Shared accounting and preview math | Economic source of truth |
| `JBController` | Launch, queue rulesets, mint, burn, and update split groups | Supply and configuration |
| `JBDirectory`, `JBRulesets` | Project routing and time-based ruleset lifecycle | Coordination layer |
| `JBProjects`, `JBTokens`, `JBERC20` | Identity and token surfaces | Ownership and tokenization |
| `JBPermissions`, `JBSplits`, `JBFundAccessLimits`, `JBPrices` | Shared authorization and configuration state | Cross-repo dependencies; price feeds are append-only with backups |

## Trust Boundaries

- This repo owns the canonical balance and supply transitions.
- Hook repos may change inputs and post-settlement behavior, but they should not replace the core ledger.
- External price feeds, Permit2, and ERC-20 behavior matter, but accounting truth still lives here.

## Critical Flows

### Payment

```text
terminal receives funds
  -> terminal store reads the active ruleset and optional data hooks
  -> before-pay data hook can change weight and return pay-hook specs
  -> terminal store records the payment in the terminal-scoped ledger
  -> controller mints beneficiary tokens and accrues reserved tokens
  -> pay hooks run after settlement
```

### Cash Out

```text
holder requests redemption
  -> terminal store reads the current ruleset, balances, and supply inputs
  -> before-cash-out data hook can change reclaim inputs and hook specs
  -> terminal store records the cash out in the terminal-scoped ledger
  -> controller burns tokens
  -> terminal pays reclaim value and routes protocol fees
  -> cash-out hooks run after settlement
```

### Launch And Queue Rulesets

```text
owner, operator, or omnichain ruleset operator
  -> controller launches or queues rulesets
  -> launch also sets the controller in the directory and configures terminals
  -> rulesets become the source of truth for later pay, cash-out, and admin constraints
```

### Payouts And Allowances

```text
authorized caller
  -> consumes payout limits or surplus allowances
  -> funds move to splits, projects, hooks, or direct recipients
  -> optional referral context credits fee volume when protocol fees are processed
  -> same-terminal project payouts stay inside terminal accounting and may add fee-free surplus
```

## Accounting Model

This repo owns the canonical ledger for balances, fees, fee-referral volume, supply-sensitive reclaim math, payout limits, allowances, reserved tokens, and preview calculations. Other repos may wrap or influence these values, but they should not duplicate them.

`JBTerminalStore` keeps terminal balances, payout-limit usage, and surplus-allowance usage. Those reset boundaries are not the same:

- payout-limit usage is tracked by ruleset cycle number
- surplus-allowance usage is tracked by `ruleset.id`

If a duration-based ruleset auto-cycles without a new ruleset ID, payout-limit usage resets but allowance usage does not.

## Security Model

- Review `JBMultiTerminal`, `JBTerminalStore`, and `JBController` as one pipeline.
- `JBTerminalStore` uses shared logic with terminal-scoped state. Misreading that split leads to bad accounting assumptions.
- Small changes in fee or surplus logic can affect every downstream repo.
- Same-terminal project payouts, fee-free surplus capping, and migration cleanup are coupled.
- `allowOwnerMinting` is not a universal mint kill switch. Other allowed paths can still mint.
- Hook ordering and preview-execution alignment are ongoing maintenance requirements.

## Safe Change Guide

- Trace both the preview path and the state-changing path for any nontrivial change.
- Read downstream hook repos before changing hook metadata or interface expectations.
- Keep fee logic, balance logic, reclaim math, and surplus math in sync.
- If you change same-terminal payouts between projects, re-check self-pay reverts, fee-free surplus accumulation, and post-pay caps.
- If you change ruleset rollover semantics, re-check which counters reset on cycle progression versus new ruleset IDs.
- If permissions change, update shared docs and downstream assumptions at the same time.

## Canonical Checks

- fee-free surplus and same-terminal payout behavior:
  `test/TestFeeFreeCashOutBypass.sol`
- migration and terminal-accounting continuity:
  `test/TestTerminalMigration.sol`
- ruleset ordering and transition behavior:
  `test/RulesetTransitions.t.sol`

## Source Map

- `src/JBController.sol`
- `src/JBMultiTerminal.sol`
- `src/JBTerminalStore.sol`
- `src/JBDirectory.sol`
- `src/JBRulesets.sol`
- `src/JBPermissions.sol`
- `test/TestFeeFreeCashOutBypass.sol`
- `test/TestTerminalMigration.sol`
- `test/RulesetTransitions.t.sol`
