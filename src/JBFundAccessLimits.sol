// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBControlled} from "./abstract/JBControlled.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "./interfaces/IJBFundAccessLimits.sol";
import {JBCurrencyAmount} from "./structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "./structs/JBFundAccessLimitGroup.sol";

/// @notice Controls how much a project can withdraw from its terminals each funding cycle. Two types of limits:
/// **Payout limits** cap how much can be distributed to splits and the project owner. **Surplus allowances** cap how
/// much the project owner can pull from the surplus (funds above payout limits). Both reset each ruleset cycle.
/// @dev Limits are denominated in a currency (which may differ from the held token) and resolved at withdrawal time
/// via `JBPrices`. An empty `fundAccessLimitGroups` array means zero access (not unlimited) — use `type(uint224).max`
/// for unlimited.
contract JBFundAccessLimits is JBControlled, IJBFundAccessLimits {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering();
    error JBFundAccessLimits_InvalidSurplusAllowanceCurrencyOrdering();

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice An array of packed payout limits for a given project, ruleset, terminal, and token.
    /// @dev bits 0-223: The maximum amount (in a specific currency) of the terminal's `token`s that the project can pay
    /// out during the ruleset.
    /// @dev bits 224-255: The currency that the payout limit is denominated in. If this currency is different from the
    /// terminal's `token`, the payout limit will vary depending on their exchange rate.
    /// @custom:param projectId The project's ID.
    /// @custom:param rulesetId The ruleset's ID.
    /// @custom:param terminal The terminal to get the payout limits of.
    /// @custom:param token The token to get the payout limits of.
    mapping(
        uint256 projectId
            => mapping(uint256 rulesetId => mapping(address terminal => mapping(address token => uint256[])))
    ) internal _packedPayoutLimitsDataOf;

    /// @notice An array of packed surplus allowances for a given project, ruleset, terminal, and token.
    /// @dev bits 0-223: The maximum amount (in a specific currency) of the terminal's `token`s that the project can
    /// access from its surplus during the ruleset.
    /// @dev bits 224-255: The currency that the surplus allowance is denominated in. If this currency is different from
    /// the terminal's `token`, the surplus allowance will vary depending on their exchange rate.
    /// @custom:param projectId The project's ID.
    /// @custom:param rulesetId The ruleset's ID.
    /// @custom:param terminal The terminal to get the surplus allowances of.
    /// @custom:param token The token to get the surplus allowances of.
    mapping(
        uint256 projectId
            => mapping(uint256 rulesetId => mapping(address terminal => mapping(address token => uint256[])))
    ) internal _packedSurplusAllowancesDataOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing the terminals and the controller used by each project.
    // solhint-disable-next-line no-empty-blocks
    constructor(IJBDirectory directory) JBControlled(directory) {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Configure how much a project can withdraw from each of its terminals during a ruleset. Payout limits
    /// cap how much can be distributed to splits/owner; surplus allowances cap how much extra the owner can pull from
    /// surplus. Both reset each funding cycle.
    /// @dev Only a project's controller can set fund access limits (called during `queueRulesetsOf`).
    /// @dev Limits within each group must be sorted by currency in strictly increasing order to prevent duplicates.
    /// @param projectId The ID of the project whose fund access limits are to set.
    /// @param rulesetId The ID of the ruleset that the limits will apply within.
    /// @param fundAccessLimitGroups An array containing payout limits and surplus allowances for each payment terminal.
    /// Amounts are fixed point numbers using the same number of decimals as the associated terminal.
    function setFundAccessLimitsFor(
        uint256 projectId,
        uint256 rulesetId,
        JBFundAccessLimitGroup[] calldata fundAccessLimitGroups
    )
        external
        override
        onlyControllerOf(projectId)
    {
        // Save the number of fund access limit groups.
        uint256 numberOfFundAccessLimitGroups = fundAccessLimitGroups.length;

        // Set payout limits if there are any.
        for (uint256 i; i < numberOfFundAccessLimitGroups;) {
            // Set the limits being iterated on.
            JBFundAccessLimitGroup calldata fundAccessLimitGroup = fundAccessLimitGroups[i];

            // Keep a reference to the number of payout limits.
            uint256 numberOfPayoutLimits = fundAccessLimitGroup.payoutLimits.length;

            // Iterate through each payout limit to validate and store them.
            for (uint256 j; j < numberOfPayoutLimits;) {
                // Set the payout limit being iterated on.
                JBCurrencyAmount calldata payoutLimit = fundAccessLimitGroup.payoutLimits[j];

                // Make sure the payout limits are passed in strictly increasing order (sorted by currency) to prevent
                // duplicates.
                if (j != 0 && payoutLimit.currency <= fundAccessLimitGroup.payoutLimits[j - 1].currency) {
                    revert JBFundAccessLimits_InvalidPayoutLimitCurrencyOrdering();
                }

                // Set the payout limit if there is one.
                if (payoutLimit.amount > 0) {
                    _packedPayoutLimitsDataOf[projectId][rulesetId][fundAccessLimitGroup.terminal][fundAccessLimitGroup.token].push(
                        uint256(payoutLimit.amount) | (uint256(payoutLimit.currency) << 224)
                    );
                }
                unchecked {
                    ++j;
                }
            }

            // Keep a reference to the number of surplus allowances.
            uint256 numberOfSurplusAllowances = fundAccessLimitGroup.surplusAllowances.length;

            // Iterate through each surplus allowance to validate and store them.
            for (uint256 j; j < numberOfSurplusAllowances;) {
                // Set the surplus allowance being iterated on.
                JBCurrencyAmount calldata surplusAllowance = fundAccessLimitGroup.surplusAllowances[j];

                // Make sure the surplus allowances are passed in strictly increasing order (sorted by currency) to
                // prevent duplicates.
                if (j != 0 && surplusAllowance.currency <= fundAccessLimitGroup.surplusAllowances[j - 1].currency) {
                    revert JBFundAccessLimits_InvalidSurplusAllowanceCurrencyOrdering();
                }

                // Set the surplus allowance if there is one.
                if (surplusAllowance.amount > 0) {
                    _packedSurplusAllowancesDataOf[projectId][rulesetId][fundAccessLimitGroup.terminal][fundAccessLimitGroup.token].push(
                        uint256(surplusAllowance.amount) | (uint256(surplusAllowance.currency) << 224)
                    );
                }
                unchecked {
                    ++j;
                }
            }

            emit SetFundAccessLimits({
                rulesetId: rulesetId,
                projectId: projectId,
                fundAccessLimitGroup: fundAccessLimitGroup,
                caller: msg.sender
            });
            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Look up how much a project can distribute (via `sendPayoutsOf`) from a specific terminal and token,
    /// denominated in a specific currency. Returns 0 if no limit is configured for that currency.
    /// @dev The fixed point return amount uses the same number of decimals as the terminal.
    /// @param projectId The project's ID.
    /// @param rulesetId The ruleset's ID.
    /// @param terminal The terminal the payout limit applies to.
    /// @param token The token the payout limit applies to.
    /// @param currency The currency the payout limit is denominated in.
    /// @return payoutLimit The payout limit, as a fixed point number with the same number of decimals as the
    /// terminal.
    function payoutLimitOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 payoutLimit)
    {
        // Get a reference to the packed payout limits.
        uint256[] memory data = _packedPayoutLimitsDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of payout limits.
        uint256 numberOfData = data.length;

        // Iterate through the stored packed values and return the value of the matching currency.
        for (uint256 i; i < numberOfData;) {
            // Set the data being iterated on.
            uint256 packedPayoutLimitData = data[i];

            // If the currencies match, return the value.
            if (currency == packedPayoutLimitData >> 224) {
                // forge-lint: disable-next-line(unsafe-typecast)
                return uint256(uint224(packedPayoutLimitData));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get all payout limits for a project's terminal and token during a ruleset. A project can have multiple
    /// payout limits denominated in different currencies (e.g. 10,000 USD + 5 ETH). Each is enforced independently.
    /// @dev The fixed point `amount`s returned use the same number of decimals as the terminal.
    /// @param projectId The project's ID.
    /// @param rulesetId The ruleset's ID.
    /// @param terminal The terminal the payout limits apply to.
    /// @param token The token the payout limits apply to.
    /// @return payoutLimits The payout limits.
    function payoutLimitsOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token
    )
        external
        view
        override
        returns (JBCurrencyAmount[] memory payoutLimits)
    {
        // Get a reference to the packed payout limits.
        uint256[] memory packedPayoutLimitsData = _packedPayoutLimitsDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of payout limits.
        uint256 numberOfData = packedPayoutLimitsData.length;

        // Initialize the return array.
        payoutLimits = new JBCurrencyAmount[](numberOfData);

        // Iterate through the packed values and format the returned value.
        for (uint256 i; i < numberOfData;) {
            // Set the data being iterated on.
            uint256 packedPayoutLimitData = packedPayoutLimitsData[i];

            // The limit amount is in bits 0-223. The currency is in bits 224-255.
            // forge-lint: disable-next-line(unsafe-typecast)
            payoutLimits[i] = JBCurrencyAmount({
                // forge-lint: disable-next-line(unsafe-typecast)
                currency: uint32(packedPayoutLimitData >> 224),
                // forge-lint: disable-next-line(unsafe-typecast)
                amount: uint224(packedPayoutLimitData)
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Look up how much a project's owner can withdraw from the surplus (via `useAllowanceOf`) from a specific
    /// terminal and token, denominated in a specific currency. Returns 0 if no allowance is configured.
    /// @dev The fixed point return amount uses the same number of decimals as the terminal.
    /// @param projectId The project's ID.
    /// @param rulesetId The ruleset's ID.
    /// @param terminal The terminal the surplus allowance applies to.
    /// @param token The token the surplus allowance applies to.
    /// @param currency The currency that the surplus allowance is denominated in.
    /// @return surplusAllowance The surplus allowance, as a fixed point number with the same number of decimals as the
    /// terminal.
    function surplusAllowanceOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 surplusAllowance)
    {
        // Get a reference to the packed surplus allowances.
        uint256[] memory packedSurplusAllowancesData =
            _packedSurplusAllowancesDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of surplus allowances.
        uint256 numberOfData = packedSurplusAllowancesData.length;

        // Iterate through the stored packed values and format the returned value.
        for (uint256 i; i < numberOfData;) {
            // Set the data being iterated on.
            uint256 packedSurplusAllowanceData = packedSurplusAllowancesData[i];

            // If the currencies match, return the value.
            if (currency == packedSurplusAllowanceData >> 224) {
                // forge-lint: disable-next-line(unsafe-typecast)
                return uint256(uint224(packedSurplusAllowanceData));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get all surplus allowances for a project's terminal and token during a ruleset. Like payout limits, a
    /// project can have multiple surplus allowances in different currencies, each enforced independently.
    /// @dev The fixed point `amount`s returned use the same number of decimals as the terminal.
    /// @param projectId The project's ID.
    /// @param rulesetId The ruleset's ID.
    /// @param terminal The terminal the surplus allowances apply to.
    /// @param token The token the surplus allowances apply to.
    /// @return surplusAllowances The surplus allowances.
    function surplusAllowancesOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token
    )
        external
        view
        override
        returns (JBCurrencyAmount[] memory surplusAllowances)
    {
        // Get a reference to the packed surplus allowances.
        uint256[] memory packedSurplusAllowancesData =
            _packedSurplusAllowancesDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of surplus allowances.
        uint256 numberOfData = packedSurplusAllowancesData.length;

        // Initialize the return array.
        surplusAllowances = new JBCurrencyAmount[](numberOfData);

        // Iterate through the stored packed values and format the returned value.
        for (uint256 i; i < numberOfData;) {
            // Set the data being iterated on.
            uint256 packedSurplusAllowanceData = packedSurplusAllowancesData[i];

            // The limit is in bits 0-223. The currency is in bits 224-255.
            // forge-lint: disable-next-line(unsafe-typecast)
            surplusAllowances[i] = JBCurrencyAmount({
                // forge-lint: disable-next-line(unsafe-typecast)
                currency: uint32(packedSurplusAllowanceData >> 224),
                // forge-lint: disable-next-line(unsafe-typecast)
                amount: uint224(packedSurplusAllowanceData)
            });
            unchecked {
                ++i;
            }
        }
    }
}
