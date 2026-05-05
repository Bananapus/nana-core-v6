// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBRulesetApprovalHook} from "../interfaces/IJBRulesetApprovalHook.sol";
import {JBFundAccessLimitGroup} from "./JBFundAccessLimitGroup.sol";
import {JBRulesetMetadata} from "./JBRulesetMetadata.sol";
import {JBSplitGroup} from "./JBSplitGroup.sol";

/// @notice The configuration passed to `JBController.launchRulesetsFor` or `queueRulesetsOf` to define a new ruleset.
/// Includes the economic parameters (weight, duration, decay), the metadata (permissions and hooks), the split
/// recipients, and the fund access limits.
/// @custom:member mustStartAtOrAfter The earliest timestamp the ruleset can begin. Pass 0 to start immediately after
/// the previous ruleset ends.
/// @custom:member duration How long the ruleset lasts in seconds. 0 = stays active until explicitly replaced.
/// @custom:member weight Tokens minted per unit of payment (18 decimals). Pass 1 to inherit decayed weight from the
/// previous ruleset. Pass 0 for no token issuance.
/// @custom:member weightCutPercent Decay rate per cycle, out of `JBConstants.MAX_WEIGHT_CUT_PERCENT`. 100,000,000 =
/// 10% cut. 0 = no decay.
/// @custom:member approvalHook Contract that must approve the *next* queued ruleset for it to take effect.
/// @custom:member metadata The ruleset's behavioral flags and parameters (see `JBRulesetMetadata`).
/// @custom:member splitGroups How payouts and reserved tokens are distributed during this ruleset.
/// @custom:member fundAccessLimitGroups How much the project can withdraw from each terminal per cycle.
struct JBRulesetConfig {
    uint48 mustStartAtOrAfter;
    uint32 duration;
    uint112 weight;
    uint32 weightCutPercent;
    IJBRulesetApprovalHook approvalHook;
    JBRulesetMetadata metadata;
    JBSplitGroup[] splitGroups;
    JBFundAccessLimitGroup[] fundAccessLimitGroups;
}
