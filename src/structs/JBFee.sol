// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member amount The total amount the fee was taken from, as a fixed point number with the same number of
/// decimals as the token's accounting context.
/// @custom:member beneficiary The address that will receive the tokens that are minted as a result of the fee payment.
/// @custom:member unlockTimestamp The timestamp at which the fee is unlocked and can be processed.
/// @custom:member referralProjectId The referral project credited when this fee is eventually processed. Captured
/// from the originating fee-paying call's transient `currentReferralProjectId` so that held-fee attribution survives
/// the 28-day delay between the fee being taken and `processHeldFeesOf` actually paying it to the fee project.
/// Packs into the same slot as `beneficiary` (160 bits) and `unlockTimestamp` (48 bits) — 48 bits free for the
/// project ID (2^48 = ~2.8e14 IDs).
struct JBFee {
    uint256 amount;
    address beneficiary;
    uint48 unlockTimestamp;
    uint48 referralProjectId;
}
