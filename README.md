# Juicebox Core V6

`@bananapus/core-v6` is the base protocol package for Juicebox on EVM chains. It defines projects, rulesets, terminals, permissions, token issuance, cash outs, splits, price feeds, and the accounting that the rest of the V6 ecosystem builds on.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## Overview

If a V6 package moves value, mints tokens, checks permissions, or reads project configuration, it probably depends on this repo.

This package provides:

- project ownership and metadata through `JBProjects`
- ruleset lifecycle management through `JBRulesets`
- token issuance, ruleset queueing, token setup, and splits through `JBController`
- multi-token terminal accounting through `JBMultiTerminal` and `JBTerminalStore`
- operator permissions through `JBPermissions`
- on-chain price-feed routing through `JBPrices`

Use this repo when you need the protocol's canonical accounting and execution logic. Do not copy that logic into downstream repos unless the repo is explicitly meant to wrap or extend core.

If you only read one V6 repo before reading the rest, read this one.

## Mental Model

It helps to think about core in four layers:

1. identity and configuration: `JBProjects`, `JBDirectory`, `JBRulesets`
2. execution: `JBController` and `JBMultiTerminal`
3. accounting: `JBTerminalStore`
4. permissions and shared context: `JBPermissions`, `JBPrices`, feeless-address and deadline helpers

Many integrations mostly touch layer 2. Many high-impact bugs are easier to understand in layer 3.

The shortest reading path is:

1. `JBController` for project launch and ruleset configuration
2. `JBMultiTerminal` for user-facing execution entrypoints
3. `JBTerminalStore` for the accounting model
4. `JBDirectory` and `JBPermissions` for routing and authority

## Read These Files First

1. `src/JBController.sol`
2. `src/JBMultiTerminal.sol`
3. `src/JBTerminalStore.sol`
4. `src/JBDirectory.sol`
5. `src/JBRulesets.sol`
6. `src/JBPermissions.sol`

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBController` | Launches projects, queues rulesets, configures tokens, and manages split groups. |
| `JBMultiTerminal` | Main payment, payout, allowance, and cash-out surface. |
| `JBTerminalStore` | Shared accounting for balances, surplus, fees, and reclaim math. |
| `JBDirectory` | Registry for controller and terminal routing. |
| `JBProjects` | ERC-721 project registry and ownership surface. |
| `JBPermissions` | Packed operator-permission registry. |
| `JBPrices` | Price-feed routing used by terminals and integrations. |

## Integration Traps

- `JBMultiTerminal` is multi-token and multi-terminal. Do not assume one token or one balance.
- Data hooks and cash-out hooks can change economics and side effects. They are part of the protocol surface.
- Permission checks are not always against the project owner. Some flows are scoped to the token holder instead.
- Preview and execution are intentionally close, but callers should still treat them as separate surfaces when hooks or routing can change behavior.

## Where State Lives

- project identity and ownership: `JBProjects`
- controller and terminal routing: `JBDirectory`
- ruleset history and activation: `JBRulesets`
- balances, surplus, fees, and reclaim accounting: `JBTerminalStore`
- operator authority: `JBPermissions`

When a flow is unclear, read the contract that owns the state before the contract that forwards into it.

## High-Signal Tests

1. `test/TestPayBurnRedeemFlow.sol`
2. `test/TestTerminalPreviewParity.sol`
3. `test/invariants/TerminalStoreInvariant.t.sol`
4. `test/invariants/RulesetsInvariant.t.sol`
5. `test/audit/CrossTerminalSurplusSpoof.t.sol`

## Install

```bash
npm install @bananapus/core-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run test:fork`
- `npm run deploy:mainnets`
- `npm run deploy:testnets`
- `npm run deploy:mainnets:periphery`
- `npm run deploy:testnets:periphery`

## Deployment Notes

This repo contains the main core deployments and periphery deployment helpers. Most other V6 packages assume these contracts exist first and treat them as the stable base layer.

## Repository Layout

```text
src/
  core contracts, periphery helpers, interfaces, libraries, enums, structs, and abstract bases
test/
  unit, integration, fork, invariant, audit, formal, and regression coverage
script/
  Deploy.s.sol
  DeployPeriphery.s.sol
  helpers/
```

## Risks And Notes

- Hooks can materially change payment and cash-out behavior.
- Permissions are flexible, which makes broad or wildcard grants risky.
- Multi-terminal and multi-token accounting is powerful, but it is easy to misuse if an integration assumes a single-terminal model.
- Fee, surplus, and reclaim logic stay high-priority audit areas.

The easiest way to misread V6 is to treat core like a simple crowdfunding terminal. It is closer to a configurable accounting and settlement layer.

## For AI Agents

- Start with `JBController`, `JBMultiTerminal`, and `JBTerminalStore`.
- Keep controller configuration, terminal execution, and store accounting separate in your mental model.
- If hooks are involved, inspect the hook repo before treating preview or execution behavior as final.
