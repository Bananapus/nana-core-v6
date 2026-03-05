// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script, stdJson, VmSafe} from "forge-std/Script.sol";
import {CoreDeployment, CoreDeploymentLib} from "./helpers/CoreDeploymentLib.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IJBPriceFeed} from "src/interfaces/IJBPriceFeed.sol";
import {JBPermissions} from "src/JBPermissions.sol";
import {JBProjects} from "src/JBProjects.sol";
import {JBPrices} from "src/JBPrices.sol";
import {JBDeadline3Hours} from "src/periphery/JBDeadline3Hours.sol";
import {JBDeadline1Day} from "src/periphery/JBDeadline1Day.sol";
import {JBDeadline3Days} from "src/periphery/JBDeadline3Days.sol";
import {JBDeadline7Days} from "src/periphery/JBDeadline7Days.sol";
import {JBMatchingPriceFeed} from "src/periphery/JBMatchingPriceFeed.sol";
import {JBChainlinkV3PriceFeed, AggregatorV3Interface} from "src/JBChainlinkV3PriceFeed.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {JBChainlinkV3SequencerPriceFeed} from "src/JBChainlinkV3SequencerPriceFeed.sol";
import {JBRulesets} from "src/JBRulesets.sol";
import {JBDirectory} from "src/JBDirectory.sol";
import {JBERC20} from "src/JBERC20.sol";
import {JBTokens} from "src/JBTokens.sol";
import {JBSplits} from "src/JBSplits.sol";
import {JBFeelessAddresses} from "src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "src/JBFundAccessLimits.sol";
import {JBController} from "src/JBController.sol";
import {JBTerminalStore} from "src/JBTerminalStore.sol";
import {JBMultiTerminal} from "src/JBMultiTerminal.sol";

import {JBConstants} from "src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "src/libraries/JBCurrencyIds.sol";

