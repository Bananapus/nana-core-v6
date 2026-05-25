// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPrices} from "../../../../src/JBPrices.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPriceFeed} from "../../../../src/interfaces/IJBPriceFeed.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBPricesSetup} from "./JBPricesSetup.sol";
import {MockPriceFeed} from "../../../mock/MockPriceFeed.sol";

contract TestPricePerUnitOf_Local is JBPricesSetup {
    uint256 DEFAULT_PROJECT_ID = 0;
    uint256 _projectId = 1;
    uint256 _defaultDirectPrice = 1_000_000_000;
    uint256 _directPrice = 2_000_000_000;
    uint256 _inversePrice = 1e18;
    uint256 _directDecimals = 18;
    uint256 _inverseDecimals = 6;
    uint256 _pricingCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
    uint256 _unitCurrency = uint32(uint160(makeAddr("someToken")));

    function setUp() public {
        super.pricesSetup();
    }

    function _addFeed(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed) internal {
        if (projectId == DEFAULT_PROJECT_ID) {
            vm.prank(_owner);
        } else {
            mockExpect(
                address(directory), abi.encodeCall(IJBDirectory.controllerOf, (projectId)), abi.encode(address(this))
            );
        }

        _prices.addPriceFeedFor(projectId, pricingCurrency, unitCurrency, feed);
    }

    modifier givenDirectFeedExists() {
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new MockPriceFeed(_directPrice, _inverseDecimals));
        _;
    }

    modifier givenIndirectFeedExists() {
        _addFeed(_projectId, _unitCurrency, _pricingCurrency, new MockPriceFeed(_inversePrice, _directDecimals));
        _;
    }

    modifier givenOnlyDefaultDirectFeedExists() {
        IJBPriceFeed feed = new MockPriceFeed(_defaultDirectPrice, _inverseDecimals);
        _addFeed(DEFAULT_PROJECT_ID, _pricingCurrency, _unitCurrency, feed);

        assertEq(address(_prices.priceFeedFor(DEFAULT_PROJECT_ID, _pricingCurrency, _unitCurrency)), address(feed));
        _;
    }

    function test_WhenPricingCurrencyIsTheSameAsUnitCurrency() external view {
        uint256 price = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _pricingCurrency, 18);
        assertEq(price, 1e18);
    }

    function test_WhenPriceFeedExistsForProjectIdAndPricingCurrencyToUnitCurrency() external givenDirectFeedExists {
        uint256 pricesPrice = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, 6);
        assertEq(pricesPrice, _directPrice);
    }

    function test_WhenInversePriceFeedExistsForProjectIdAndUnitCurrencyToPricingCurrency()
        external
        givenIndirectFeedExists
    {
        uint256 inversePrice = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, 18);
        assertEq(inversePrice, _inversePrice);
    }

    function test_WhenProjectIdIsNotTheDEFAULT_PROJECT_IDAndNoDirectOrInversePriceFeedIsFound()
        external
        givenOnlyDefaultDirectFeedExists
    {
        uint256 defaultPrice = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, 6);
        assertEq(defaultPrice, _defaultDirectPrice);
    }

    function test_WhenNoPriceFeedIsFoundOrExistsIncludingDefaultCase() external {
        vm.expectPartialRevert(JBPrices.JBPrices_PriceFeedNotFound.selector);
        _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, 6);
    }

    function test_WhenDirectPriceFeedReturnsZero() external {
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new MockPriceFeed(0, _inverseDecimals));

        vm.expectPartialRevert(JBPrices.JBPrices_PriceFeedNotFound.selector);
        _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, _inverseDecimals);
    }

    function test_WhenInversePriceFeedReturnsZero() external {
        _addFeed(_projectId, _unitCurrency, _pricingCurrency, new MockPriceFeed(0, _directDecimals));

        vm.expectPartialRevert(JBPrices.JBPrices_PriceFeedNotFound.selector);
        _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, _directDecimals);
    }

    function test_WhenDirectPriceFeedReturnsZero_UsesBackup() external {
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new MockPriceFeed(0, _inverseDecimals));
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new MockPriceFeed(_directPrice, _inverseDecimals));

        uint256 pricesPrice = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, _inverseDecimals);
        assertEq(pricesPrice, _directPrice);
    }

    function test_WhenDirectPriceFeedReverts_UsesBackup() external {
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new RevertingPriceFeed());
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new MockPriceFeed(_directPrice, _inverseDecimals));

        uint256 pricesPrice = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, _inverseDecimals);
        assertEq(pricesPrice, _directPrice);
    }

    function test_WhenProjectPriceFeedFails_UsesDefaultFeed() external {
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new RevertingPriceFeed());
        _addFeed(
            DEFAULT_PROJECT_ID,
            _pricingCurrency,
            _unitCurrency,
            new MockPriceFeed(_defaultDirectPrice, _inverseDecimals)
        );

        uint256 pricesPrice = _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, _inverseDecimals);
        assertEq(pricesPrice, _defaultDirectPrice);
    }

    function test_WhenEveryConfiguredPriceFeedFails_Reverts() external {
        _addFeed(_projectId, _pricingCurrency, _unitCurrency, new RevertingPriceFeed());
        _addFeed(DEFAULT_PROJECT_ID, _pricingCurrency, _unitCurrency, new MockPriceFeed(0, _inverseDecimals));

        vm.expectPartialRevert(JBPrices.JBPrices_PriceFeedNotFound.selector);
        _prices.pricePerUnitOf(_projectId, _pricingCurrency, _unitCurrency, _inverseDecimals);
    }
}

contract RevertingPriceFeed is IJBPriceFeed {
    function currentUnitPrice(uint256) external pure returns (uint256) {
        revert("NO_PRICE");
    }
}
