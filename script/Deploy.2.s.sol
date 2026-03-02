// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script, stdJson, VmSafe} from "forge-std/Script.sol";
import {CoreDeployment, CoreDeploymentLib} from "./helpers/CoreDeploymentLib.sol";

import {JBRulesets} from "src/JBRulesets.sol";
import {JBMultiTerminal} from "src/JBMultiTerminal.sol";
import {JBTerminalStore} from "src/JBTerminalStore.sol";
import {JBController} from "src/JBController.sol";

contract DeployPeriphery is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    address private TRUSTED_FORWARDER;

    /// @notice The nonce that gets used across all chains to sync deployment addresses and allow for new deployments of
    /// the same bytecode.
    uint256 private CORE_DEPLOYMENT_NONCE = 1;

    address private OMNICHAIN_RULESET_OPERATOR = address(0x587BF86677Ec0d1B766D9bA0d7AC2A51c6C2fc71);

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-core-v5";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    /// @notice Deploys the protocol.
    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("deployments/")));

        // We use the same trusted forwarder as the core deployment.
        TRUSTED_FORWARDER = core.permissions.trustedForwarder();

        // Make sure the ruleset operator is actually deployed.
        if (OMNICHAIN_RULESET_OPERATOR.code.length == 0) {
            revert("Omnichain ruleset operator not deployed");
        }

        // Deploy the protocol.
        deploy();
    }

    function deploy() public sphinx {
        core.directory
            .setIsAllowedToSetFirstController(
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
}
