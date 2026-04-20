# Juicebox Core

## Use This File For

- Use this file when the task touches protocol core behavior: payments, cash-outs, terminals, controller actions, rulesets, splits, tokens, permissions, or price feeds.
- Start here if you know the issue is in core, then identify the single state transition being changed before reading broadly. In this repo, most bugs reduce to controller lifecycle, terminal execution, store accounting, or ruleset state.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and protocol framing | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Controller and project lifecycle behavior | [`src/JBController.sol`](./src/JBController.sol), [`src/JBProjects.sol`](./src/JBProjects.sol), [`src/JBTokens.sol`](./src/JBTokens.sol) |
| Payment, cash-out, surplus, and fee accounting | [`src/JBMultiTerminal.sol`](./src/JBMultiTerminal.sol), [`src/JBTerminalStore.sol`](./src/JBTerminalStore.sol), [`src/JBFundAccessLimits.sol`](./src/JBFundAccessLimits.sol) |
| Rulesets, permissions, directory, and prices | [`src/JBRulesets.sol`](./src/JBRulesets.sol), [`src/JBPermissions.sol`](./src/JBPermissions.sol), [`src/JBDirectory.sol`](./src/JBDirectory.sol), [`src/JBPrices.sol`](./src/JBPrices.sol) |
| Shared math, metadata parsing, and constants | [`src/libraries/`](./src/libraries/), [`src/structs/`](./src/structs/), [`src/enums/`](./src/enums/) |
| Periphery helpers and deployment | [`src/periphery/`](./src/periphery/), [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`script/DeployPeriphery.s.sol`](./script/DeployPeriphery.s.sol) |
| Payment and cash-out entrypoint surface | [`references/entrypoints.md`](./references/entrypoints.md) |
| Packed metadata, gotchas, errors, and hook return shapes | [`references/types-errors-events.md`](./references/types-errors-events.md) |
| Cash-out, payment, and terminal accounting proofs | [`test/TestPayBurnRedeemFlow.sol`](./test/TestPayBurnRedeemFlow.sol), [`test/TestCashOut.sol`](./test/TestCashOut.sol), [`test/TestMultiTerminalSurplus.sol`](./test/TestMultiTerminalSurplus.sol), [`test/TestTerminalPreviewParity.sol`](./test/TestTerminalPreviewParity.sol) |
| Permissions, rulesets, and invariants | [`test/TestPermissions.sol`](./test/TestPermissions.sol), [`test/PermissionEscalation.t.sol`](./test/PermissionEscalation.t.sol), [`test/TestRulesetQueueing.sol`](./test/TestRulesetQueueing.sol), [`test/ComprehensiveInvariant.t.sol`](./test/ComprehensiveInvariant.t.sol), [`test/PermissionsInvariant.t.sol`](./test/PermissionsInvariant.t.sol) |
| Economic, exploit, and weird-token coverage | [`test/EconomicSimulation.t.sol`](./test/EconomicSimulation.t.sol), [`test/CoreExploitTests.t.sol`](./test/CoreExploitTests.t.sol), [`test/FlashLoanAttacks.t.sol`](./test/FlashLoanAttacks.t.sol), [`test/WeirdTokenTests.t.sol`](./test/WeirdTokenTests.t.sol), [`test/AuditFixes.t.sol`](./test/AuditFixes.t.sol) |

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
- For runtime bugs, start from the terminal/controller/store contract that owns the state transition. Most user-facing behavior is computed there, not in helpers or interfaces.
- `JBMultiTerminal` and `JBTerminalStore` are a pair. If you change one without re-deriving the other’s assumptions, expect accounting drift.
- Payment and cash-out previews are not optional convenience APIs. `previewPayFrom` and `previewCashOutFrom` are part of the protocol surface and need to stay aligned with execution semantics.
- Payout limits reset by ruleset cycle number, but surplus allowances are keyed by `ruleset.id`, not cycle number. Do not assume they reset together.
- Fee handling is nuanced. Re-check held fees, fee-free surplus tracking, and feeless-address behavior before changing payout or cash-out logic.
- Fee-free surplus is a bounded anti-bypass mechanism, not a generic exemption bucket. Re-check lifecycle capping and migration/reset behavior before changing cash-out or payout flows.
- For config or weird value-shape issues, open `references/types-errors-events.md` before changing structs or metadata packing.
- Terminal previews, accounting, and fee behavior are tightly coupled. If one changes, assume at least one of the others needs verification.
- Long-lived rulesets have a real cache boundary. If the issue involves extreme cycle counts, inspect `JBRulesets.updateRulesetWeightCache(...)` and the surrounding tests before touching weight math.
- When a bug smells cross-repo, prove it is not really coming from a hook, router, or downstream deployer before patching core.
