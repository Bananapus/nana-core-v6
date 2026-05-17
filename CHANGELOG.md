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

## Breaking ABI changes

- `IJBController.addPriceFeed(...)` was renamed to `addPriceFeedFor(...)`.
- `IJBController.setTokenMetadataOf(...)` is new and sits on the core controller surface.
- `IJBController.previewMintOf(...)` is new.
- `IJBTerminal.previewPayFor(...)` is new.
- `IJBCashOutTerminal.previewCashOutFrom(...)` is new.
- `IJBTerminalStore.previewPayFrom(...)` and `previewCashOutFrom(...)` are new.
- `IJBTerminal.currentSurplusOf(...)` changed parameter shape.

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
  - `IJBTerminalStore.previewPayFrom(...)`
  - `IJBTerminalStore.previewCashOutFrom(...)`
  - `IJBController.previewMintOf(...)`
  - `IJBController.setTokenMetadataOf(...)`
- Renamed functions
  - `IJBController.addPriceFeed(...)` -> `addPriceFeedFor(...)`
- Changed function shapes
  - `IJBTerminal.currentSurplusOf(...)`
- Added events
  - `SplitHookReverted`
- Added migration-sensitive capabilities
  - mutable token metadata
  - preview-oriented hook-spec decoding
