// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Context, ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBControlled} from "./abstract/JBControlled.sol";
import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBPriceFeed} from "./interfaces/IJBPriceFeed.sol";
import {IJBPrices} from "./interfaces/IJBPrices.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";

/// @notice Resolves protocol currency conversions from append-only project and default price feeds.
/// @dev Each feed prices one unit of `unitCurrency` in `pricingCurrency`. Feeds cannot be changed or removed once
/// added. Later feeds for the same exact pair act as backups when earlier feeds revert or return zero. Project-specific
/// feeds are checked before project ID 0 defaults, and inverse prices are derived at read time when only the opposite
/// direction is configured. If no configured feed returns a non-zero price, the read reverts instead of guessing.
contract JBPrices is JBControlled, JBPermissioned, ERC2771Context, Ownable, IJBPrices {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBPrices_PriceFeedAlreadyAdded(IJBPriceFeed feed);
    error JBPrices_PriceFeedNotFound(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency);
    error JBPrices_ZeroPriceFeed();
    error JBPrices_ZeroPricingCurrency(uint256 projectId, uint256 pricingCurrency);
    error JBPrices_ZeroUnitCurrency(uint256 projectId, uint256 unitCurrency);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID to store default values in.
    uint256 public constant override DEFAULT_PROJECT_ID = 0;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Price feeds available to each project for each exact currency pair.
    /// @dev The array is append-only. Index 0 remains the primary feed, and later indexes are backups.
    /// @custom:param projectId The ID of the project the feed applies to. Project ID 0 stores protocol defaults.
    /// @custom:param pricingCurrency The currency the feed's returned price is denominated in.
    /// @custom:param unitCurrency The currency whose unit is priced by the feed.
    mapping(
        uint256 projectId => mapping(uint256 pricingCurrency => mapping(uint256 unitCurrency => IJBPriceFeed[]))
    ) internal _priceFeedsFor;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @notice Initializes the price registry and its permissioned dependencies.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param owner The address that will own the contract.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBProjects projects,
        address owner,
        address trustedForwarder
    )
        JBControlled(directory)
        JBPermissioned(permissions)
        Ownable(owner)
        ERC2771Context(trustedForwarder)
    {
        PROJECTS = projects;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Adds an append-only price feed for a project's exact currency pair.
    /// @dev Project ID 0 stores protocol defaults and can only be configured by this contract's owner. Non-zero
    /// project IDs can only be configured by that project's controller. The feed is stored only for the exact
    /// `pricingCurrency`/`unitCurrency` direction; the opposite direction is derived by `pricePerUnitOf` when needed.
    /// @dev Later feeds for the same exact pair are backups. The existing feeds remain preferred, and this function
    /// rejects duplicate feed addresses for the exact pair.
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
        external
        override
    {
        // Project 0 configures defaults for every project; each other project delegates feed configuration to its
        // controller.
        projectId == DEFAULT_PROJECT_ID ? _checkOwner() : _onlyControllerOf(projectId);

        if (pricingCurrency == 0) {
            revert JBPrices_ZeroPricingCurrency({projectId: projectId, pricingCurrency: pricingCurrency});
        }

        if (unitCurrency == 0) revert JBPrices_ZeroUnitCurrency({projectId: projectId, unitCurrency: unitCurrency});

        if (feed == IJBPriceFeed(address(0))) revert JBPrices_ZeroPriceFeed();

        // Only exact-direction duplicates are rejected. Opposite-direction feeds can coexist and are used when deriving
        // inverse prices.
        _requireNewPriceFeed({
            projectId: projectId, pricingCurrency: pricingCurrency, unitCurrency: unitCurrency, feed: feed
        });

        // Keep existing feeds immutable: appending preserves the primary feed and adds this feed as the last fallback.
        _priceFeedsFor[projectId][pricingCurrency][unitCurrency].push(feed);

        emit AddPriceFeed({
            projectId: projectId,
            pricingCurrency: pricingCurrency,
            unitCurrency: unitCurrency,
            feed: feed,
            caller: _msgSender()
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

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
        override
        returns (IJBPriceFeed feed)
    {
        return _priceFeedsFor[projectId][pricingCurrency][unitCurrency][index];
    }

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
        override
        returns (uint256 count)
    {
        return _priceFeedsFor[projectId][pricingCurrency][unitCurrency].length;
    }

    /// @notice Returns the primary feed for an exact currency pair, or zero if none is configured.
    /// @dev This view does not apply inverse or project-default fallback lookup. Use `pricePerUnitOf` to resolve a
    /// usable price through the full backup path.
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
        override
        returns (IJBPriceFeed feed)
    {
        return _priceFeedsFor[projectId][pricingCurrency][unitCurrency].length == 0
            ? IJBPriceFeed(address(0))
            : _priceFeedsFor[projectId][pricingCurrency][unitCurrency][0];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the price of one `unitCurrency` unit denominated in `pricingCurrency`.
    /// @dev Lookup order is project direct feeds, project inverse feeds, default direct feeds, then default inverse
    /// feeds. Each feed list is tried in registration order, skipping feeds that revert or return zero. Reverts with
    /// `JBPrices_PriceFeedNotFound` if no configured feed in that lookup path returns a non-zero price.
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
        public
        view
        override
        returns (uint256 price)
    {
        // Same-currency conversions are always 1 in the requested fixed-point precision.
        if (pricingCurrency == unitCurrency) return 10 ** decimals;

        bool found;

        // Project-specific feeds take priority over defaults, including their configured backups.
        (price, found) = _pricePerUnitOf({
            projectId: projectId, pricingCurrency: pricingCurrency, unitCurrency: unitCurrency, decimals: decimals
        });
        if (found) return price;

        if (projectId != DEFAULT_PROJECT_ID) {
            // Project 0 feeds are the shared defaults. Avoid checking them twice when project ID 0 was requested.
            (price, found) = _pricePerUnitOf({
                projectId: DEFAULT_PROJECT_ID,
                pricingCurrency: pricingCurrency,
                unitCurrency: unitCurrency,
                decimals: decimals
            });
            if (found) return price;
        }

        revert JBPrices_PriceFeedNotFound({
            projectId: projectId, pricingCurrency: pricingCurrency, unitCurrency: unitCurrency
        });
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Reverts if `feed` is already configured for an exact currency pair.
    /// @param projectId The ID of the project whose pair should be checked.
    /// @param pricingCurrency The currency that the feed's returned price is denominated in.
    /// @param unitCurrency The currency whose unit is priced by the feed.
    /// @param feed The price feed to check.
    function _requireNewPriceFeed(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        IJBPriceFeed feed
    )
        internal
        view
    {
        IJBPriceFeed[] storage feeds = _priceFeedsFor[projectId][pricingCurrency][unitCurrency];
        uint256 numberOfFeeds = feeds.length;

        for (uint256 i; i < numberOfFeeds;) {
            if (feeds[i] == feed) revert JBPrices_PriceFeedAlreadyAdded({feed: feed});

            unchecked {
                ++i;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Returns the ERC-2771 context suffix length.
    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    /// @return contextSuffixLength The context suffix length.
    function _contextSuffixLength()
        internal
        view
        override(ERC2771Context, Context)
        returns (uint256 contextSuffixLength)
    {
        return super._contextSuffixLength();
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return data The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata data) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the first non-zero direct price from `feeds`.
    /// @dev Feeds are tried in registration order. A feed that reverts or returns zero is treated as unavailable.
    /// @param feeds The direct price feeds to try.
    /// @param decimals The number of decimals the returned fixed point price should use.
    /// @return price The first non-zero price returned by the feeds.
    /// @return found Whether a usable price was found.
    function _priceFrom(
        IJBPriceFeed[] storage feeds,
        uint256 decimals
    )
        internal
        view
        returns (uint256 price, bool found)
    {
        uint256 numberOfFeeds = feeds.length;
        for (uint256 i; i < numberOfFeeds;) {
            // Try each feed independently so one unavailable oracle does not block later backups.
            try feeds[i].currentUnitPrice(decimals) returns (uint256 returnedPrice) {
                if (returnedPrice != 0) return (returnedPrice, true);
            } catch {}

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the first non-zero inverse price from `feeds`.
    /// @dev Feeds are tried in registration order. A feed that reverts, returns zero, or inverts to zero at the
    /// requested precision is treated as unavailable.
    /// @param feeds The opposite-direction price feeds to invert.
    /// @param decimals The number of decimals the returned fixed point price should use.
    /// @return price The first non-zero inverse price returned by the feeds.
    /// @return found Whether a usable inverse price was found.
    function _priceFromInverse(
        IJBPriceFeed[] storage feeds,
        uint256 decimals
    )
        internal
        view
        returns (uint256 price, bool found)
    {
        uint256 numberOfFeeds = feeds.length;
        for (uint256 i; i < numberOfFeeds;) {
            // Each opposite-direction feed is optional; continue to backups if it cannot produce a usable price.
            try feeds[i].currentUnitPrice(decimals) returns (uint256 inversePrice) {
                if (inversePrice != 0) {
                    // Convert "unit per pricing" into "pricing per unit" using the same fixed-point precision.
                    uint256 invertedPrice = mulDiv({x: 10 ** decimals, y: 10 ** decimals, denominator: inversePrice});
                    if (invertedPrice != 0) return (invertedPrice, true);
                }
            } catch {}

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns a non-zero price from a project's direct or inverse feeds.
    /// @dev Direct feeds are preferred over inverse feeds for the same project and pair.
    /// @param projectId The ID of the project whose feeds should be checked.
    /// @param pricingCurrency The currency that the returned price should be denominated in.
    /// @param unitCurrency The currency whose unit is being priced.
    /// @param decimals The number of decimals the returned fixed point price should use.
    /// @return price The first usable direct or inverse price.
    /// @return found Whether a usable price was found.
    function _pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 decimals
    )
        internal
        view
        returns (uint256 price, bool found)
    {
        (price, found) =
            _priceFrom({feeds: _priceFeedsFor[projectId][pricingCurrency][unitCurrency], decimals: decimals});
        if (found) return (price, true);

        (price, found) =
            _priceFromInverse({feeds: _priceFeedsFor[projectId][unitCurrency][pricingCurrency], decimals: decimals});
    }
}
