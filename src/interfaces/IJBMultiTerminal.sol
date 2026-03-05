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
import {IJBTerminalStore} from "./IJBTerminalStore.sol";
import {IJBTokens} from "./IJBTokens.sol";

/// @notice A terminal that manages native/ERC-20 payments, cash outs, and surplus allowance usage for any number of
/// projects.
interface IJBMultiTerminal is IJBTerminal, IJBFeeTerminal, IJBCashOutTerminal, IJBPayoutTerminal, IJBPermitTerminal {
    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The contract storing and managing project rulesets.
    function RULESETS() external view returns (IJBRulesets);

    /// @notice The contract that stores splits for each project.
    function SPLITS() external view returns (IJBSplits);

    /// @notice The terminal store that manages this terminal's data.
    function STORE() external view returns (IJBTerminalStore);

    /// @notice The contract that manages token minting and burning.
    function TOKENS() external view returns (IJBTokens);
}
