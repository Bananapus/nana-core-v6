// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBTerminal} from "./IJBTerminal.sol";

interface IJBPermitTerminal is IJBTerminal {
    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason);

    function PERMIT2() external returns (IPermit2);
}
