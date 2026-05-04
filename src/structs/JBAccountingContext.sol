// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Describes how a terminal accounts for a specific token — its address, decimal precision, and which
/// currency
/// it's priced in. Used when recording payments, payouts, and cash outs to ensure correct fixed-point arithmetic.
/// @custom:member token The token address (use `JBConstants.NATIVE_TOKEN` for ETH).
/// @custom:member decimals The number of decimals for this token's fixed-point amounts (e.g. 18 for ETH, 6 for USDC).
/// @custom:member currency The currency ID for price feed lookups. Convention: `uint32(uint160(tokenAddress))` for
/// tokens, or `JBCurrencyIds.ETH`/`JBCurrencyIds.USD` for well-known currencies.
struct JBAccountingContext {
    address token;
    uint8 decimals;
    uint32 currency;
}
