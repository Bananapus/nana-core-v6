// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBTokenAmount} from "./JBTokenAmount.sol";

/// @notice Context sent from the terminal to the ruleset's data hook upon cash out.
/// @custom:member terminal The terminal that is facilitating the cash out.
/// @custom:member holder The holder of the tokens to cash out.
/// @custom:member projectId The ID of the project cashing out tokens.
/// @custom:member rulesetId The ID of the ruleset the cash out is made during.
/// @custom:member cashOutCount The number of tokens to cash out, as a fixed point number with 18 decimals.
/// @custom:member totalSupply The total token supply to use for the calculation, as a fixed point number with 18
/// decimals.
/// @custom:member surplus The surplus amount used for the calculation, as a fixed point number with 18 decimals.
/// Includes the token of the surplus, the surplus value, the number of decimals
/// included, and the currency of the surplus.
/// @custom:member useTotalSurplus If true, use surplus across all of a project's terminals when calculating cash outs.
/// @custom:member cashOutTaxRate The cash out tax rate of the ruleset the cash out is made during, out of
/// `JBConstants.MAX_CASH_OUT_TAX_RATE`.
/// @custom:member beneficiaryIsFeeless Whether the cash out's beneficiary is a feeless address. Useful for data hooks
/// that charge their own fees — they can skip fees when value stays in the protocol (e.g. project-to-project
/// routing).
/// @custom:member metadata Extra data provided by the casher.
struct JBBeforeCashOutRecordedContext {
    address terminal;
    address holder;
    uint256 projectId;
    uint256 rulesetId;
    uint256 cashOutCount;
    uint256 totalSupply;
    JBTokenAmount surplus;
    bool useTotalSurplus;
    uint256 cashOutTaxRate;
    bool beneficiaryIsFeeless;
    bytes metadata;
}
