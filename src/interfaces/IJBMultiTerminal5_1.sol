// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutTerminal} from "./IJBCashOutTerminal.sol";
import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBFeeTerminal} from "./IJBFeeTerminal.sol";
import {IJBPayoutTerminal} from "./IJBPayoutTerminal.sol";
import {IJBPermitTerminal} from "./IJBPermitTerminal.sol";
import {IJBProjects} from "./IJBProjects.sol";
import {IJBRulesets} from "./IJBRulesets.sol";
import {IJBSplits} from "./IJBSplits.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {IJBTerminalStore5_1} from "./IJBTerminalStore5_1.sol";
import {IJBTokens} from "./IJBTokens.sol";

interface IJBMultiTerminal5_1 is IJBTerminal, IJBFeeTerminal, IJBCashOutTerminal, IJBPayoutTerminal, IJBPermitTerminal {
    function DIRECTORY() external view returns (IJBDirectory);
    function PROJECTS() external view returns (IJBProjects);
    function SPLITS() external view returns (IJBSplits);
    function STORE() external view returns (IJBTerminalStore5_1);
    function TOKENS() external view returns (IJBTokens);
}
