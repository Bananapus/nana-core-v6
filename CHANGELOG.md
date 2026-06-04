# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `nana-core-v5` in `../../v5/evm` with the current `nana-core-v6` repo.

## Current V6 Surface

- `JBController`
- `JBMultiTerminal`
- `JBTerminalStore`
- `JBRulesets`
- `JBTokens`
- the shared core interfaces, structs, and libraries under `src/`

## Summary

- V6 adds explicit preview APIs for pay and cash-out flows. Frontends and backends can simulate more of the terminal path without submitting transactions.
- Token metadata is mutable through the controller/token surface. V5 assumptions that ERC-20 token name and symbol are fixed after deployment are no longer safe.
- Price feeds are append-only per exact pair, with primary feeds plus backup feeds that `pricePerUnitOf(...)` can skip when earlier feeds revert or return zero.
- Approval-hook, split-hook, and fee accounting behavior is more defensive. V6 emits more explicit failure events and rejects more invalid accounting states.
- Core structs and terminal interfaces changed enough that V5-generated types should be discarded rather than patched.
- The Solidity baseline moved from the V5 `0.8.23` era to `0.8.28`.

## ABI, Event, and Error Changes

- Added functions:
  - `IJBTerminal.previewPayFor(...)`
  - `IJBCashOutTerminal.previewCashOutFrom(...)`
  - `IJBTerminalStore.previewPayFrom(...)`
  - `IJBTerminalStore.previewCashOutFrom(...)`
  - `IJBController.previewMintOf(...)`
  - `IJBController.setTokenMetadataOf(...)`
  - `IJBPrices.priceFeedAt(...)`
  - `IJBPrices.priceFeedCountFor(...)`
  - `IJBPrices.priceFeedFor(...)`
  - `IJBProjects.MAX_CREATION_FEE()`
- Renamed functions:
  - `IJBController.addPriceFeed(...)` -> `addPriceFeedFor(...)`
- Changed function shapes:
  - `IJBTerminal.currentSurplusOf(...)`
  - `IJBCashOutTerminal.cashOutTokensOf(...)`
  - `IJBPayoutTerminal.sendPayoutsOf(...)`
  - `IJBPayoutTerminal.useAllowanceOf(...)`
- Added or migration-sensitive events:
  - `SplitHookReverted`
  - `SetTokenMetadata`
  - `Permit2AllowanceFailed`
  - payout and fee failure events should be regenerated from the V6 ABI.
