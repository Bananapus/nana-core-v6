// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "./IJBTerminal.sol";
import {JBSplit} from "../structs/JBSplit.sol";

/// @notice A terminal that can send payouts.
interface IJBPayoutTerminal is IJBTerminal {
    /// @notice A payout to a split reverted, so the gross amount is held for the split until a retry succeeds.
    /// @param projectId The ID of the project the payout was for.
    /// @param token The token of the payout.
    /// @param split The split the amount is held for, with a resolved beneficiary. Hash it to read `heldPayoutOf`.
    /// @param amount The gross amount held.
    /// @param reason The revert reason.
    event HoldSplit(uint256 indexed projectId, address indexed token, JBSplit split, uint256 amount, bytes reason);

    /// @notice A held payout was retried and delivered.
    /// @param projectId The ID of the project the payout was for.
    /// @param token The token of the payout.
    /// @param split The split that was paid.
    /// @param amount The gross amount that was held.
    /// @param netAmount The amount the recipient received after fees.
    /// @param caller The address that retried the payout.
    event ProcessHeldSplit(
        uint256 indexed projectId,
        address indexed token,
        JBSplit split,
        uint256 amount,
        uint256 netAmount,
        address caller
    );

    /// @notice A payout was sent to a specific split.
    /// @param projectId The ID of the project the payout was for.
    /// @param rulesetId The ID of the ruleset during the payout.
    /// @param group The split group the payout was part of.
    /// @param split The split that received the payout.
    /// @param amount The gross amount of the payout.
    /// @param netAmount The net amount of the payout after fees.
    /// @param caller The address that called the payout function.
    event SendPayoutToSplit(
        uint256 indexed projectId,
        uint256 indexed rulesetId,
        uint256 indexed group,
        JBSplit split,
        uint256 amount,
        uint256 netAmount,
        address caller
    );

    /// @notice Payouts were sent from a project.
    /// @param rulesetId The ID of the ruleset during the payouts.
    /// @param rulesetCycleNumber The cycle number of the ruleset during the payouts.
    /// @param projectId The ID of the project that sent the payouts.
    /// @param projectOwner The owner of the project.
    /// @param amount The total amount of tokens paid out.
    /// @param amountPaidOut The amount paid out to splits.
    /// @param fee The total fee taken.
    /// @param netLeftoverPayoutAmount The net leftover amount sent to the project owner.
    /// @param caller The address that called the payout function.
    event SendPayouts(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address projectOwner,
        uint256 amount,
        uint256 amountPaidOut,
        uint256 fee,
        uint256 netLeftoverPayoutAmount,
        address caller
    );

    /// @notice Surplus allowance was used to send funds to a beneficiary.
    /// @param rulesetId The ID of the ruleset during the allowance usage.
    /// @param rulesetCycleNumber The cycle number of the ruleset.
    /// @param projectId The ID of the project using the allowance.
    /// @param beneficiary The address that received the funds.
    /// @param feeBeneficiary The address that received project tokens from fees.
    /// @param amount The gross amount of the allowance used.
    /// @param amountPaidOut The amount paid out before fees.
    /// @param netAmountPaidOut The net amount paid out to the beneficiary after fees.
    /// @param memo A memo associated with the allowance usage.
    /// @param caller The address that called the use allowance function.
    event UseAllowance(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address beneficiary,
        address feeBeneficiary,
        uint256 amount,
        uint256 amountPaidOut,
        uint256 netAmountPaidOut,
        string memo,
        address caller
    );

    /// @notice Sends a project's payouts to its payout split group according to its ruleset's payout limits.
    /// @param projectId The ID of the project to send payouts for.
    /// @param token The token to pay out.
    /// @param amount The total amount of tokens to pay out.
    /// @param currency The currency the amount is denominated in.
    /// @param minTokensPaidOut The minimum number of terminal tokens expected to be paid out.
    /// @return amountPaidOut The total amount paid out.
    function sendPayoutsOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        uint256 minTokensPaidOut
    )
        external
        returns (uint256 amountPaidOut);

    /// @notice The gross amount held for a split whose payout could not be delivered.
    /// @param projectId The ID of the project the payout is from.
    /// @param token The token of the payout.
    /// @param splitHash `keccak256(abi.encode(split))` of the held split, as emitted in `HoldSplit`.
    function heldPayoutOf(uint256 projectId, address token, bytes32 splitHash) external view returns (uint256);

    /// @notice Retries a held payout. Reverts if the recipient still cannot take it.
    /// @param projectId The ID of the project the payout is from.
    /// @param token The token of the payout.
    /// @param split The held split, as emitted in `HoldSplit`.
    function processHeldPayoutOf(uint256 projectId, address token, JBSplit calldata split) external;

    /// @notice Retries several held payouts of one project and token. Reverts if any recipient still cannot take it.
    /// @param projectId The ID of the project the payouts are from.
    /// @param token The token of the payouts.
    /// @param splits The held splits, as emitted in `HoldSplit`.
    function processHeldPayoutsOf(uint256 projectId, address token, JBSplit[] calldata splits) external;

    /// @notice Uses a project's surplus allowance to send funds to a beneficiary.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param token The token to pay out.
    /// @param amount The amount of the surplus allowance to use.
    /// @param currency The currency the amount is denominated in.
    /// @param minTokensPaidOut The minimum number of terminal tokens expected to be paid out.
    /// @param beneficiary The address to send the funds to.
    /// @param feeBeneficiary The address that will receive any project tokens minted from fees.
    /// @param memo A memo to pass along to the emitted event.
    /// @return netAmountPaidOut The net amount paid out to the beneficiary after fees.
    function useAllowanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        uint256 minTokensPaidOut,
        address payable beneficiary,
        address payable feeBeneficiary,
        string calldata memo
    )
        external
        returns (uint256 netAmountPaidOut);
}
