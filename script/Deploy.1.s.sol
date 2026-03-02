// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script, stdJson, VmSafe} from "forge-std/Script.sol";
import {CoreDeployment, CoreDeploymentLib} from "./helpers/CoreDeploymentLib.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {JBRulesets} from "src/JBRulesets.sol";
import {JBMultiTerminal} from "src/JBMultiTerminal.sol";
import {JBTerminalStore} from "src/JBTerminalStore.sol";
import {JBController} from "src/JBController.sol";

contract DeployPeriphery is Script, Sphinx {
    /// @notice The universal PERMIT2 address.
    IPermit2 private constant _PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    address private TRUSTED_FORWARDER;

    /// @notice The nonce that gets used across all chains to sync deployment addresses and allow for new deployments of
    /// the same bytecode.
    uint256 private CORE_DEPLOYMENT_NONCE = 1;

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

        // Deploy the protocol.
        deploy();
    }

    function deploy() public sphinx {
        JBRulesets rulesets = new JBRulesets{salt: keccak256(abi.encode(CORE_DEPLOYMENT_NONCE))}(core.directory);

        new JBMultiTerminal{salt: keccak256(abi.encode(CORE_DEPLOYMENT_NONCE))}({
            permissions: core.permissions,
            projects: core.projects,
            splits: core.splits,
            store: new JBTerminalStore{salt: keccak256(abi.encode(CORE_DEPLOYMENT_NONCE))}({
                directory: core.directory,
                prices: core.prices,
                rulesets: rulesets
            }),
            tokens: core.tokens,
            feelessAddresses: core.feeless,
            permit2: _PERMIT2,
            trustedForwarder: TRUSTED_FORWARDER
        });
    }
}
