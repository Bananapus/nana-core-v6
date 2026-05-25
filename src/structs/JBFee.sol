// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member amount The total amount the fee was taken from, as a fixed point number with the same number of
/// decimals as the token's accounting context. `uint224` covers any realistic per-call fee basis (max
/// ~2.7e49 ETH-equivalent at 18 decimals) and is the same width the protocol's payout/surplus-allowance limits use.
/// @custom:member referralChainId The EIP-155 chain ID of the referrer's home chain, captured from the upper bits of
/// the transient referral encoding at fee-take time. A value of `0` is the "current chain" sentinel — a referrer that
/// only encoded a project ID without a chain prefix is credited on the chain the fee is paid on. Packing this beside
/// `amount` in the same storage slot avoids growing `JBFee` to a third slot.
/// @custom:member beneficiary The address that will receive the tokens that are minted as a result of the fee payment.
/// @custom:member unlockTimestamp The timestamp at which the fee is unlocked and can be processed.
/// @custom:member referralProjectId The referrer's project ID on `referralChainId`. Captured from the lower bits of
/// `currentReferralProjectId` at fee-take time so held-fee attribution survives the 28-day hold window. The transient
/// slot and terminal entry-point arguments use the packed `(referralChainId << 48) | referralProjectId` form; this
/// struct stores the two halves separately for cheap storage.
struct JBFee {
    uint224 amount;
    uint32 referralChainId;
    address beneficiary;
    uint48 unlockTimestamp;
    uint48 referralProjectId;
}
