// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBBeforeCashOutRecordedContext} from "./../structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "./../structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "./../structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "./../structs/JBPayHookSpecification.sol";
import {JBRuleset} from "./../structs/JBRuleset.sol";

/// @notice Data hooks extend a terminal's pay/cash-out functionality by overriding the weight or memo, specifying
/// pay/cash-out hooks, or allowing addresses to mint a project's tokens on-demand.
/// @dev If a project's ruleset has `useDataHookForPay` or `useDataHookForCashOut` enabled, its `dataHook` is called by
/// the terminal upon payments/cash outs (respectively).
interface IJBRulesetDataHook is IERC165 {
    /// @notice Calculates data before a cash out is recorded in the terminal store.
    /// @param context The context passed to this data hook by the `cashOutTokensOf(...)` function.
    /// @return cashOutTaxRate The rate determining the reclaimable amount for a given surplus and token supply.
    /// @return effectiveCashOutCount The effective token count to use for pricing the cash out. The terminal still
    /// burns the caller-supplied token count.
    /// @return effectiveTotalSupply The effective total supply to use for both the proportional reclaim and tax
    /// calculations. For omnichain projects, this should include tokens on other chains so the tax cannot be bypassed.
    /// @return effectiveTaxSurplus The global surplus across all chains, used for the proportional reclaim base.
    /// When > 0, the proportional base uses `taxSurplus / totalSupply` instead of `surplus / totalSupply`,
    /// capped at local surplus. Set to 0 to use local surplus (default single-chain behavior).
    /// @return hookSpecifications The amount and data to send to cash out hooks instead of returning to the
    /// beneficiary.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        returns (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveTaxSurplus,
            JBCashOutHookSpecification[] memory hookSpecifications
        );

    /// @notice Calculates data before a payment is recorded in the terminal store.
    /// @param context The context passed to this data hook by the `pay(...)` function.
    /// @return weight The new weight to use, overriding the ruleset's weight.
    /// @return hookSpecifications The amount and data to send to pay hooks instead of adding to the terminal's balance.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications);

    /// @notice Returns whether an address has permission to mint a project's tokens on-demand.
    /// @param projectId The ID of the project whose token can be minted.
    /// @param ruleset The ruleset to check the token minting permission of.
    /// @param addr The address to check the token minting permission of.
    /// @return flag A flag indicating whether the address has permission.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset memory ruleset,
        address addr
    )
        external
        view
        returns (bool flag);
}
