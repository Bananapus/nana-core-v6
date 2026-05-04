// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBRulesetApprovalHook} from "./../interfaces/IJBRulesetApprovalHook.sol";

/// @notice A ruleset defines how a project behaves during a period of time — token issuance rate, cash-out terms,
/// payout rules, and permissions. Rulesets cycle automatically: when one expires, the next queued (and approved) one
/// takes effect. If nothing is queued, the current ruleset auto-cycles with decayed weight.
/// @dev Timestamps are unix timestamps (seconds since epoch).
/// @custom:member cycleNumber Which cycle this is (starts at 1, increments each cycle).
/// @custom:member id The ruleset's ID — the unix timestamp when it was first stored. Stays the same across
/// auto-cycles.
/// @custom:member basedOnId The ID of the ruleset that was active when this one was created (forms a linked list).
/// @custom:member start When this ruleset became/becomes active.
/// @custom:member duration How many seconds the ruleset lasts. 0 = no auto-cycling (must be explicitly replaced).
/// @custom:member weight Tokens minted per unit paid (18 decimals). The terminal divides payment amount by weight to
/// determine token issuance. Higher weight = more tokens per unit of payment.
/// @custom:member weightCutPercent How much to reduce weight each cycle (out of 1,000,000,000). 100,000,000 = 10% cut
/// per cycle. 0 = no decay. Only applies when a cycle auto-rolls without an explicitly queued replacement.
/// @custom:member approvalHook A contract that gates whether queued rulesets can take effect (e.g. `JBDeadline` for
/// minimum notice periods). If the hook rejects a queued ruleset, the current one continues.
/// @custom:member metadata Packed 256-bit field containing reservedPercent, cashOutTaxRate, baseCurrency, boolean
/// flags, data hook address, and custom metadata. Decoded by `JBRulesetMetadataResolver`.
struct JBRuleset {
    uint48 cycleNumber;
    uint48 id;
    uint48 basedOnId;
    uint48 start;
    uint32 duration;
    uint112 weight;
    uint32 weightCutPercent;
    IJBRulesetApprovalHook approvalHook;
    uint256 metadata;
}
