# Juicebox Core V6

`@bananapus/core-v6` is the core protocol package for Juicebox on EVM chains. It defines projects, rulesets, terminals, permissions, token issuance, cash outs, splits, price feeds, and the accounting surfaces that the rest of the V6 ecosystem builds on.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

If a V6 package moves value, mints tokens, checks permissions, or reasons about project configuration, it almost certainly depends on this repo.

The core package provides:

- project ownership and metadata through `JBProjects`
- ruleset lifecycle management through `JBRulesets`
- issuance, queueing, token setup, and splits through `JBController`
- multi-token terminal accounting through `JBMultiTerminal` and `JBTerminalStore`
- operator permissions through `JBPermissions`
- on-chain price-feed routing through `JBPrices`

Use this repo when you need the canonical protocol invariant. Do not duplicate its logic in downstream packages unless the repo is explicitly intended to wrap or extend the core surface.

If you only read one repo before auditing the rest of the ecosystem, read this one.

## Mental Model

The core protocol is easiest to reason about in four layers:

1. identity and configuration: `JBProjects`, `JBDirectory`, `JBRulesets`
2. execution: `JBController` and `JBMultiTerminal`
3. accounting: `JBTerminalStore`
4. permissions and external context: `JBPermissions`, `JBPrices`, feeless-address and deadline helpers

Most integrations touch only layer 2. Most economically important bugs leak through layer 3.

The shortest path through the repo is:

1. `JBController` for project launch and ruleset configuration
2. `JBMultiTerminal` for execution entrypoints
3. `JBTerminalStore` for economic truth
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
| `JBController` | Project launch, ruleset queueing, token configuration, and split management. |
| `JBMultiTerminal` | Main payment, payout, allowance, and cash-out terminal surface. |
| `JBTerminalStore` | Shared accounting store for balances, surplus, fees, and reclaim calculations. |
| `JBDirectory` | Project-to-controller and project-to-terminal routing registry. |
| `JBProjects` | ERC-721 project registry and ownership surface. |
| `JBPermissions` | Packed operator permissions registry. |
| `JBPrices` | Price feed routing used by terminals and integrations. |

## Integration Traps

- `JBMultiTerminal` is not a single-token terminal. Integrations that assume one token, one balance, or one primary path usually misread the accounting model.
- data hooks and cash-out hooks are not cosmetic. They can change effective issuance, reclaim value, and side effects on the path.
- permission checks are not always against the project owner. Some flows are scoped to the token holder instead.
- previews and execution are intentionally close, but integrators should still treat them as distinct surfaces when hooks or dynamic routing are involved.

## Where State Lives

- project identity and ownership live in `JBProjects`
- controller and terminal routing live in `JBDirectory`
- ruleset history and activation live in `JBRulesets`
- balances, surplus, fees, and reclaim accounting live in `JBTerminalStore`
- operator authority lives in `JBPermissions`

When in doubt, read the state-owning contract before the contract that merely forwards into it.

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

This repo contains both core deployments and periphery deployment helpers. Most other V6 packages assume these contracts exist first and treat them as the stable base layer of the ecosystem.

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

- hooks can meaningfully change payment and cash-out behavior, so core integrations must treat hook composition as part of the protocol surface
- permissions are flexible enough to be dangerous when scoped broadly or granted with wildcard project IDs
- multi-terminal and multi-token accounting is powerful but increases the chance of integration mistakes when callers assume a single-terminal model
- fee, surplus, and reclaim logic are economically sensitive and remain high-priority audit surfaces

The fastest way to misunderstand V6 is to treat the core contracts like a simple crowdfunding terminal. They are closer to a configurable accounting and settlement substrate.
