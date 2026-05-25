// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPriceFeed} from "./IJBPriceFeed.sol";
import {IJBProjects} from "./IJBProjects.sol";

/// @notice Resolves protocol currency conversions from append-only project and default price feeds.
interface IJBPrices {
    /// @notice Emitted when a price feed is added for an exact currency pair.
    /// @param projectId The ID of the project the price feed was added for. Project ID 0 stores protocol defaults.
    /// @param pricingCurrency The currency that the feed's returned price is denominated in.
    /// @param unitCurrency The currency whose unit is priced by the feed.
    /// @param feed The price feed that was added.
    /// @param caller The address that added the price feed.
    event AddPriceFeed(
        uint256 indexed projectId,
        uint256 indexed pricingCurrency,
        uint256 indexed unitCurrency,
        IJBPriceFeed feed,
        address caller
    );

    /// @notice The project ID used to store protocol default price feeds.
    /// @return projectId The project ID used to store protocol defaults.
    function DEFAULT_PROJECT_ID() external view returns (uint256 projectId);

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    /// @return projects The project NFT contract.
    function PROJECTS() external view returns (IJBProjects projects);

    /// @notice Returns the feed stored at an exact pair's index.
    /// @dev This view does not apply inverse or project-default fallback lookup. It reverts with Solidity's default
    /// array bounds check if `index` is not configured.
    /// @param projectId The ID of the project whose feed should be returned.
    /// @param pricingCurrency The currency that the feed's returned price is denominated in.
    /// @param unitCurrency The currency whose unit is priced by the feed.
    /// @param index The index of the feed to return.
    /// @return feed The configured price feed for the exact pair at `index`.
    function priceFeedAt(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 index
    )
        external
        view
        returns (IJBPriceFeed);

    /// @notice Returns the number of feeds configured for an exact currency pair.
    /// @dev This count does not include feeds configured for the inverse direction or project ID 0 defaults.
    /// @param projectId The ID of the project whose feed count should be returned.
    /// @param pricingCurrency The currency that the feeds' returned prices are denominated in.
    /// @param unitCurrency The currency whose unit is priced by the feeds.
    /// @return count The number of configured price feeds for the exact pair.
    function priceFeedCountFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency
    )
        external
        view
        returns (uint256 count);

    /// @notice Returns the primary feed for an exact currency pair, or zero if none is configured.
    /// @dev This view only returns the stored primary feed address. It does not call the feed, skip unavailable feeds,
    /// derive inverse feeds, or fall back to project ID 0 defaults.
    /// @param projectId The ID of the project whose primary feed should be returned.
    /// @param pricingCurrency The currency that the feed's returned price is denominated in.
    /// @param unitCurrency The currency whose unit is priced by the feed.
    /// @return feed The first configured price feed for the exact pair, or the zero address if none exists.
    function priceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency
    )
        external
        view
        returns (IJBPriceFeed feed);

    /// @notice Returns the price of one `unitCurrency` unit denominated in `pricingCurrency`.
    /// @dev Lookup order is project direct feeds, project inverse feeds, default direct feeds, then default inverse
    /// feeds. Each feed list is tried in registration order, skipping feeds that revert or return zero.
    /// @param projectId The ID of the project to check first. Project ID 0 feeds are used as defaults.
    /// @param pricingCurrency The currency that the returned price is denominated in.
    /// @param unitCurrency The currency whose unit is being priced.
    /// @param decimals The number of decimals the returned fixed point price should use.
    /// @return price The `pricingCurrency` price of one `unitCurrency`, using `decimals` fixed point precision.
    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 decimals
    )
        external
        view
        returns (uint256 price);

    /// @notice Adds an append-only price feed for a project's exact currency pair.
    /// @dev Project ID 0 stores protocol defaults and can only be configured by this contract's owner. Non-zero
    /// project IDs can only be configured by that project's controller.
    /// @param projectId The ID of the project to add the feed for, or 0 to add a protocol default.
    /// @param pricingCurrency The currency that the feed's returned price is denominated in.
    /// @param unitCurrency The currency whose unit is priced by the feed.
    /// @param feed The price feed to add.
    function addPriceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        IJBPriceFeed feed
    )
        external;
}
