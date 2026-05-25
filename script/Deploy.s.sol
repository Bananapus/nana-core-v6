// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {JBDirectory} from "../src/JBDirectory.sol";
import {JBERC20} from "../src/JBERC20.sol";
import {JBFeelessAddresses} from "../src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "../src/JBFundAccessLimits.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {JBPermissions} from "../src/JBPermissions.sol";
import {JBPrices} from "../src/JBPrices.sol";
import {JBProjects} from "../src/JBProjects.sol";
import {JBRulesets} from "../src/JBRulesets.sol";
import {JBSplits} from "../src/JBSplits.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBTokens} from "../src/JBTokens.sol";

contract Deploy is Script, Sphinx {
    /// @notice The universal PERMIT2 address.
    IPermit2 private constant _PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @notice The address that is allowed to forward calls to the terminal and controller on behalf of users.
    string private constant _TRUSTED_FORWARDER_NAME = "Juicebox";
    address private trustedForwarder;

    /// @notice The address that will manage privileged protocol functions.
    address private manager;

    /// @notice The address that will own the fee-project.
    /// @dev Core deployment transfers project `#1` to this owner, but does not fully activate fee collection on its
    /// own. Production fee collection only starts once the fee project's controller, terminals, and accounting
    /// contexts are configured by follow-up deployment steps.
    address private feeProjectOwner;

    /// @notice The nonce that gets used across all chains to sync deployment addresses and allow for new deployments of
    /// the same bytecode.
    uint256 private constant _CORE_DEPLOYMENT_NONCE = 6;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-core-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    /// @notice Deploys the protocol.
    function run() public sphinx {
        // Set the manager, this can be changed and won't affect deployment addresses.
        manager = safeAddress();
        // Set the owner of the fee project to be the project multisig. This does not by itself make fee collection
        // live; project `#1` still needs its follow-up controller/terminal/accounting-context configuration.
        feeProjectOwner = safeAddress();

        // Deploy the protocol.
        deploy();
    }

    function deploy() public sphinx {
        trustedForwarder =
            address(new ERC2771Forwarder{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(_TRUSTED_FORWARDER_NAME));

        JBPermissions permissions =
            new JBPermissions{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(trustedForwarder);
        JBProjects projects = new JBProjects{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}({
            owner: safeAddress(), feeProjectOwner: safeAddress(), trustedForwarder: trustedForwarder
        });
        JBDirectory directory = new JBDirectory{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}({
            permissions: permissions, projects: projects, owner: safeAddress()
        });
        JBSplits splits = new JBSplits{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(directory);
        JBRulesets rulesets = new JBRulesets{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(directory);
        JBPrices prices = new JBPrices{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}({
            directory: directory,
            permissions: permissions,
            projects: projects,
            owner: safeAddress(),
            trustedForwarder: trustedForwarder
        });
        JBTokens tokens = new JBTokens{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}({
            directory: directory,
            token: new JBERC20{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(permissions, projects)
        });

        new JBFundAccessLimits{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(directory);

        JBFeelessAddresses feeless =
            new JBFeelessAddresses{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}(safeAddress());

        new JBMultiTerminal{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}({
            permissions: permissions,
            projects: projects,
            splits: splits,
            store: new JBTerminalStore{salt: keccak256(abi.encode(_CORE_DEPLOYMENT_NONCE))}({
                directory: directory, rulesets: rulesets, prices: prices
            }),
            tokens: tokens,
            feelessAddresses: feeless,
            permit2: _PERMIT2,
            trustedForwarder: trustedForwarder
        });

        // If the manager is not the deployer we transfer all ownership to it.
        if (manager != safeAddress() && manager != address(0)) {
            directory.transferOwnership(manager);
            feeless.transferOwnership(manager);
            prices.transferOwnership(manager);
            projects.transferOwnership(manager);
        }

        // Transfer ownership to the fee project owner. Follow-up deployment steps must still finish configuring
        // project `#1` before protocol fees are collected instead of being forgiven back to payer projects.
        if (feeProjectOwner != safeAddress() && feeProjectOwner != address(0)) {
            projects.safeTransferFrom({from: safeAddress(), to: feeProjectOwner, tokenId: 1});
        }
    }
}
