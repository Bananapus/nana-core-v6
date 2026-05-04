// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Well-known split group IDs. The reserved tokens group (ID 1) defines how a project's reserved tokens are
/// distributed. Payout split groups use the token address cast to `uint256(uint160(token))` as their group ID.
library JBSplitGroupIds {
    uint256 public constant RESERVED_TOKENS = 1;
}
