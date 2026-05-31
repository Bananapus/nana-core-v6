// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBPriceFeed} from "../../../../src/interfaces/IJBPriceFeed.sol";
import {JBTriangularPriceFeed} from "../../../../src/periphery/JBTriangularPriceFeed.sol";
import {MockPriceFeed} from "../../../mock/MockPriceFeed.sol";

/// @notice Unit tests for the composite (triangulating) price feed.
contract TestTriangularPriceFeed is Test {
    /// @dev A leg that always reverts, to prove the composite inherits leg reverts.
    function _revertingFeed() internal returns (IJBPriceFeed feed) {
        MockRevertingFeed reverting = new MockRevertingFeed();
        return IJBPriceFeed(address(reverting));
    }

    /// @notice ETH<->USDC through USD: USD/USDC = 1, USD/ETH = 3000 => ETH per USDC = 1/3000.
    function test_currentUnitPrice_triangulatesEthUsdc() public {
        // USD per 1 USDC = 1 (numerator), USD per 1 ETH = 3000 (denominator), both reported at 18 decimals.
        IJBPriceFeed usdPerUsdc = IJBPriceFeed(address(new MockPriceFeed(1e18, 18)));
        IJBPriceFeed usdPerEth = IJBPriceFeed(address(new MockPriceFeed(3000e18, 18)));

        JBTriangularPriceFeed feed = new JBTriangularPriceFeed({numerator: usdPerUsdc, denominator: usdPerEth});

        // ETH per 1 USDC = 1/3000, at 18 decimals.
        assertEq(feed.currentUnitPrice(18), mulDiv(1e18, 1e18, 3000e18));
        assertEq(feed.currentUnitPrice(18), uint256(1e18) / 3000);
    }

    /// @notice The composite must produce the same answer at different requested precisions.
    function test_currentUnitPrice_respectsDecimals() public {
        IJBPriceFeed usdPerUsdc = IJBPriceFeed(address(new MockPriceFeed(1e8, 8)));
        IJBPriceFeed usdPerEth = IJBPriceFeed(address(new MockPriceFeed(2000e8, 8)));

        JBTriangularPriceFeed feed = new JBTriangularPriceFeed({numerator: usdPerUsdc, denominator: usdPerEth});

        // 6-decimal request: ETH per USDC = 1/2000 at 6 decimals = 500.
        assertEq(feed.currentUnitPrice(6), uint256(1e6) / 2000);
        // 18-decimal request.
        assertEq(feed.currentUnitPrice(18), uint256(1e18) / 2000);
    }

    /// @notice Fuzz: composite equals numerator/denominator at the requested precision.
    function testFuzz_currentUnitPrice_matchesManualDivision(uint256 num, uint256 den, uint8 decRaw) public {
        uint256 decimals = bound(uint256(decRaw), 0, 36);
        num = bound(num, 1, 1e30);
        den = bound(den, 1, 1e30);

        IJBPriceFeed numerator = IJBPriceFeed(address(new MockPriceFeed(num, decimals)));
        IJBPriceFeed denominator = IJBPriceFeed(address(new MockPriceFeed(den, decimals)));

        JBTriangularPriceFeed feed = new JBTriangularPriceFeed({numerator: numerator, denominator: denominator});

        assertEq(feed.currentUnitPrice(decimals), mulDiv(num, 10 ** decimals, den));
    }

    /// @notice A reverting leg makes the composite revert (no usable stale/invalid composite price).
    function test_currentUnitPrice_revertsIfLegReverts() public {
        IJBPriceFeed good = IJBPriceFeed(address(new MockPriceFeed(1e18, 18)));
        JBTriangularPriceFeed feedNumeratorBad =
            new JBTriangularPriceFeed({numerator: _revertingFeed(), denominator: good});
        JBTriangularPriceFeed feedDenominatorBad =
            new JBTriangularPriceFeed({numerator: good, denominator: _revertingFeed()});

        vm.expectRevert();
        feedNumeratorBad.currentUnitPrice(18);

        vm.expectRevert();
        feedDenominatorBad.currentUnitPrice(18);
    }
}

contract MockRevertingFeed is IJBPriceFeed {
    error StaleOrInvalid();

    function currentUnitPrice(uint256) external pure override returns (uint256) {
        revert StaleOrInvalid();
    }
}
