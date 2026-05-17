# Changelog

## Scope

This file describes the verified change from `nana-core-v5` to the current `nana-core-v6` repo.

## Current v6 surface

- `JBController`
- `JBMultiTerminal`
- `JBTerminalStore`
- `JBRulesets`
- `JBTokens`
- the shared core interfaces, structs, and libraries under `src/`

## 0.0.53 — Drop the `via_ir` requirement

`JBCashOutHookSpecsLib.fulfill` originally took 10 named arguments. When `JBMultiTerminal._cashOutTokensOf` and `_routeReclaimAsPayViaLib` called it, the call site ran past solc 0.8.28's 16-slot Yul stack ceiling, which forced every consumer of `@bananapus/core-v6` to enable `via_ir = true` in their own `foundry.toml` profile. That cascaded into stack-too-deep failures in downstream packages whose own functions couldn't tolerate `via_ir` (notably `nana-721-hook-v6`'s `JB721TiersHookStore.tiersOf`).

This release reshapes `fulfill` to accept the existing `JBAfterCashOutRecordedContext` directly — the same struct the hook receives — so no parallel arg bundle is needed. The new signature is `fulfill(IJBFeelessAddresses, JBAfterCashOutRecordedContext, JBCashOutHookSpecification[])`. The per-iteration loop body is extracted into a private `_fulfillOne` helper so its locals don't share `fulfill`'s stack frame. Both call sites in `JBMultiTerminal` build the context field-by-field (one stack slot per assignment) instead of via a struct literal (which would push all ten fields onto the stack at once and trip the same ceiling at the caller).

Integrator impact:
- `JBCashOutHookSpecsLib.fulfill(IJBFeelessAddresses, uint256, JBTokenAmount, address, uint256, bytes, JBRuleset, uint256, address payable, JBCashOutHookSpecification[])` → `fulfill(IJBFeelessAddresses, JBAfterCashOutRecordedContext, JBCashOutHookSpecification[])`. The only on-chain caller is `JBMultiTerminal` (this PR updates both call sites), so the public ABI surface of `JBMultiTerminal` is unchanged.
- Consumers of `@bananapus/core-v6@^0.0.53` can drop `via_ir = true` from their `foundry.toml` profiles if they only enabled it because of `JBCashOutHookSpecsLib`. `nana-core-v6`'s own profile flips `via_ir` to `false` to lock in the property.
- All 997 unit/non-fork tests pass on the refactored library + call sites.

## Summary

- v6 adds explicit preview APIs for pay and cash-out flows. Integrations can simulate more of the terminal path directly from the core contracts.
- Token metadata is more editable than in v5. The controller now exposes a dedicated token-metadata update path.
- Approval-hook handling is safer. The v6 codebase and tests are built around preventing a bad approval hook from freezing project behavior.
- Fee accounting is tighter than in v5, especially around fee-free surplus behavior and cross-flow bookkeeping.
- The repo carries much broader test coverage than the v5 tree, including dedicated review, invariant, fork, and formal-style suites.
- The implementation baseline moved from the v5 `0.8.23` world to `0.8.28`.

## Verified deltas

- `IJBTerminal.previewPayFor(...)` is new.
- `IJBCashOutTerminal.previewCashOutFrom(...)` and `IJBTerminalStore.previewCashOutFrom(...)` are new preview surfaces.
- `IJBController.setTokenMetadataOf(uint256,string,string)` is new.
- `IJBController.addPriceFeed(...)` became `addPriceFeedFor(...)`.
- `IJBTerminal.currentSurplusOf(...)` now takes `address[] calldata tokens` instead of the old accounting-context array input.
- The interface surface adds explicit hook-spec return types to preview flows, which changes what off-chain callers can and should decode.
- `IJBCashOutTerminal.cashOutAndPay(...)` is new. It burns source-project tokens and pays the
  reclaim into another project via that project's primary terminal for the reclaim token (which may itself
  be a router that swaps before paying). Same-terminal retained balance is credited to
  `_feeFreeSurplusOf[beneficiaryProjectId][token]`, and same-terminal pay-hook egress is source-fee-bound
  per hook. External/router routes can skip the source fee only when no pay-hook forwarding is previewed,
  every beneficiary context on this terminal uses the source token, and the full source-token reclaim is
  retained here; previewed forwarding or mixed/cross-token output pays the source fee up front and routes net.
