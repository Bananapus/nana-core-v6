# Juicebox Core

## Use This File For

- Use this file when the task touches core protocol behavior: payments, cash outs, terminals, controller actions, rulesets, splits, tokens, permissions, or price feeds.
- Start here when you know the issue is in core. Then narrow it to one state transition before reading more broadly.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and protocol framing | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Controller and project lifecycle behavior | [`src/JBController.sol`](./src/JBController.sol), [`src/JBProjects.sol`](./src/JBProjects.sol), [`src/JBTokens.sol`](./src/JBTokens.sol) |
| Payment, cash-out, surplus, fee, and referral accounting | [`src/JBMultiTerminal.sol`](./src/JBMultiTerminal.sol), [`src/JBTerminalStore.sol`](./src/JBTerminalStore.sol), [`src/JBFundAccessLimits.sol`](./src/JBFundAccessLimits.sol) |
| Rulesets, permissions, directory, and prices | [`src/JBRulesets.sol`](./src/JBRulesets.sol), [`src/JBPermissions.sol`](./src/JBPermissions.sol), [`src/JBDirectory.sol`](./src/JBDirectory.sol), [`src/JBPrices.sol`](./src/JBPrices.sol) |
| Shared math, metadata parsing, and constants | [`src/libraries/`](./src/libraries/), [`src/structs/`](./src/structs/), [`src/enums/`](./src/enums/) |
| Periphery helpers and deployment | [`src/periphery/`](./src/periphery/), [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`script/DeployPeriphery.s.sol`](./script/DeployPeriphery.s.sol) |
| Payment and cash-out entrypoints | [`references/entrypoints.md`](./references/entrypoints.md) |
| Packed metadata, errors, events, and hook return shapes | [`references/types-errors-events.md`](./references/types-errors-events.md) |
| Payment and cash-out behavior in tests | [`test/TestPayBurnRedeemFlow.sol`](./test/TestPayBurnRedeemFlow.sol), [`test/TestCashOut.sol`](./test/TestCashOut.sol), [`test/TestMultiTerminalSurplus.sol`](./test/TestMultiTerminalSurplus.sol), [`test/TestTerminalPreviewParity.sol`](./test/TestTerminalPreviewParity.sol) |
| Permissions, rulesets, and invariants | [`test/TestPermissions.sol`](./test/TestPermissions.sol), [`test/PermissionEscalation.t.sol`](./test/PermissionEscalation.t.sol), [`test/TestRulesetQueueing.sol`](./test/TestRulesetQueueing.sol), [`test/ComprehensiveInvariant.t.sol`](./test/ComprehensiveInvariant.t.sol), [`test/PermissionsInvariant.t.sol`](./test/PermissionsInvariant.t.sol) |
| Economic and exploit coverage | [`test/EconomicSimulation.t.sol`](./test/EconomicSimulation.t.sol), [`test/CoreExploitTests.t.sol`](./test/CoreExploitTests.t.sol), [`test/FlashLoanAttacks.t.sol`](./test/FlashLoanAttacks.t.sol), [`test/WeirdTokenTests.t.sol`](./test/WeirdTokenTests.t.sol), [`test/RegressionFixes.t.sol`](./test/RegressionFixes.t.sol) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, types, and enums | [`src/libraries/`](./src/libraries/), [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/), [`src/enums/`](./src/enums/) |
| Periphery | [`src/periphery/`](./src/periphery/) |
| Tests | [`test/`](./test/) |

## Purpose

This is the core Juicebox V6 protocol on EVM. It lets projects launch treasury-backed tokens with configurable rulesets for payments, payouts, cash outs, and token issuance.

For the canonical list of every doc in this repo (architecture, invariants, risks, admin, audit, changelog, style, references), see the README "Documentation" section.

## Working Rules

- Open the source before relying on any summary here.
- For runtime bugs, start from the terminal, controller, or store contract that owns the state transition.
- `JBMultiTerminal` and `JBTerminalStore` should usually be read together.
- Payment and cash-out previews are part of the protocol surface. Keep them aligned with execution.
- Payout limits reset by ruleset cycle number. Surplus allowances are keyed by `ruleset.id`. They do not always reset together.
- Fee handling is subtle. Re-check held fees, fee-free surplus tracking, and feeless-address behavior before changing payout or cash-out logic.
- Fee-referral volume is attribution metadata. Re-check `currentReferralProjectId`, held-fee referral fields, and `JBTerminalStore.recordFeeReferralCreditOf` when changing fee-bearing outflows.
- Fee-free surplus is a bounded anti-bypass mechanism, not a general exemption bucket.
- For config or metadata-shape issues, open `references/types-errors-events.md` before changing structs or packed metadata.
- If previews, accounting, or fee behavior change, verify the other two as well.
- If a bug looks cross-repo, prove it is not caused by a hook, router, or deployer before patching core.
