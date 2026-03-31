# Juicebox Core

## Use This File For

- Use this file when the task touches protocol core behavior: payments, cash-outs, terminals, controller actions, rulesets, splits, tokens, permissions, or price feeds.
- Start here if you know the issue is in core, then open the specific contract that owns the state transition you are debugging.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and protocol framing | [`README.md`](./README.md) |
| Controller and project lifecycle behavior | [`src/JBController.sol`](./src/JBController.sol), [`src/JBProjects.sol`](./src/JBProjects.sol), [`src/JBTokens.sol`](./src/JBTokens.sol) |
| Payment, cash-out, surplus, and fee accounting | [`src/JBMultiTerminal.sol`](./src/JBMultiTerminal.sol), [`src/JBTerminalStore.sol`](./src/JBTerminalStore.sol), [`src/JBFundAccessLimits.sol`](./src/JBFundAccessLimits.sol) |
| Rulesets, permissions, directory, and prices | [`src/JBRulesets.sol`](./src/JBRulesets.sol), [`src/JBPermissions.sol`](./src/JBPermissions.sol), [`src/JBDirectory.sol`](./src/JBDirectory.sol), [`src/JBPrices.sol`](./src/JBPrices.sol) |
| Shared math, metadata parsing, and constants | [`src/libraries/`](./src/libraries/), [`src/structs/`](./src/structs/), [`src/enums/`](./src/enums/) |
| Periphery helpers and deployment | [`src/periphery/`](./src/periphery/), [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`script/DeployPeriphery.s.sol`](./script/DeployPeriphery.s.sol) |
| Invariants, fork tests, and security/economic regressions | [`test/formal/`](./test/formal/), [`test/fork/`](./test/fork/), [`test/audit/`](./test/audit/), [`test/helpers/`](./test/helpers/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, types, and enums | [`src/libraries/`](./src/libraries/), [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/), [`src/enums/`](./src/enums/) |
| Periphery | [`src/periphery/`](./src/periphery/) |
| Tests | [`test/`](./test/) |

## Purpose

The core Juicebox V6 protocol on EVM: a modular system for launching treasury-backed tokens with configurable rulesets that govern payments, payouts, cash outs, and token issuance.

## Reference Files

| If you need... | Open this next |
|---|---|
| Contract map and callable entrypoints | [`references/entrypoints.md`](./references/entrypoints.md) |
| Types, constants, gotchas, permissions, common errors, events, and hook return shapes | [`references/types-errors-events.md`](./references/types-errors-events.md) |

## Working Rules

- Open source before relying on any summary here. This skill is a router, not the ground truth.
- For runtime bugs, start from the terminal/controller/store contract that owns the state transition.
- For config or weird value-shape issues, open `references/types-errors-events.md` before changing structs or metadata packing.
