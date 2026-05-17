// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Variants of the unified `cashOutAndDeliver` cross-project entry on `JBMultiTerminal`. Replaces
/// the prior split between `payAfterCashOutTokensOf` (`Full`) and `addToBalanceAfterCashOutTokensOf`
/// (`DonationOnly`). Bundling the two entries lets them share the cashout + permission + delivery-snapshot
/// path that otherwise duplicates across both external functions.
/// @dev `Full` — mint destination-project tokens to `beneficiary` per the destination ruleset's weight and
/// data hook; slippage-checked against `minTokensOut`. `DonationOnly` — credit the destination project's
/// balance without minting; `beneficiary` and `minTokensOut` are ignored.
enum JBPayType {
    Full,
    DonationOnly
}
