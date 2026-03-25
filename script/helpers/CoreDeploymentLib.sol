// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBPermissions} from "../../src/JBPermissions.sol";
import {JBProjects} from "../../src/JBProjects.sol";
import {JBPrices} from "../../src/JBPrices.sol";
import {JBRulesets} from "../../src/JBRulesets.sol";
import {JBDirectory} from "../../src/JBDirectory.sol";
import {JBTokens} from "../../src/JBTokens.sol";
import {JBSplits} from "../../src/JBSplits.sol";
import {JBFeelessAddresses} from "../../src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "../../src/JBFundAccessLimits.sol";
import {JBController} from "../../src/JBController.sol";
import {JBTerminalStore} from "../../src/JBTerminalStore.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";

import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/contracts/foundry/SphinxConstants.sol";

struct CoreDeployment {
    JBPermissions permissions;
    JBProjects projects;
    JBDirectory directory;
    JBSplits splits;
    JBRulesets rulesets;
    JBController controller;
    JBMultiTerminal terminal;
    JBTerminalStore terminalStore;
    JBPrices prices;
    JBFeelessAddresses feeless;
    JBFundAccessLimits fundAccess;
    JBTokens tokens;
    address trustedForwarder;
}

library CoreDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm internal constant vm = Vm(VM_ADDRESS);
    string constant PROJECT_NAME = "nana-core-v6";

    function getDeployment(string memory path) internal returns (CoreDeployment memory deployment) {
        // get chainId for which we need to get the deployment.
        uint256 chainId = block.chainid;

        // Deploy to get the constants.
        // TODO: get constants without deploy.
        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            if (networks[_i].chainId == chainId) {
                return getDeployment({path: path, networkName: networks[_i].name});
            }
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory networkName
    )
        internal
        view
        returns (CoreDeployment memory deployment)
    {
        deployment.permissions = JBPermissions(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBPermissions"
            })
        );

        deployment.projects = JBProjects(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBProjects"
            })
        );

        deployment.directory = JBDirectory(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBDirectory"
            })
        );

        deployment.splits = JBSplits(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBSplits"
            })
        );

        deployment.rulesets = JBRulesets(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBRulesets"
            })
        );

        deployment.controller = JBController(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBController"
            })
        );

        deployment.terminal = JBMultiTerminal(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBMultiTerminal"
            })
        );

        deployment.terminalStore = JBTerminalStore(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBTerminalStore"
            })
        );

        deployment.prices = JBPrices(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBPrices"
            })
        );

        deployment.feeless = JBFeelessAddresses(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBFeelessAddresses"
            })
        );

        deployment.fundAccess = JBFundAccessLimits(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBFundAccessLimits"
            })
        );

        deployment.tokens = JBTokens(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBTokens"
            })
        );

        deployment.trustedForwarder = _getDeploymentAddress({
            path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "ERC2771Forwarder"
        });
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.readFile(string.concat(path, projectName, "/", networkName, "/", contractName, ".json"));
        return stdJson.readAddress({json: deploymentJson, key: ".address"});
    }
}
