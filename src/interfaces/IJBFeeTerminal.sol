// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBFeelessAddresses} from "./IJBFeelessAddresses.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {JBFee} from "../structs/JBFee.sol";

/// @notice A terminal that can process and hold fees.
interface IJBFeeTerminal is IJBTerminal {
    event FeeReverted(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed feeProjectId,
        uint256 amount,
        bytes reason,
        address caller
    );
    event HoldFee(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed amount,
        uint256 fee,
        address beneficiary,
        address caller
    );
    event ProcessFee(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed amount,
        bool wasHeld,
        address beneficiary,
        address caller
    );
    event ReturnHeldFees(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed amount,
        uint256 returnedFees,
        uint256 leftoverAmount,
        address caller
    );

    /// @notice The terminal's fee as a fraction of `JBConstants.MAX_FEE`.
    function FEE() external view returns (uint256);

    /// @notice The contract that tracks feeless addresses.
    function FEELESS_ADDRESSES() external view returns (IJBFeelessAddresses);

    /// @notice Returns the held fees for a project and token.
    /// @param projectId The ID of the project to get held fees for.
    /// @param token The token the fees are denominated in.
    /// @param count The maximum number of held fees to return.
    /// @return An array of held fee structs.
    function heldFeesOf(uint256 projectId, address token, uint256 count) external view returns (JBFee[] memory);

    /// @notice Processes held fees for a project.
    /// @param projectId The ID of the project to process held fees for.
    /// @param token The token the fees are denominated in.
    /// @param count The number of held fees to process.
    function processHeldFeesOf(uint256 projectId, address token, uint256 count) external;
}
