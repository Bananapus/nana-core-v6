// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Human-readable configuration for a ruleset's behavioral flags and parameters. This struct is packed into
/// 256 bits for on-chain storage (see `JBRulesetMetadataResolver` for the packing layout).
/// @custom:member reservedPercent Percentage of newly minted tokens set aside for the reserved token split group,
/// out of `JBConstants.MAX_RESERVED_PERCENT`. 5,000 = 50% reserved.
/// @custom:member cashOutTaxRate Tax applied when holders cash out tokens, out of
/// `JBConstants.MAX_CASH_OUT_TAX_RATE`. Higher rate = less reclaim per token. 0 = proportional, 10,000 = no reclaim
/// (100% tax).
/// @custom:member baseCurrency The currency used to interpret the ruleset's weight for token issuance. Convention:
/// `uint32(uint160(tokenAddress))` for tokens, or `JBCurrencyIds.ETH`/`JBCurrencyIds.USD` for well-known currencies.
/// @custom:member pausePay If `true`, the project cannot receive payments during this ruleset.
/// @custom:member pauseCreditTransfers If `true`, token credit transfers are disabled during this ruleset.
/// @custom:member allowOwnerMinting If `true`, the project owner (or MINT_TOKENS operator) can mint tokens on demand.
/// @custom:member allowSetCustomToken If `true`, the project can set a custom ERC-20 token via `setTokenFor`.
/// @custom:member allowTerminalMigration If `true`, terminals can be migrated to new implementations.
/// @custom:member allowSetTerminals If `true`, the project's terminal list can be modified.
/// @custom:member allowSetController If `true`, the project's controller can be changed.
/// @custom:member allowAddAccountingContext If `true`, new token accounting contexts can be added to terminals.
/// @custom:member allowAddPriceFeed If `true`, the project can register new price feeds in `JBPrices`.
/// @custom:member ownerMustSendPayouts If `true`, only the project owner can trigger payout distribution.
/// @custom:member holdFees If `true`, fees are accumulated but not processed until a future ruleset (or manually).
/// @custom:member scopeCashOutsToLocalBalances If `true`, omnichain cash-out calculations use only the local chain's
/// balances (not cross-chain aggregates).
/// @custom:member pauseCrossProjectFeeFreeInflows If `true`, the project cannot be targeted by
/// `cashOutAsPaymentToProjectOf` calls during this ruleset.
/// @custom:member useDataHookForPay If `true`, the data hook is called before recording payments.
/// @custom:member useDataHookForCashOut If `true`, the data hook is called before recording cash outs.
/// @custom:member dataHook Contract called before pay/cash-out to potentially override token counts or add hooks.
/// @custom:member metadata 13 bits of application-specific metadata (upper 3 bits of the uint16 are ignored).
struct JBRulesetMetadata {
    uint16 reservedPercent;
    uint16 cashOutTaxRate;
    uint32 baseCurrency;
    bool pausePay;
    bool pauseCreditTransfers;
    bool allowOwnerMinting;
    bool allowSetCustomToken;
    bool allowTerminalMigration;
    bool allowSetTerminals;
    bool allowSetController;
    bool allowAddAccountingContext;
    bool allowAddPriceFeed;
    bool ownerMustSendPayouts;
    bool holdFees;
    bool scopeCashOutsToLocalBalances;
    bool pauseCrossProjectFeeFreeInflows;
    bool useDataHookForPay;
    bool useDataHookForCashOut;
    address dataHook;
    uint16 metadata;
}