- `IJBCashOutTerminal.cashOutAndAddToBalance(...)` is new. Sibling of
  `cashOutAndPay` that adds the reclaim to the destination project's balance instead of paying
  (no destination tokens minted). Same source-side fee-skip + destination-side `_feeFreeSurplusOf` credit
  semantics, same opt-out via `pauseCrossProjectFeeFreeInflows`. Held-fee return on the destination side
  is hardcoded to `false` so this entrypoint cannot unlock B's held fees.
- `JBRulesetMetadata.pauseCrossProjectFeeFreeInflows` is new (bit 80 in the packed metadata word). Opt-out
  flag on the destination project's current ruleset; when set, `cashOutAndPay` and
  `cashOutAndAddToBalance` calls targeting the destination project revert. Default
  `false` allows inflows — matching the existing intra-terminal payout semantic where receiving projects
  accumulate `_feeFreeSurplusOf` credits from other projects' outflows. The trailing `metadata` field
  narrowed from 14 to 13 bits to make room.

## Breaking ABI changes

- `IJBController.addPriceFeed(...)` was renamed to `addPriceFeedFor(...)`.
- `IJBController.setTokenMetadataOf(...)` is new and sits on the core controller surface.
- `IJBController.previewMintOf(...)` is new.
- `IJBTerminal.previewPayFor(...)` is new.
- `IJBCashOutTerminal.previewCashOutFrom(...)` is new.
- `IJBCashOutTerminal.cashOutAndPay(...)` is new.
- `IJBCashOutTerminal.cashOutAndAddToBalance(...)` is new.
- `IJBFeeTerminal.FEE()` is REMOVED. The terminal no longer re-exports the protocol fee constant; read
  `JBConstants.FEE` directly. Off-chain integrators that previously called `terminal.FEE()` must switch to
  reading the constant from `JBConstants`.
- `IJBTerminalStore.previewPayFrom(...)` and `previewCashOutFrom(...)` are new.
- `IJBTerminal.currentSurplusOf(...)` changed parameter shape.
- `JBRulesetMetadata` adds `pauseCrossProjectFeeFreeInflows` and narrows `metadata` from 14 to 13 bits.
  Packed `JBRuleset.metadata` layout has shifted accordingly. Integrators that read the packed word directly
  must rebuild against the new layout.

## Indexer impact

- `SplitHookReverted` is a new controller event.
- Preview functions do not emit events, but they change what frontends and simulation services can derive without sending transactions.
- If your indexer inferred token metadata immutability from v5, that assumption is no longer safe once `setTokenMetadataOf(...)` is in use.

## Migration notes

- Rebuild against the v6 interfaces. This repo is too central for hand-maintained ABI diffs to be trustworthy.
- Review any integration that assumed old ruleset-cache behavior, old preview availability, or old token-metadata immutability.
- If your system relied on subtle fee-free cash-out behavior from v5, re-validate it against the v6 accounting model.

## ABI appendix

- Added functions
  - `IJBTerminal.previewPayFor(...)`
  - `IJBCashOutTerminal.previewCashOutFrom(...)`
  - `IJBCashOutTerminal.cashOutAndPay(...)`
  - `IJBCashOutTerminal.cashOutAndAddToBalance(...)`
  - `IJBTerminalStore.previewPayFrom(...)`
  - `IJBTerminalStore.previewCashOutFrom(...)`
  - `IJBController.previewMintOf(...)`
  - `IJBController.setTokenMetadataOf(...)`
- Added ruleset metadata flags
  - `JBRulesetMetadata.pauseCrossProjectFeeFreeInflows` (bit 80; narrowed `metadata` field from 14 to 13 bits)
- Added libraries
  - `JBHeldFeesLib` (held-fee bookkeeping extracted from `JBMultiTerminal` to relieve bytecode budget;
    called via delegatecall, storage refs preserved)
  - `JBCashOutHookSpecsLib` (cash-out hook specification fulfillment extracted from `JBMultiTerminal` to
    relieve bytecode budget after adding `cashOutAndAddToBalance`; called via delegatecall, emits
    `HookAfterRecordCashOut` from the terminal address)
- Renamed functions
  - `IJBController.addPriceFeed(...)` -> `addPriceFeedFor(...)`
- Removed functions
  - `IJBFeeTerminal.FEE()` (read `JBConstants.FEE` directly)
- Changed function shapes
  - `IJBTerminal.currentSurplusOf(...)`
- Added events
  - `SplitHookReverted`
- Added migration-sensitive capabilities
  - mutable token metadata
  - preview-oriented hook-spec decoding