- Added or migration-sensitive errors include:
  - `JBProjects_CreationFeeExceedsMax`
  - `JBMultiTerminal_OverflowAlert`
  - `JBTerminalStore_Uint224Overflow`
  - `JBPrices_PriceFeedAlreadyAdded`
  - `JBPrices_ZeroPriceFeed`
  - `JBMultiTerminal_SplitHookInvalid`

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-core-v5`.
- Own-source ABI artifacts compared: V6 `66`, V5 `63`.
- Contract/interface coverage: `4` added, `1` removed, `32` shared names with ABI changes, `30` shared names ABI-identical.
- Shared-name ABI item deltas: `147` added, `82` removed, `13` modified.

Added V6 ABI artifacts:
- `IJBFeelessHook` from `src/interfaces/IJBFeelessHook.sol`: `2` functions, `0` events, `0` errors.
- `IJBPayoutSplitGroupExecutor` from `src/libraries/JBPayoutSplitGroupLib.sol`: `1` functions, `0` events, `0` errors.
- `JBHeldFees` from `src/libraries/JBHeldFees.sol`: `0` functions, `1` events, `1` errors.
- `JBPayoutSplitGroupLib` from `src/libraries/JBPayoutSplitGroupLib.sol`: `0` functions, `2` events, `2` errors.

Removed V5 ABI artifacts:
- `JBRulesets5_1` from `src/JBRulesets5_1.sol`: `13` functions, `3` events, `8` errors.

Shared ABI artifacts with changes:
- `IJBCashOutTerminal`: `3` added, `1` removed, `0` modified ABI items.
- `IJBController`: `6` added, `4` removed, `1` modified ABI items.
- `IJBFeeTerminal`: `2` added, `2` removed, `1` modified ABI items.
- `IJBFeelessAddresses`: `6` added, `2` removed, `0` modified ABI items.
- `IJBMultiTerminal`: `4` added, `3` removed, `1` modified ABI items.
- `IJBPayoutTerminal`: `2` added, `1` removed, `0` modified ABI items.
- `IJBPermitTerminal`: `2` added, `1` removed, `0` modified ABI items.
- `IJBPrices`: `2` added, `0` removed, `0` modified ABI items.
- `IJBProjects`: `5` added, `0` removed, `1` modified ABI items.
- `IJBRulesetDataHook`: `1` added, `1` removed, `1` modified ABI items.
- `IJBRulesets`: `1` added, `1` removed, `0` modified ABI items.
- `IJBTerminal`: `2` added, `1` removed, `0` modified ABI items.
- `IJBTerminalStore`: `11` added, `5` removed, `1` modified ABI items.
- `IJBToken`: `1` added, `0` removed, `0` modified ABI items.
- `IJBTokens`: `2` added, `0` removed, `0` modified ABI items.
- `JBCashOuts`: `1` added, `1` removed, `0` modified ABI items.
- `JBChainlinkV3PriceFeed`: `1` added, `1` removed, `0` modified ABI items.
- `JBChainlinkV3SequencerPriceFeed`: `2` added, `2` removed, `0` modified ABI items.
- `JBConstants`: `3` added, `0` removed, `0` modified ABI items.
- `JBController`: `14` added, `10` removed, `2` modified ABI items.
- `JBERC20`: `8` added, `7` removed, `1` modified ABI items.
- `JBFeelessAddresses`: `7` added, `2` removed, `0` modified ABI items.
- `JBFundAccessLimits`: `3` added, `2` removed, `0` modified ABI items.
- `JBMetadataResolver`: `4` added, `4` removed, `0` modified ABI items.
- `JBMultiTerminal`: `9` added, `11` removed, `2` modified ABI items.
- `JBPermissions`: `1` added, `2` removed, `0` modified ABI items.
- `JBPrices`: `7` added, `4` removed, `0` modified ABI items.
- `JBProjects`: `10` added, `0` removed, `1` modified ABI items.
- `JBRulesets`: `1` added, `1` removed, `0` modified ABI items.
- `JBSplits`: `2` added, `2` removed, `0` modified ABI items.
- `JBTerminalStore`: `19` added, `8` removed, `1` modified ABI items.
- `JBTokens`: `5` added, `3` removed, `0` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `LaunchRulesets`, `PayoutReverted`, `ReturnHeldFees`, `SendPayoutToSplit`, `SetCreationFee`, `SetFeelessAddress`, `SetFeelessHook`, `SetTokenMetadata`.
  - `SplitHookReverted`.
- Event names removed or replaced:
  - `LaunchRulesets`, `OwnershipTransferred`, `PrepMigration`, `RulesetInitialized`, `RulesetQueued`, `SetFeelessAddress`, `WeightCacheUpdated`.
- Error names added:
  - `FailedCall`, `InsufficientBalance`, `JBCashOuts_DesiredOutputNotAchievable`, `JBChainlinkV3PriceFeed_IncompleteRound`, `JBChainlinkV3SequencerPriceFeed_InvalidRound`, `JBController_CreditTransfersPaused`, `JBController_InvalidCreationFee`, `JBController_NoReservedTokens`.
  - `JBController_ReservedTokenSplitProjectSameAsOwner`, `JBController_RulesetsArrayEmpty`, `JBController_TerminalTokensNotTransferred`, `JBController_ZeroTokensToBurn`, `JBController_ZeroTokensToMint`, `JBERC20_AlreadyInitialized`, `JBERC20_Unauthorized`, `JBFeelessAddresses_InvalidFeelessHook`.
  - `JBFundAccessLimits_DuplicateFundAccessLimitGroup`, `JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering`, `JBFundAccessLimits_InvalidSurplusAllowanceCurrencyOrdering`, `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_LengthMismatch`, `JBMetadataResolver_MetadataTooLong`, `JBMetadataResolver_MetadataTooShort`, `JBMultiTerminal_MintNotAllowed`.
  - `JBMultiTerminal_ReentrantTokenTransfer`, `JBMultiTerminal_TemporaryAllowanceNotConsumed`, `JBMultiTerminal_TerminalMigrationToSelf`, `JBMultiTerminal_UnderMin`, `JBPermissioned_Unauthorized`, `JBPermissions_NoZeroPermission`, `JBPrices_PriceFeedAlreadyAdded`, `JBPrices_PriceFeedNotFound`.
  - `JBPrices_ZeroPriceFeed`, `JBPrices_ZeroPricingCurrency`, `JBPrices_ZeroUnitCurrency`, `JBProjects_CreationFeeExceedsMax`, `JBProjects_InvalidCreationFee`, `JBProjects_ZeroCreationFeeReceiver`, `JBSplits_TotalPercentExceeds100`, `JBSplits_ZeroSplitPercent`.
  - `JBTerminalStore_AccountingContextAlreadySet`, `JBTerminalStore_AccountingContextDecimalsMismatch`, `JBTerminalStore_AccountingContextDecimalsOutOfRange`, `JBTerminalStore_AddingAccountingContextNotAllowed`, `JBTerminalStore_NoopHookSpecHasAmount`, `JBTerminalStore_RulesetPaymentPaused`, `JBTerminalStore_TerminalMigrationNotAllowed`, `JBTerminalStore_ZeroAccountingContextCurrency`.
  - `JBTokens_EmptyName`, `JBTokens_EmptySymbol`, `JBTokens_TokenNotFound`, `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`.
- Error names removed or replaced:
  - `JBCashOuts_DesiredOutputNotAchievable`, `JBChainlinkV3PriceFeed_IncompleteRound`, `JBChainlinkV3SequencerPriceFeed_InvalidRound`, `JBControlled_ControllerUnauthorized`, `JBController_CreditTransfersPaused`, `JBController_NoReservedTokens`, `JBController_RulesetsArrayEmpty`, `JBController_TerminalTokensNotTransferred`.
  - `JBController_ZeroTokensToBurn`, `JBController_ZeroTokensToMint`, `JBERC20_AlreadyInitialized`, `JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering`, `JBFundAccessLimits_InvalidSurplusAllowanceCurrencyOrdering`, `JBMetadataResolver_DataNotPadded`, `JBMetadataResolver_LengthMismatch`, `JBMetadataResolver_MetadataTooLong`.
  - `JBMetadataResolver_MetadataTooShort`, `JBMultiTerminal_AccountingContextAlreadySet`, `JBMultiTerminal_AccountingContextDecimalsMismatch`, `JBMultiTerminal_AddingAccountingContextNotAllowed`, `JBMultiTerminal_UnderMinReturnedTokens`, `JBMultiTerminal_UnderMinTokensPaidOut`, `JBMultiTerminal_UnderMinTokensReclaimed`, `JBMultiTerminal_ZeroAccountingContextCurrency`.
  - `JBPermissions_CantSetRootPermissionForWildcardProject`, `JBPermissions_NoZeroPermission`, `JBPrices_PriceFeedAlreadyExists`, `JBPrices_PriceFeedNotFound`, `JBPrices_ZeroPricingCurrency`, `JBPrices_ZeroUnitCurrency`, `JBRulesets_InvalidRulesetApprovalHook`, `JBRulesets_InvalidRulesetDuration`.
  - `JBRulesets_InvalidRulesetEndTime`, `JBRulesets_InvalidWeight`, `JBRulesets_InvalidWeightCutPercent`, `JBRulesets_WeightCacheRequired`, `JBSplits_TotalPercentExceeds100`, `JBSplits_ZeroSplitPercent`, `JBTerminalStore_InadequateControllerPayoutLimit`, `JBTerminalStore_RulesetPaymentPaused`.
  - `JBTerminalStore_TerminalMigrationNotAllowed`, `JBTokens_EmptyName`, `JBTokens_EmptySymbol`, `JBTokens_TokenNotFound`, `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `PRBMath_MulDiv_Overflow`.

Shared ABI artifacts checked with no ABI item changes:
- `IJBCashOutHook`, `IJBControlled`, `IJBDirectory`, `IJBDirectoryAccessControl`, `IJBFundAccessLimits`, `IJBMigratable`, `IJBPayHook`, `IJBPermissioned`.
- `IJBPermissions`, `IJBPriceFeed`, `IJBProjectUriRegistry`, `IJBRulesetApprovalHook`, `IJBSplitHook`, `IJBSplits`, `IJBTokenUriResolver`, `JBControlled`.
- `JBCurrencyIds`, `JBDeadline`, `JBDeadline1Day`, `JBDeadline3Days`, `JBDeadline3Hours`, `JBDeadline7Days`, `JBDirectory`, `JBFees`.
- `JBFixedPointNumber`, `JBMatchingPriceFeed`, `JBPermissioned`, `JBRulesetMetadataResolver`, `JBSplitGroupIds`, `JBSurplus`.

## Migration Notes

- Regenerate every core ABI and all generated types from the V6 sources.
- Re-check systems that inferred token metadata immutability, old ruleset-cache behavior, or the absence of preview surfaces.
- Review fee and payout indexing. V6 has more explicit hook/split failure behavior, and event assumptions from V5 can miss those cases.
