// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutHook} from "../interfaces/IJBCashOutHook.sol";

/// @notice A cash out hook specification sent from the ruleset's data hook back to the terminal for fulfillment.
/// @custom:member hook The cash out hook to use when fulfilling this specification.
/// @custom:member noop A flag indicating if the hook callback should be skipped.
/// @custom:member amount The amount to send to the hook.
/// @custom:member metadata Metadata to pass to the hook.
struct JBCashOutHookSpecification {
    IJBCashOutHook hook;
    bool noop;
    uint256 amount;
    bytes metadata;
}
