// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPriceFeed} from "../../src/interfaces/IJBPriceFeed.sol";
import {IJBPrices} from "../../src/interfaces/IJBPrices.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "../../src/libraries/JBCurrencyIds.sol";
import {JBRatioPriceFeed} from "../../src/periphery/JBRatioPriceFeed.sol";

/// @notice Fork tests composing the legs that are actually registered in the deployed `JBPrices` on each chain with
/// no direct USDC/ETH aggregator.
/// @dev Ethereum mainnet can be checked against a third, independent aggregator. Optimism, Base and Arbitrum cannot —
/// no direct USDC/ETH feed exists there, which is the reason the composition is needed on those chains in the first
/// place. What is checkable is that the pair the deploy registers resolves at all and lands at a plausible ETH per
/// USDC, over the legs read back out of the live registry rather than over addresses re-hardcoded here.
/// @dev The legs on these chains are `JBChainlinkV3SequencerPriceFeed`s, which revert when the L2 sequencer-uptime
/// feed reports the sequencer down or still inside its grace period. Each block below is pinned at a point where both
/// legs resolve, so a revert here is the composition failing rather than the chain having been paused.
contract TestRatioPriceFeedRegistryFork is Test {
    // `JBPrices`, deployed to the same address on every chain.
    IJBPrices constant PRICES = IJBPrices(0xad45E4627f068d1e6b21E5301870d807543a8401);

    // The project ID `JBPrices` stores protocol default feeds under.
    uint256 constant DEFAULT_PROJECT_ID = 0;

    // Canonical USDC per chain.
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant OPTIMISM_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Pinned blocks for reproducibility, each chosen so both legs resolve.
    uint256 constant ARBITRUM_FORK_BLOCK = 492_500_000;
    uint256 constant BASE_FORK_BLOCK = 49_700_000;
    uint256 constant OPTIMISM_FORK_BLOCK = 155_000_000;

    // Bounds on ETH per USDC at 18 decimals. They span ETH anywhere from $100 to $100,000, which is loose enough that
    // no plausible price at a pinned block falls outside, while an inverted composition lands above 1e21 — five
    // orders past the upper bound.
    uint256 constant MAX_ETH_PER_USDC = 1e16;
    uint256 constant MIN_ETH_PER_USDC = 1e13;

    // ------------------------------------------------------------------
    // Live registry composition
    // ------------------------------------------------------------------

    /// @notice The registered Arbitrum legs compose to a plausible ETH per USDC.
    function test_composedPrice_arbitrum() public {
        _assertRegisteredLegsComposeToEthPerUsdc({
            forkAlias: "arbitrum", forkBlock: ARBITRUM_FORK_BLOCK, usdc: ARBITRUM_USDC
        });
    }

    /// @notice The registered Base legs compose to a plausible ETH per USDC.
    function test_composedPrice_base() public {
        _assertRegisteredLegsComposeToEthPerUsdc({forkAlias: "base", forkBlock: BASE_FORK_BLOCK, usdc: BASE_USDC});
    }

    /// @notice The registered Optimism legs compose to a plausible ETH per USDC.
    function test_composedPrice_optimism() public {
        _assertRegisteredLegsComposeToEthPerUsdc({
            forkAlias: "optimism", forkBlock: OPTIMISM_FORK_BLOCK, usdc: OPTIMISM_USDC
        });
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Reads the two legs out of the live `JBPrices` at the exact pairs the deploy registers them under, then
    /// composes them and checks the result is a usable ETH per USDC.
    /// @param forkAlias The RPC alias to fork.
    /// @param forkBlock The block to pin the fork at.
    /// @param usdc The chain's canonical USDC token.
    function _assertRegisteredLegsComposeToEthPerUsdc(
        string memory forkAlias,
        uint256 forkBlock,
        address usdc
    )
        internal
    {
        vm.createSelectFork(forkAlias, forkBlock);

        // `JBPrices` keys ERC-20 currencies by the low 32 bits of the token address.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 usdcCurrency = uint32(uint160(usdc));

        IJBPriceFeed usdcUsdFeed = PRICES.priceFeedFor({
            projectId: DEFAULT_PROJECT_ID, pricingCurrency: JBCurrencyIds.USD, unitCurrency: usdcCurrency
        });
        IJBPriceFeed nativeUsdFeed = PRICES.priceFeedFor({
            projectId: DEFAULT_PROJECT_ID,
            pricingCurrency: JBCurrencyIds.USD,
            unitCurrency: JBConstants.NATIVE_TOKEN_CURRENCY
        });

        assertNotEq(address(usdcUsdFeed), address(0), "no USDC/USD leg registered");
        assertNotEq(address(nativeUsdFeed), address(0), "no NATIVE/USD leg registered");

        uint256 composedPrice = new JBRatioPriceFeed(usdcUsdFeed, nativeUsdFeed).currentUnitPrice(18);

        assertGt(composedPrice, MIN_ETH_PER_USDC, "ETH per USDC below 0.00001");
        assertLt(composedPrice, MAX_ETH_PER_USDC, "ETH per USDC above 0.01, so the quotient is inverted");
    }
}
