// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBFeelessAddresses} from "./IJBFeelessAddresses.sol";
import {IJBTerminal} from "./IJBTerminal.sol";
import {JBFee} from "../structs/JBFee.sol";

/// @notice A terminal that can process and hold fees.
interface IJBFeeTerminal is IJBTerminal {
    /// @notice A fee payment to the fee project reverted and was returned to the project's balance.
    /// @param projectId The ID of the project the fee was for.
    /// @param token The token the fee was denominated in.
    /// @param feeProjectId The ID of the fee project.
    /// @param amount The amount of the fee that reverted.
    /// @param reason The revert reason.
    /// @param caller The address that triggered the fee processing.
    event FeeReverted(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed feeProjectId,
        uint256 amount,
        bytes reason,
        address caller
    );

    /// @notice A fee was held for later processing.
    /// @param projectId The ID of the project the fee was held for.
    /// @param token The token the fee is denominated in.
    /// @param amount The amount from which the fee was calculated.
    /// @param fee The fee amount held.
    /// @param beneficiary The address that will receive project tokens when the fee is processed.
    /// @param caller The address that triggered the fee hold.
    event HoldFee(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed amount,
        uint256 fee,
        address beneficiary,
        address caller
    );

    /// @notice A fee was processed and paid to the fee project.
    /// @param projectId The ID of the project the fee was for.
    /// @param token The token the fee was denominated in.
    /// @param amount The fee amount processed.
    /// @param wasHeld Whether the fee was previously held.
    /// @param beneficiary The address that received project tokens from the fee payment.
    /// @param caller The address that triggered the fee processing.
    event ProcessFee(
        uint256 indexed projectId,
        address indexed token,
        uint256 indexed amount,
        bool wasHeld,
        address beneficiary,
        address caller
    );

    /// @notice Held fees were returned to a project's balance.
    /// @param projectId The ID of the project the held fees were returned to.
    /// @param token The token the fees are denominated in.
    /// @param amount The amount that triggered the fee return.
    /// @param returnedFees The total amount of fees returned.
    /// @param leftoverAmount The leftover amount after returning fees.
    /// @param caller The address that triggered the fee return.
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
