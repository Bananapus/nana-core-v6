// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBTerminal} from "./IJBTerminal.sol";

/// @notice A terminal that supports Permit2 token approvals.
interface IJBPermitTerminal is IJBTerminal {
    /// @notice A Permit2 allowance approval failed.
    /// @param token The token the approval was attempted for.
    /// @param owner The owner of the tokens.
    /// @param reason The failure reason.
    /// @param caller The address that called the terminal function.
    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason, address caller);

    /// @notice The Permit2 contract used for gasless ERC-20 token approvals during payments.
    // forge-lint: disable-next-line(mixed-case-function)
    function PERMIT2() external returns (IPermit2);
}