contract DeployPeriphery is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    address private TRUSTED_FORWARDER;

    bytes32 private DEADLINES_SALT = keccak256("_JBDeadlinesV6_");
    bytes32 private USD_NATIVE_FEED_SALT = keccak256("USD_FEEDV6");

    /// @notice The nonce that gets used across all chains to sync deployment addresses and allow for new deployments of
    /// the same bytecode.
    uint256 private CORE_DEPLOYMENT_NONCE = 6;
    address private OMNICHAIN_RULESET_OPERATOR = address(0x8f5DED85c40b50d223269C1F922A056E72101590);

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-core-v5";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia", "tempo_testnet"];
    }

    /// @notice Deploys the protocol.
    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("deployments/")));

        // We use the same trusted forwarder as the core deployment.
        TRUSTED_FORWARDER = core.permissions.trustedForwarder();

        // Deploy the protocol.
        deploy();
    }

    function deploy() public sphinx {
        // Deploy the ETH/USD price feed.
        IJBPriceFeed feed;

        IJBPriceFeed matchingPriceFeed;
        matchingPriceFeed = new JBMatchingPriceFeed();

        // Same as the chainlink example grace period.
        uint256 L2GracePeriod = 3600 seconds;

        // NOTE: Feeds come from this url `https://data.chain.link/feeds/ethereum/mainnet/eth-usd`.
        // Sequencer feeds come from this url `https://docs.chain.link/data-feeds/l2-sequencer-feeds`.

        // Perform the deploy for L1(s).
        if (block.chainid == 1) {
            feed = new JBChainlinkV3PriceFeed{salt: USD_NATIVE_FEED_SALT}(
                AggregatorV3Interface(address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)), 3600 seconds
            );
        } else if (block.chainid == 11_155_111) {
            feed = new JBChainlinkV3PriceFeed{salt: USD_NATIVE_FEED_SALT}(
                AggregatorV3Interface(address(0x694AA1769357215DE4FAC081bf1f309aDC325306)), 3600 seconds
            );
        } else {
            // Perform the deploy for L2s
            AggregatorV3Interface source;

            // Optimism
            if (block.chainid == 10) {
                source = AggregatorV3Interface(0x13e3Ee699D1909E989722E753853AE30b17e08c5);
                feed = new JBChainlinkV3SequencerPriceFeed{salt: USD_NATIVE_FEED_SALT}(
                    source,
                    3600 seconds,
                    AggregatorV2V3Interface(0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389),
                    L2GracePeriod
                );
            }
            // Optimism Sepolia
            else if (block.chainid == 11_155_420) {
                source = AggregatorV3Interface(address(0x61Ec26aA57019C486B10502285c5A3D4A4750AD7));
                feed = new JBChainlinkV3PriceFeed{salt: USD_NATIVE_FEED_SALT}(source, 3600 seconds);
            }
            // Base
            else if (block.chainid == 8453) {
                source = AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
                feed = new JBChainlinkV3SequencerPriceFeed{salt: USD_NATIVE_FEED_SALT}(
                    source,
                    3600 seconds,
                    AggregatorV2V3Interface(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433),
                    L2GracePeriod
                );
            }
            // Base Sepolia
            else if (block.chainid == 84_532) {
                source = AggregatorV3Interface(address(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1));
                feed = new JBChainlinkV3PriceFeed{salt: USD_NATIVE_FEED_SALT}(source, 3600 seconds);
            }
            // Arbitrum
            else if (block.chainid == 42_161) {
                source = AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
                feed = new JBChainlinkV3SequencerPriceFeed{salt: USD_NATIVE_FEED_SALT}(
                    source,
                    3600 seconds,
                    AggregatorV2V3Interface(0xFdB631F5EE196F0ed6FAa767959853A9F217697D),
                    L2GracePeriod
                );
            }
            // Arbitrum Sepolia
            else if (block.chainid == 421_614) {
                source = AggregatorV3Interface(address(0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165));
                feed = new JBChainlinkV3PriceFeed{salt: USD_NATIVE_FEED_SALT}(source, 3600 seconds);
            } else {
                revert("Unsupported chain");
            }
        }
        require(address(feed) != address(0), "Invalid price feed");

        core.prices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: JBCurrencyIds.USD,
            unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            feed: feed
        });

        // WARN: We are using the same price feed as the native token for the USD price feed. Which is only valid on
        // chains where Ether is the native asset. We *NEED* to update this when we deploy to a non-ether chain!
        core.prices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: JBCurrencyIds.USD,
            unitCurrency: JBCurrencyIds.ETH,
            feed: feed
        });

        // If the native asset for this chain is ether, then the conversion from native asset to ether is 1:1.
        // NOTE: We need to refactor this the moment we add a chain where its native token is *NOT* ether.
        // As otherwise prices for the `NATIVE_TOKEN` will be incorrect!
        core.prices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: JBCurrencyIds.ETH,
            unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            feed: matchingPriceFeed
        });

        // Deploy the USDC/USD price feed.
        _deployUSDCFeed(L2GracePeriod);

        // Deploy the JBDeadlines
        if (!_isDeployed(DEADLINES_SALT, type(JBDeadline3Hours).creationCode, "")) {
            new JBDeadline3Hours{salt: DEADLINES_SALT}();
        }

        if (!_isDeployed(DEADLINES_SALT, type(JBDeadline1Day).creationCode, "")) {
            new JBDeadline1Day{salt: DEADLINES_SALT}();
        }

        if (!_isDeployed(DEADLINES_SALT, type(JBDeadline3Days).creationCode, "")) {
            new JBDeadline3Days{salt: DEADLINES_SALT}();
        }

        if (!_isDeployed(DEADLINES_SALT, type(JBDeadline7Days).creationCode, "")) {
            new JBDeadline7Days{salt: DEADLINES_SALT}();
        }

        core.directory.setIsAllowedToSetFirstController(
            address(
                new JBController{salt: keccak256(abi.encode(CORE_DEPLOYMENT_NONCE))}({
                    directory: core.directory,
                    fundAccessLimits: core.fundAccess,
                    prices: core.prices,
                    permissions: core.permissions,
                    projects: core.projects,
                    rulesets: core.rulesets,
                    splits: core.splits,
                    tokens: core.tokens,
                    omnichainRulesetOperator: OMNICHAIN_RULESET_OPERATOR,
                    trustedForwarder: TRUSTED_FORWARDER
                })
            ),
            true
        );
    }

    function _deployUSDCFeed(uint256 L2GracePeriod) internal {
        IJBPriceFeed usdcFeed;
        address usdc;

        if (block.chainid == 1) {
            usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
            usdcFeed = new JBChainlinkV3PriceFeed(
                AggregatorV3Interface(address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6)), 86_400 seconds
            );
        } else if (block.chainid == 11_155_111) {
            usdc = address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
            usdcFeed = new JBChainlinkV3PriceFeed(
                AggregatorV3Interface(address(0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E)), 86_400 seconds
            );
        } else if (block.chainid == 10) {
            usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
            usdcFeed = new JBChainlinkV3SequencerPriceFeed({
                feed: AggregatorV3Interface(0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3),
                threshold: 86_400 seconds,
                sequencerFeed: AggregatorV2V3Interface(0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389),
                gracePeriod: L2GracePeriod
            });
        } else if (block.chainid == 11_155_420) {
            usdc = address(0x5fd84259d66Cd46123540766Be93DFE6D43130D7);
            usdcFeed = new JBChainlinkV3PriceFeed(
                AggregatorV3Interface(address(0x6e44e50E3cc14DD16e01C590DC1d7020cb36eD4C)), 86_400 seconds
            );
        } else if (block.chainid == 8453) {
            usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
            usdcFeed = new JBChainlinkV3SequencerPriceFeed({
                feed: AggregatorV3Interface(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B),
                threshold: 86_400 seconds,
                sequencerFeed: AggregatorV2V3Interface(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433),
                gracePeriod: L2GracePeriod
            });
        } else if (block.chainid == 84_532) {
            usdc = address(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
            usdcFeed = new JBChainlinkV3PriceFeed(
                AggregatorV3Interface(address(0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165)), 86_400 seconds
            );
        } else if (block.chainid == 42_161) {
            usdc = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
            usdcFeed = new JBChainlinkV3SequencerPriceFeed({
                feed: AggregatorV3Interface(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3),
                threshold: 86_400 seconds,
                sequencerFeed: AggregatorV2V3Interface(0xFdB631F5EE196F0ed6FAa767959853A9F217697D),
                gracePeriod: L2GracePeriod
            });
        } else if (block.chainid == 421_614) {
            usdc = address(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d);
            usdcFeed = new JBChainlinkV3PriceFeed(
                AggregatorV3Interface(address(0x0153002d20B96532C639313c2d54c3dA09109309)), 86_400 seconds
            );
        } else {
            revert("Unsupported chain for USDC feed");
        }

        require(usdc.code.length > 0, "Invalid USDC address");
        require(address(usdcFeed) != address(0), "Invalid USDC price feed");

        core.prices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: JBCurrencyIds.USD,
            unitCurrency: uint32(uint160(usdc)),
            feed: usdcFeed
        });
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        internal
        view
        returns (bool)
    {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }
}
