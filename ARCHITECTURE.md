# Architecture

## Purpose

`nana-core-v6` is the protocol root for the V6 stack. It owns project identity, rulesets, permissions, treasury balances, token issuance, fee behavior, payout limits, and the hook interfaces every extension repo composes with.

If a change affects accounting, supply, fee logic, terminal routing, or permission semantics, this repo is the source of truth.

## System Overview

`JBController`, `JBMultiTerminal`, and `JBTerminalStore` form the main execution and accounting pipeline. `JBDirectory`, `JBRulesets`, `JBProjects`, `JBTokens`, `JBPermissions`, `JBSplits`, and related contracts provide the routing, identity, and shared state that all downstream repos depend on. `JBTerminalStore` is terminal-scoped through `msg.sender`, so each terminal records its own balances and usage against the shared ruleset and price surfaces. Extensions may influence economics through hook interfaces, but they should not create competing ledgers.

## Core Invariants

- Preview functions must remain behaviorally aligned with state-changing functions.
- Data hooks run before settlement and may alter economics; pay and cash-out hooks run after settlement.
- Reserved tokens and other pending supply affect supply-sensitive math before distribution.
- Terminal balances, fee accounting, reclaim math, and surplus calculations must agree.
- Fee logic taxes fund egress, not every internal rebalance. Same-terminal project routing is a special case and must stay coherent with fee-free surplus tracking.
- Rulesets are time-ordered and approval-aware, and many deployer repos depend on predictable ID progression.
- Permission checks are protocol validity checks, not UI affordances.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBMultiTerminal` | Payment, cash-out, payout, allowance, and fee entrypoint | Execution surface |
| `JBTerminalStore` | Shared accounting and preview math | Economic source of truth |
| `JBController` | Launch, queue rulesets, mint, burn, and split-group updates | Supply and configuration |
| `JBDirectory`, `JBRulesets` | Project routing and time-based ruleset lifecycle | Coordination layer |
| `JBProjects`, `JBTokens`, `JBERC20` | Identity and token surfaces | Ownership and tokenization |
| `JBPermissions`, `JBSplits`, `JBFundAccessLimits`, `JBPrices` | Shared authorization and configuration state | Cross-repo dependencies |

## Trust Boundaries

- This repo owns canonical balance and supply transitions.
- Hook repos may adjust inputs and post-settlement side effects, but they should not replace the ledger defined here.
- External price feeds, Permit2, and ERC-20 behavior are dependencies, but accounting truth stays in core.

## Critical Flows

### Payment

```text
terminal receives funds
  -> terminal store reads the active ruleset and optional data hooks
  -> before-pay data hook can modify weight and return pay-hook specs
  -> terminal store records payment against the terminal-scoped ledger
  -> controller mints beneficiary tokens and accrues reserved tokens
  -> pay hooks run only after settlement
```

### Cash Out

```text
holder requests redemption
  -> terminal store reads current ruleset, balances, and supply inputs
  -> before-cash-out data hook can modify reclaim inputs and hook specs
  -> terminal store records the cash out against the terminal-scoped ledger
  -> controller burns tokens
  -> terminal pays reclaim value and routes protocol fees
  -> cash-out hooks run only after settlement
```

### Launch And Queue Rulesets

```text
owner, operator, or omnichain ruleset operator
  -> controller launches or queues rulesets
  -> launch path also sets the controller in the directory and configures terminals
  -> rulesets become the source of truth for subsequent pay, cash-out, and admin constraints
```

### Payouts And Allowances

```text
authorized caller
  -> consumes payout limits or surplus allowances
  -> funds move to splits, projects, hooks, or direct recipients
  -> same-terminal project payouts stay inside terminal accounting, may accrue fee-free surplus, and must not accidentally mint against the payer's own balance
```

## Accounting Model

This repo owns the canonical ledger for balances, fees, supply-sensitive reclaim math, payout limits, allowances, reserved tokens, and preview calculations. Other repos may wrap or influence these values, but none should duplicate them.

`JBTerminalStore` keeps terminal balances, payout-limit usage, and surplus-allowance usage. That state is terminal-scoped, but not all reset boundaries are the same: payout-limit usage is tracked by ruleset cycle number, while surplus-allowance usage is tracked by `ruleset.id`. Auto-cycling a duration-based ruleset does not reset allowance usage; queueing a new ruleset does.

## Security Model

- `JBMultiTerminal`, `JBTerminalStore`, and `JBController` should be reviewed as one pipeline.
- `JBTerminalStore` is shared logic but terminal-scoped state. Misunderstanding that split causes bad accounting assumptions.
- Small changes in fee or surplus logic can affect every downstream repo.
- Same-terminal project payouts, fee-free surplus capping, and migration cleanup are coupled. Changing one without the others creates fee bypasses or overcharges.
- `allowOwnerMinting` is not a universal mint kill switch. Terminals, the current data hook, and hook-authorized callers can still mint through the controller path.
- Hook ordering and preview-execution alignment are permanent maintenance obligations.

## Safe Change Guide

- Trace both preview and state-changing paths for any nontrivial change.
- Read downstream hook repos before changing hook metadata or interface expectations.
- Keep fee logic, balance logic, reclaim math, and surplus math synchronized.
- If you change payouts between projects on the same terminal, re-check self-pay revert behavior, fee-free surplus accumulation, and the post-pay cap against recorded balance.
- If you change ruleset rollover semantics, re-check which usage counters reset on cycle progression versus new ruleset IDs.
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
