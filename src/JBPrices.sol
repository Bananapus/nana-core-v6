// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context, Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBControlled} from "./abstract/JBControlled.sol";
import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBPriceFeed} from "./interfaces/IJBPriceFeed.sol";
import {IJBPrices} from "./interfaces/IJBPrices.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";

/// @notice Provides currency conversion for the protocol. When a project's payout limits or surplus allowances are
/// denominated in a currency different from the token held in its terminal (e.g. USD limits with ETH held), this
/// contract resolves the exchange rate via registered price feeds (typically Chainlink oracles).
/// @dev Price feeds are immutable once set — they cannot be replaced or removed. This protects against oracle
/// manipulation via admin-key attacks. If a feed is misconfigured, operations using that pair will revert (DoS, not
/// fund loss). The inverse of any registered feed is auto-calculated. Projects can have their own feeds; project ID 0
/// holds protocol-wide defaults.
contract JBPrices is JBControlled, JBPermissioned, ERC2771Context, Ownable, IJBPrices {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBPrices_PriceFeedAlreadyExists(IJBPriceFeed feed);
    error JBPrices_PriceFeedNotFound(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency);
    error JBPrices_ZeroPrice(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed);
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
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The available price feeds.
    /// @dev The feed returns the `pricingCurrency` cost for one unit of the `unitCurrency`.
    /// @custom:param projectId The ID of the project the feed applies to. Feeds stored in ID 0 are used by default for
    /// all projects.
    /// @custom:param pricingCurrency The currency the feed's resulting price is in terms of.
    /// @custom:param unitCurrency The currency the feed prices.
    mapping(uint256 projectId => mapping(uint256 pricingCurrency => mapping(uint256 unitCurrency => IJBPriceFeed)))
        public
        override priceFeedFor;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

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

    /// @notice Register a price feed that provides the exchange rate between two currencies. For example, registering
    /// an ETH/USD feed allows payout limits denominated in USD to be enforced against ETH balances.
    /// @dev Price feeds are immutable — once set for a currency pair, they cannot be replaced or removed. This
    /// prevents
    /// admin-key oracle manipulation. The inverse rate is auto-calculated, so registering A→B also provides B→A.
    /// @dev Pass `projectId` = 0 to set a protocol-wide default (owner only). Non-zero project IDs require controller
    /// authorization. A default feed for a pair blocks per-project overrides for that same pair.
    /// @param projectId The ID of the project to add a feed for. Pass 0 for a protocol-wide default.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @param feed The address of the price feed to add.
    function addPriceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        IJBPriceFeed feed
    )
        external
        override
    {
        // Ensure default price feeds can only be set by this contract's owner, and that other `projectId`s can only be
        // set by the controller
        projectId == DEFAULT_PROJECT_ID ? _checkOwner() : _onlyControllerOf(projectId);

        // Make sure the pricing currency isn't 0.
        if (pricingCurrency == 0) {
            revert JBPrices_ZeroPricingCurrency({projectId: projectId, pricingCurrency: pricingCurrency});
        }

        // Make sure the unit currency isn't 0.
        if (unitCurrency == 0) revert JBPrices_ZeroUnitCurrency({projectId: projectId, unitCurrency: unitCurrency});

        // Make sure there isn't already a default price feed for the pair or its inverse.
        if (
            priceFeedFor[DEFAULT_PROJECT_ID][pricingCurrency][unitCurrency] != IJBPriceFeed(address(0))
                || priceFeedFor[DEFAULT_PROJECT_ID][unitCurrency][pricingCurrency] != IJBPriceFeed(address(0))
        ) {
            revert JBPrices_PriceFeedAlreadyExists({
                feed: priceFeedFor[DEFAULT_PROJECT_ID][pricingCurrency][unitCurrency] != IJBPriceFeed(address(0))
                    ? priceFeedFor[DEFAULT_PROJECT_ID][pricingCurrency][unitCurrency]
                    : priceFeedFor[DEFAULT_PROJECT_ID][unitCurrency][pricingCurrency]
            });
        }

        // Make sure this project doesn't already have a price feed for the pair or its inverse.
        if (
            priceFeedFor[projectId][pricingCurrency][unitCurrency] != IJBPriceFeed(address(0))
                || priceFeedFor[projectId][unitCurrency][pricingCurrency] != IJBPriceFeed(address(0))
        ) {
            revert JBPrices_PriceFeedAlreadyExists({
                feed: priceFeedFor[projectId][pricingCurrency][unitCurrency] != IJBPriceFeed(address(0))
                    ? priceFeedFor[projectId][pricingCurrency][unitCurrency]
                    : priceFeedFor[projectId][unitCurrency][pricingCurrency]
            });
        }

        // Price feed immutability is by design to prevent admin-key attacks on price oracles.
        // If a feed fails, operations using that currency pair revert (DoS but not fund loss). Projects can use
        // alternative currency pairs. A default feed for a currency pair prevents per-project overrides to ensure
        // price consistency; projects should use unused currency IDs for custom pricing.
        // Store the feed.
        priceFeedFor[projectId][pricingCurrency][unitCurrency] = feed;

        emit AddPriceFeed({
            projectId: projectId,
            pricingCurrency: pricingCurrency,
            unitCurrency: unitCurrency,
            feed: feed,
            caller: _msgSender()
        });
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Convert between currencies — returns how much of `pricingCurrency` one unit of `unitCurrency` is
    /// worth.
    /// For example, `pricePerUnitOf(id, USD, ETH, 18)` returns the USD price of 1 ETH with 18 decimals.
    /// @dev Lookup order: project-specific feed → inverse of project feed → default feed (project 0) → inverse of
    /// default. Reverts with `JBPrices_PriceFeedNotFound` if no feed exists in any direction.
    /// @param projectId The ID of the project to check the feed for. Falls back to project 0 (protocol defaults).
    /// @param pricingCurrency The currency the result is denominated in.
    /// @param unitCurrency The currency to price.
    /// @param decimals The number of decimals the returned fixed point price should include.
    /// @return The `pricingCurrency` price of 1 `unitCurrency`, as a fixed point number with the specified number of
    /// decimals.
    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 decimals
    )
        public
        view
        override
        returns (uint256)
    {
        // If the `pricingCurrency` is the `unitCurrency`, return 1 since they have the same price. Include the
        // desired number of decimals.
        if (pricingCurrency == unitCurrency) return 10 ** decimals;

        // Get a reference to the price feed.
        IJBPriceFeed feed = priceFeedFor[projectId][pricingCurrency][unitCurrency];

        // If the feed exists, return its non-zero price.
        if (feed != IJBPriceFeed(address(0))) {
            uint256 price = feed.currentUnitPrice(decimals);
            if (price == 0) {
                revert JBPrices_ZeroPrice({
                    projectId: projectId, pricingCurrency: pricingCurrency, unitCurrency: unitCurrency, feed: feed
                });
            }
            return price;
        }

        // Try getting the inverse feed.
        feed = priceFeedFor[projectId][unitCurrency][pricingCurrency];

        // If it exists, return the inverse of its price.
        // @dev The inverse calculation `(10^d * 10^d) / price` has acceptable precision when the feed price
        // is in the range of ~1e9 to ~1e27 (for 18 decimals). Extreme prices outside this range may lose
        // significant precision due to fixed-point division truncation.
        if (feed != IJBPriceFeed(address(0))) {
            uint256 inversePrice = feed.currentUnitPrice(decimals);
            if (inversePrice == 0) {
                revert JBPrices_ZeroPrice({
                    projectId: projectId, pricingCurrency: unitCurrency, unitCurrency: pricingCurrency, feed: feed
                });
            }
            return mulDiv({x: 10 ** decimals, y: 10 ** decimals, denominator: inversePrice});
        }

        // Check for a default feed (project ID 0) if not found.
        if (projectId != DEFAULT_PROJECT_ID) {
            return pricePerUnitOf({
                projectId: DEFAULT_PROJECT_ID,
                pricingCurrency: pricingCurrency,
                unitCurrency: unitCurrency,
                decimals: decimals
            });
        }

        // No price feed available, revert.
        revert JBPrices_PriceFeedNotFound({
            projectId: projectId, pricingCurrency: pricingCurrency, unitCurrency: unitCurrency
        });
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }
}
