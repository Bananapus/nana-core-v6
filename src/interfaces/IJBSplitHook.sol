// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBSplitHookContext} from "../structs/JBSplitHookContext.sol";

/// @notice Allows processing a single split with custom logic.
/// @dev The split hook's address should be set as the `hook` in the relevant split.
interface IJBSplitHook is IERC165 {
    /// @notice Called by terminals and controllers while processing a split.
    /// @dev Critical business logic should be protected by appropriate access control. The tokens and/or native tokens
    /// are optimistically transferred to the split hook when this function is called.
    /// @param context The context passed by the terminal/controller to the split hook.
    function processSplitWith(JBSplitHookContext calldata context) external payable;
}
