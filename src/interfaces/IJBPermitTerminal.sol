// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBTerminal} from "./IJBTerminal.sol";

/// @notice A terminal that supports Permit2 token approvals.
interface IJBPermitTerminal is IJBTerminal {
    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason);

    /// @notice The Permit2 contract used for token approvals.
    function PERMIT2() external returns (IPermit2);
}
