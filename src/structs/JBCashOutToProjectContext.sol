// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "../interfaces/IJBTerminal.sol";

/// @notice Routing context for a cashout-as-payment-to-project call.
/// @dev The caller declares where the cashout reclaim is sent (`destinationTerminal`, e.g. a router/swap terminal)
/// and what token they expect to physically land back on this terminal under the destination project's name
/// (`tokenForBeneficiaryProject`, e.g. USDC after an ETH→USDC swap). The terminal verifies delivery via a
/// `STORE.balanceOf` delta on `(this, beneficiaryProjectId, tokenForBeneficiaryProject)` before crediting
/// `_feeFreeSurplusOf` and skipping the source-side cashout fee. If less than `minDeliveredToB` lands, the
/// entire call reverts.
/// @custom:member destinationTerminal Terminal that initially receives the cashout reclaim. If zero, defaults
/// to `DIRECTORY.primaryTerminalOf(beneficiaryProjectId, tokenToReclaim)`.
/// @custom:member tokenForBeneficiaryProject The token whose balance on `(this, beneficiaryProjectId)` is
/// measured before/after the routing to determine "did the funds come back to B on this terminal."
/// @custom:member minDeliveredToB Minimum acceptable balance delta on `(this, beneficiaryProjectId,
/// tokenForBeneficiaryProject)`. Slippage on the routing step.
struct JBCashOutToProjectContext {
    IJBTerminal destinationTerminal;
    address tokenForBeneficiaryProject;
    uint256 minDeliveredToB;
}
