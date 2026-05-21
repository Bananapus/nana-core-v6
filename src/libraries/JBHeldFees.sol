// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBFeeTerminal} from "../interfaces/IJBFeeTerminal.sol";
import {JBFee} from "../structs/JBFee.sol";
import {JBFees} from "./JBFees.sol";

/// @notice External-library implementation of held-fee storage operations for `JBMultiTerminal`.
/// @dev Functions are `external` so they live in this library's deployed bytecode and are reached from the caller
/// terminal via `DELEGATECALL`, keeping terminal bytecode below the EIP-170 limit. Storage refs are passed by
/// parameter so the library reads/writes the caller's mappings.
library JBHeldFees {
    /// @notice Returns up to `count` held fees for a project/token, starting from the next unprocessed index.
    /// @param heldFeesOf The terminal's held-fee storage mapping.
    /// @param nextHeldFeeIndexOf The terminal's per-project/token next-index storage mapping.
    /// @param projectId The ID of the project to read held fees for.
    /// @param token The token the fees are denominated in.
    /// @param count The maximum number of held fees to return.
    /// @return heldFees The held fees.
    function viewHeldFees(
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        mapping(uint256 => mapping(address => uint256)) storage nextHeldFeeIndexOf,
        uint256 projectId,
        address token,
        uint256 count
    )
        external
        view
        returns (JBFee[] memory heldFees)
    {
        uint256 startIndex = nextHeldFeeIndexOf[projectId][token];
        uint256 numberOfHeldFees = heldFeesOf[projectId][token].length;

        if (startIndex >= numberOfHeldFees) return new JBFee[](0);
        if (startIndex + count > numberOfHeldFees) count = numberOfHeldFees - startIndex;

        heldFees = new JBFee[](count);
        for (uint256 i; i < count;) {
            heldFees[i] = heldFeesOf[projectId][token][startIndex + i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns held fees back to a project's balance based on the specified incoming amount.
    /// @dev Partial replenishments use the raw floor calculation so repaying a dust amount cannot both credit the
    /// payer project and leave the fee project owed the 1-unit minimum fee.
    /// @param heldFeesOf The terminal's held-fee storage mapping.
    /// @param nextHeldFeeIndexOf The terminal's per-project/token next-index storage mapping.
    /// @param projectId The project to return held fees to.
    /// @param token The token that the held fees are in.
    /// @param amount The amount to base the calculation on.
    /// @param caller The address that triggered the return, forwarded into the `ReturnHeldFees` event.
    /// @return returnedFees The total fee amount that was returned to the project.
    function returnHeldFees(
        mapping(uint256 => mapping(address => JBFee[])) storage heldFeesOf,
        mapping(uint256 => mapping(address => uint256)) storage nextHeldFeeIndexOf,
        uint256 projectId,
        address token,
        uint256 amount,
        address caller
    )
        external
        returns (uint256 returnedFees)
    {
        uint256 startIndex = nextHeldFeeIndexOf[projectId][token];
        uint256 numberOfHeldFees = heldFeesOf[projectId][token].length;

        if (startIndex >= numberOfHeldFees) return 0;

        uint256 leftoverAmount = amount;
        uint256 newStartIndex = startIndex;

        for (uint256 i = startIndex; i < numberOfHeldFees;) {
            if (leftoverAmount == 0) break;

            JBFee memory heldFee = heldFeesOf[projectId][token][i];

            uint256 feeAmount = JBFees.standardFeeAmountFrom(heldFee.amount);
            uint256 amountPaidOut = heldFee.amount - feeAmount;

            if (leftoverAmount >= amountPaidOut) {
                unchecked {
                    leftoverAmount -= amountPaidOut;
                    returnedFees += feeAmount;
                }
                newStartIndex = i + 1;
            } else {
                feeAmount = JBFees.standardFeeAmountResultingIn(leftoverAmount);
                unchecked {
                    heldFeesOf[projectId][token][i].amount -= (leftoverAmount + feeAmount);
                    returnedFees += feeAmount;
                }
                leftoverAmount = 0;
            }
            unchecked {
                ++i;
            }
        }

        if (startIndex != newStartIndex) nextHeldFeeIndexOf[projectId][token] = newStartIndex;

        emit IJBFeeTerminal.ReturnHeldFees({
            projectId: projectId,
            token: token,
            amount: amount,
            returnedFees: returnedFees,
            leftoverAmount: leftoverAmount,
            caller: caller
        });
    }
}
