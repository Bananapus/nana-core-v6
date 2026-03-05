// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPriceFeed} from "./IJBPriceFeed.sol";
import {IJBProjects} from "./IJBProjects.sol";

/// @notice Manages price feeds and provides unit prices for currency conversions.
interface IJBPrices {
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

    /// @notice Returns the price feed for a project's currency pair.
    /// @param projectId The ID of the project to get the price feed of.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency being priced by the feed.
    /// @return The price feed for the currency pair.
    function priceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency
    )
        external
        view
        returns (IJBPriceFeed);

    /// @notice Returns the unit price for a currency pair.
    /// @param projectId The ID of the project to get the price for.
    /// @param pricingCurrency The currency the returned price is in terms of.
    /// @param unitCurrency The currency being priced.
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
    /// @param unitCurrency The currency being priced by the feed.
    /// @param feed The price feed to add.
    function addPriceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        IJBPriceFeed feed
    )
        external;
}
