// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Well-known currency IDs used as the `baseCurrency` in ruleset metadata. These are distinct from accounting
/// context currencies (which use `uint32(uint160(tokenAddress))`). Only used for price feed lookups in `JBPrices`.
library JBCurrencyIds {
    uint32 public constant ETH = 1;
    uint32 public constant USD = 2;
}
