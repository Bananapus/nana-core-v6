// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member amount The total amount the fee was taken from, as a fixed point number with the same number of
/// decimals as the token's accounting context. `uint224` covers any realistic per-call fee basis (max
/// ~2.7e49 ETH-equivalent at 18 decimals) and is the same width the protocol's payout/surplus-allowance limits use.
/// @custom:member beneficiary The address that will receive the tokens that are minted as a result of the fee payment.
/// @custom:member unlockTimestamp The timestamp at which the fee is unlocked and can be processed.
struct JBFee {
    uint224 amount;
    address beneficiary;
    uint48 unlockTimestamp;
}
