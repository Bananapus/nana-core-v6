// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPriceFeed} from "./IJBPriceFeed.sol";
import {IJBProjects} from "./IJBProjects.sol";

/// @notice Interface for the price feed registry. Resolves exchange rates between currencies via append-only price
/// feeds (typically Chainlink). Used when payout limits or surplus allowances are denominated in a different currency
/// than the token held in the terminal.
interface IJBPrices {
    /// @notice A price feed was added for a project's currency pair.
    /// @param projectId The ID of the project the price feed was added for.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @param feed The price feed that was added.
    /// @param caller The address that added the price feed.
    event AddPriceFeed(
        uint256 indexed projectId,
        uint256 indexed pricingCurrency,
        uint256 indexed unitCurrency,
        IJBPriceFeed feed,
        address caller
    );

    /// @notice The project ID used as a fallback when no project-specific price feed is set.
    function DEFAULT_PROJECT_ID() external view returns (uint256);

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice Returns the first price feed for a project's currency pair.
    /// @param projectId The ID of the project to get the price feed of.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @return The first price feed for the currency pair.
    function priceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency
    )
        external
        view
        returns (IJBPriceFeed);

    /// @notice Returns the price feed for a project's currency pair at the requested index.
    /// @param projectId The ID of the project to get the price feed of.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @param index The index of the feed to return.
    /// @return The price feed for the currency pair at `index`.
    function priceFeedAt(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 index
    )
        external
        view
        returns (IJBPriceFeed);

    /// @notice Returns the number of price feeds configured for a project's currency pair.
    /// @param projectId The ID of the project to get the price feed count of.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @return The number of price feeds for the currency pair.
    function priceFeedCountFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency
    )
        external
        view
        returns (uint256);

    /// @notice Returns the unit price for a currency pair.
    /// @param projectId The ID of the project to get the price for.
    /// @param pricingCurrency The currency the returned price is in terms of.
    /// @param unitCurrency The currency to price.
    /// @param decimals The number of decimals the returned price should use.
    /// @return The unit price.
    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 decimals
    )
        external
        view
        returns (uint256);

    /// @notice Adds a price feed for a project's currency pair.
    /// @param projectId The ID of the project to add the price feed for.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @param feed The price feed to add.
    function addPriceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        IJBPriceFeed feed
    )
        external;
}
