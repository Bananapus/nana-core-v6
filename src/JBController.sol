// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {JBApprovalStatus} from "./enums/JBApprovalStatus.sol";
import {IJBController} from "./interfaces/IJBController.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBDirectoryAccessControl} from "./interfaces/IJBDirectoryAccessControl.sol";
import {IJBFundAccessLimits} from "./interfaces/IJBFundAccessLimits.sol";
import {IJBMigratable} from "./interfaces/IJBMigratable.sol";
import {IJBPermissioned} from "./interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBPriceFeed} from "./interfaces/IJBPriceFeed.sol";
import {IJBPrices} from "./interfaces/IJBPrices.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBProjectUriRegistry} from "./interfaces/IJBProjectUriRegistry.sol";
import {IJBRulesetDataHook} from "./interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "./interfaces/IJBRulesets.sol";
import {IJBSplitHook} from "./interfaces/IJBSplitHook.sol";
import {IJBSplits} from "./interfaces/IJBSplits.sol";
import {IJBTerminal} from "./interfaces/IJBTerminal.sol";
import {IJBToken} from "./interfaces/IJBToken.sol";
import {IJBTokens} from "./interfaces/IJBTokens.sol";
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBSplitGroupIds} from "./libraries/JBSplitGroupIds.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";
import {JBRulesetConfig} from "./structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "./structs/JBRulesetMetadata.sol";
import {JBRulesetWithMetadata} from "./structs/JBRulesetWithMetadata.sol";
import {JBSplit} from "./structs/JBSplit.sol";
import {JBSplitGroup} from "./structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "./structs/JBSplitHookContext.sol";
import {JBTerminalConfig} from "./structs/JBTerminalConfig.sol";

/// @notice The orchestrator for every Juicebox project's lifecycle. Use the controller to launch a project, queue new
/// rulesets (funding cycles), mint or burn tokens, deploy an ERC-20, distribute reserved tokens, and manage
/// permissions. The controller coordinates between the terminal (money), rulesets (rules), tokens (issuance), and
/// splits (distribution).
/// @dev Supports ERC-2771 meta-transactions. Implements `IJBMigratable` for controller-to-controller migration.
/// An omnichain deployer address is trusted to launch and queue rulesets on behalf of any project for cross-chain
/// coordination.
contract JBController is JBPermissioned, ERC2771Context, IJBController, IJBMigratable {
    // A library that parses packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBController_AddingPriceFeedNotAllowed(uint256 projectId);
    error JBController_CreditTransfersPaused(uint256 projectId, uint256 rulesetId);
    error JBController_InvalidCashOutTaxRate(uint256 rate, uint256 limit);
    error JBController_InvalidReservedPercent(uint256 percent, uint256 limit);
    error JBController_MintNotAllowedAndNotTerminalOrHook(address caller);
    error JBController_NoReservedTokens(uint256 projectId);
    error JBController_OnlyDirectory(address sender, IJBDirectory directory);
    error JBController_PendingReservedTokens(uint256 pendingReservedTokenBalance);
    error JBController_RulesetsAlreadyLaunched(uint256 projectId);
    error JBController_RulesetsArrayEmpty(uint256 projectId, uint256 rulesetConfigurationCount);
    error JBController_RulesetSetTokenNotAllowed(uint256 projectId);
    error JBController_TerminalTokensNotTransferred(address terminal, address token, uint256 allowance);
    error JBController_ZeroTokensToBurn(uint256 projectId, address holder);
    error JBController_ZeroTokensToMint(uint256 projectId, address beneficiary);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice A contract that stores fund access limits for each project.
    IJBFundAccessLimits public immutable override FUND_ACCESS_LIMITS;

    /// @notice A contract that stores prices for each project.
    IJBPrices public immutable override PRICES;

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The contract storing and managing project rulesets.
    IJBRulesets public immutable override RULESETS;

    /// @notice The contract that stores splits for each project.
    IJBSplits public immutable override SPLITS;

    /// @notice The contract that manages token minting and burning.
    IJBTokens public immutable override TOKENS;

    /// @notice The address of the contract that manages omnichain ruleset ops.
    /// @dev This is a deterministic CREATE2 deployment; bytecode verification at runtime would add gas cost for
    /// marginal security benefit since the address is verified at deploy time.
    /// @dev TRUST BOUNDARY: This hardcoded address can call `launchRulesetsFor` and `queueRulesetsOf` for ANY project,
    /// bypassing normal `JBPermissions` checks. If this address is compromised or its implementation is malicious:
    ///   - Projects WITH approval hooks are partially protected: the attacker can queue rulesets, but they must pass
    ///     the project's approval hook before becoming active.
    ///   - Projects WITHOUT approval hooks (duration == 0 or no approval hook set) are IMMEDIATELY affected: queued
    ///     rulesets take effect as soon as the current ruleset expires (or immediately if duration == 0).
    /// @dev The operator can also call `setTerminalsOf` during `launchRulesetsFor`, which could redirect a project's
    /// payment routing. This is limited to the initial launch flow (reverts if rulesets already exist).
    /// @dev Mitigation: verify the deployed bytecode at this address matches the expected `JBOmnichainDeployer`
    /// contract from `nana-omnichain-deployers-v6` on every target chain before running deployment scripts.
    address public immutable override OMNICHAIN_RULESET_OPERATOR;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice A project's unrealized reserved token balance (i.e. reserved tokens which haven't been sent out to the
    /// reserved token split group yet).
    /// @custom:param projectId The ID of the project to get the pending reserved token balance of.
    mapping(uint256 projectId => uint256) public override pendingReservedTokenBalanceOf;

    /// @notice The metadata URI for each project. This is typically an IPFS hash, optionally with an `ipfs://` prefix.
    /// @custom:param projectId The ID of the project to get the metadata URI of.
    mapping(uint256 projectId => string) public override uriOf;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param fundAccessLimits A contract that stores fund access limits for each project.
    /// @param permissions A contract storing permissions.
    /// @param prices A contract that stores prices for each project.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param rulesets A contract storing and managing project rulesets.
    /// @param splits A contract that stores splits for each project.
    /// @param tokens A contract that manages token minting and burning.
    /// @param omnichainRulesetOperator The address of the contract that manages omnichain ruleset ops.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBDirectory directory,
        IJBFundAccessLimits fundAccessLimits,
        IJBPermissions permissions,
        IJBPrices prices,
        IJBProjects projects,
        IJBRulesets rulesets,
        IJBSplits splits,
        IJBTokens tokens,
        address omnichainRulesetOperator,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = directory;
        FUND_ACCESS_LIMITS = fundAccessLimits;
        PRICES = prices;
        PROJECTS = projects;
        RULESETS = rulesets;
        SPLITS = splits;
        TOKENS = tokens;
        OMNICHAIN_RULESET_OPERATOR = omnichainRulesetOperator;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Registers a price feed so the project can use a new currency for payout limits or surplus allowances.
    /// @dev Can only be called by the project's owner or an operator with `ADD_PRICE_FEED` permission. The current
    /// ruleset must have `allowAddPriceFeed` enabled.
    /// @param projectId The ID of the project to add the feed for.
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
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.ADD_PRICE_FEED
        });

        JBRuleset memory ruleset = _currentRulesetOf(projectId);

        // Make sure the project's ruleset allows adding price feeds.
        if (!ruleset.allowAddPriceFeed()) revert JBController_AddingPriceFeedNotAllowed(projectId);

        PRICES.addPriceFeedFor({
            projectId: projectId, pricingCurrency: pricingCurrency, unitCurrency: unitCurrency, feed: feed
        });
    }

    /// @notice Called after this controller has been set as the project's controller in the directory.
    /// @dev Can only be called by the directory.
    /// @param from The controller to migrate from.
    /// @param projectId The ID of the project that migrated to this controller.
    function afterReceiveMigrationFrom(IERC165 from, uint256 projectId) external view override {
        from; // Suppress unused variable warning.
        projectId; // Suppress unused variable warning.

        // Make sure the sender is the directory.
        if (_msgSender() != address(DIRECTORY)) revert JBController_OnlyDirectory(_msgSender(), DIRECTORY);
    }

    /// @notice Prepares this controller to receive a project to migrate from another controller.
    /// @dev This controller should not be the project's controller yet.
    /// @param from The controller to migrate from.
    /// @param projectId The ID of the project that will migrate to this controller.
    function beforeReceiveMigrationFrom(IERC165 from, uint256 projectId) external override {
        // Keep a reference to the sender.
        address sender = _msgSender();

        // Make sure the sender is the expected source controller.
        if (sender != address(DIRECTORY)) revert JBController_OnlyDirectory(sender, DIRECTORY);

        // If the sending controller is an `IJBProjectUriRegistry`, copy the project's metadata URI.
        if (from.supportsInterface(type(IJBProjectUriRegistry).interfaceId)) {
            uriOf[projectId] = IJBProjectUriRegistry(address(from)).uriOf(projectId);
        }

        // Send the pending reserved tokens to the splits.
        if (
            from.supportsInterface(type(IJBController).interfaceId)
                && IJBController(address(from)).pendingReservedTokenBalanceOf(projectId) > 0
        ) {
            IJBController(address(from)).sendReservedTokensToSplitsOf(projectId);
        }
    }

    /// @notice Burns a holder's project tokens (or unclaimed credits), permanently removing them from the project
    /// token supply. Used by terminals during cash outs, or directly by holders who want to burn voluntarily.
    /// @dev Can only be called by the holder, an operator with `BURN_TOKENS` permission, or a project terminal.
    /// @param holder The address whose project tokens (or credits) are being burned.
    /// @param projectId The ID of the project whose tokens are being burned.
    /// @param tokenCount The number of project tokens (or credits) to burn, as a fixed point number with 18 decimals.
    /// @param memo A memo to pass along to the emitted event.
    function burnTokensOf(
        address holder,
        uint256 projectId,
        uint256 tokenCount,
        string calldata memo
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: holder,
            projectId: projectId,
            permissionId: JBPermissionIds.BURN_TOKENS,
            alsoGrantAccessIf: _isTerminalOf({projectId: projectId, terminal: _msgSender()})
        });

        // There must be tokens to burn.
        if (tokenCount == 0) revert JBController_ZeroTokensToBurn({projectId: projectId, holder: holder});

        emit BurnTokens({
            holder: holder, projectId: projectId, tokenCount: tokenCount, memo: memo, caller: _msgSender()
        });

        // Burn the tokens.
        TOKENS.burnFrom({holder: holder, projectId: projectId, count: tokenCount});
    }

    /// @notice Converts a holder's internal project token credits into the project's ERC-20 representation,
    /// transferring them to the beneficiary's wallet. Credits and the ERC-20 are equivalent project tokens — this
    /// just
    /// makes them transferable/tradeable.
    /// @dev Can only be called by the credit holder or an operator with `CLAIM_TOKENS` permission.
    /// @param holder The address whose project token credits are being redeemed.
    /// @param projectId The ID of the project whose project tokens are being claimed.
    /// @param tokenCount The number of project token credits to convert into ERC-20 project tokens, as a fixed point
    /// number with 18 decimals.
    /// @param beneficiary The account that receives the resulting ERC-20 project tokens.
    function claimTokensFor(
        address holder,
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.CLAIM_TOKENS});

        TOKENS.claimTokensFor({holder: holder, projectId: projectId, count: tokenCount, beneficiary: beneficiary});
    }

    /// @notice Deploys a new ERC-20 token for a project. Once deployed, holders can claim their credits as this token.
    /// Includes ERC20Votes (governance) and ERC20Permit (gasless approvals).
    /// @dev Can only be called by the project's owner or an operator with `DEPLOY_ERC20` permission.
    /// @dev Each project can only have one ERC-20 deployed — calling this again after deployment will revert.
    /// @param projectId The ID of the project to deploy the ERC-20 for.
    /// @param name The ERC-20's name.
    /// @param symbol The ERC-20's symbol.
    /// @param salt The salt used for ERC-1167 clone deployment. Pass a non-zero salt for deterministic deployment based
    /// on `msg.sender` and the `TOKEN` implementation address.
    /// @return token The address of the token that was deployed.
    function deployERC20For(
        uint256 projectId,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    )
        external
        override
        returns (IJBToken token)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.DEPLOY_ERC20
        });

        // If a salt is provided, use it.
        bytes32 saltHash = salt != bytes32(0) ? keccak256(abi.encodePacked(_msgSender(), salt)) : bytes32(0);

        // Emit the event.
        emit DeployERC20({
            projectId: projectId, deployer: _msgSender(), salt: salt, saltHash: saltHash, caller: _msgSender()
        });

        // Deploy the ERC-20 token with the hashed salt.
        return TOKENS.deployERC20For({projectId: projectId, name: name, symbol: symbol, salt: saltHash});
    }

    /// @notice When a project receives reserved tokens, if it has a terminal for the token, this is used to pay the
    /// terminal.
    /// @dev Can only be called by this controller.
    /// @param terminal The terminal to pay.
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with.
    /// @param splitTokenCount The number of tokens to pay.
    /// @param beneficiary The payment's beneficiary.
    /// @param metadata The pay metadata sent to the terminal.
    function executePayReservedTokenToTerminal(
        IJBTerminal terminal,
        uint256 projectId,
        IJBToken token,
        uint256 splitTokenCount,
        address beneficiary,
        bytes calldata metadata
    )
        external
    {
        // Can only be called by this contract.
        require(msg.sender == address(this));

        // Approve the tokens being paid.
        IERC20(address(token)).forceApprove({spender: address(terminal), value: splitTokenCount});

        terminal.pay({
            projectId: projectId,
            token: address(token),
            amount: splitTokenCount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        // Make sure that the terminal received the tokens.
        uint256 allowance = IERC20(address(token)).allowance({owner: address(this), spender: address(terminal)});
        if (allowance != 0) {
            revert JBController_TerminalTokensNotTransferred({
                terminal: address(terminal), token: address(token), allowance: allowance
            });
        }
    }

    /// @notice Creates a new Juicebox project in one transaction — mints the project NFT, queues initial rulesets,
    /// and
    /// configures terminals. This is the primary entry point for launching a project.
    /// @dev Anyone can call this on behalf of any owner. Each sub-operation (mint, queue, configure) can also be done
    /// individually if needed.
    /// @param owner The project's owner. The project ERC-721 will be minted to this address.
    /// @param projectUri The project's metadata URI. This is typically an IPFS hash, optionally with the `ipfs://`
    /// prefix. This can be updated by the project's owner.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @return projectId The project's ID.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo
    )
        external
        override
        returns (uint256 projectId)
    {
        // Mint the project ERC-721 into the owner's wallet.
        projectId = PROJECTS.createFor(owner);

        // If provided, set the project's metadata URI.
        if (bytes(projectUri).length > 0) {
            uriOf[projectId] = projectUri;
        }

        // Set this contract as the project's controller in the directory.
        DIRECTORY.setControllerOf({projectId: projectId, controller: IERC165(this)});

        // Configure the terminals.
        _configureTerminals({projectId: projectId, terminalConfigurations: terminalConfigurations});

        // Queue the rulesets.
        uint256 rulesetId = _queueRulesets({projectId: projectId, rulesetConfigurations: rulesetConfigurations});

        emit LaunchProject({
            rulesetId: rulesetId, projectId: projectId, projectUri: projectUri, memo: memo, caller: _msgSender()
        });
    }

    /// @notice Queues the first rulesets for an existing project and configures its terminals. For projects that
    /// already have active rulesets, use `queueRulesetsOf(...)` instead.
    /// @dev Can only be called by the project's owner or an operator with `LAUNCH_RULESETS` permission.
    /// @dev Each sub-operation can also be done individually if needed.
    /// @param projectId The ID of the project to launch rulesets for.
    /// @param projectUri The project's metadata URI. Pass an empty string to leave it unchanged.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the last successfully queued ruleset.
    function launchRulesetsFor(
        uint256 projectId,
        string calldata projectUri,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo
    )
        external
        override
        returns (uint256 rulesetId)
    {
        // Make sure there are rulesets being queued.
        if (rulesetConfigurations.length == 0) {
            revert JBController_RulesetsArrayEmpty({
                projectId: projectId, rulesetConfigurationCount: rulesetConfigurations.length
            });
        }

        // Keep a reference to the sender.
        address sender = _msgSender();

        // Enforce permissions.
        bool isOmnichainOperator = sender == OMNICHAIN_RULESET_OPERATOR;
        _requirePermissionAllowingOverrideFrom({
            account: _ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.LAUNCH_RULESETS,
            alsoGrantAccessIf: isOmnichainOperator
        });
        _requirePermissionAllowingOverrideFrom({
            account: _ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_TERMINALS,
            alsoGrantAccessIf: isOmnichainOperator
        });
        if (bytes(projectUri).length > 0) {
            _requirePermissionAllowingOverrideFrom({
                account: _ownerOf(projectId),
                projectId: projectId,
                permissionId: JBPermissionIds.SET_PROJECT_URI,
                alsoGrantAccessIf: isOmnichainOperator
            });
        }

        // If the project has already had rulesets, use `queueRulesetsOf(...)` instead.
        if (RULESETS.latestRulesetIdOf(projectId) > 0) {
            revert JBController_RulesetsAlreadyLaunched({projectId: projectId});
        }

        // If provided, set the project's metadata URI.
        if (bytes(projectUri).length > 0) {
            uriOf[projectId] = projectUri;
        }

        // Set this contract as the project's controller in the directory.
        DIRECTORY.setControllerOf({projectId: projectId, controller: IERC165(this)});

        // Configure the terminals.
        _configureTerminals({projectId: projectId, terminalConfigurations: terminalConfigurations});

        // Queue the first ruleset.
        rulesetId = _queueRulesets({projectId: projectId, rulesetConfigurations: rulesetConfigurations});

        emit LaunchRulesets({
            rulesetId: rulesetId, projectId: projectId, projectUri: projectUri, memo: memo, caller: _msgSender()
        });
    }

    /// @notice Migrate a project from this controller to another one.
    /// @dev Can only be called by the directory.
    /// @param projectId The ID of the project to migrate.
    /// @param to The controller to migrate the project to.
    function migrate(uint256 projectId, IERC165 to) external override {
        // Make sure this is being called by the directory.
        if (msg.sender != address(DIRECTORY)) revert JBController_OnlyDirectory(msg.sender, DIRECTORY);

        emit Migrate({projectId: projectId, to: to, caller: msg.sender});

        // Get a reference to the project's pending reserved token balance.
        uint256 pendingReservedTokenBalance = pendingReservedTokenBalanceOf[projectId];

        // Revert if there are pending reserved tokens that should be sent before migrating.
        if (pendingReservedTokenBalance != 0) revert JBController_PendingReservedTokens(pendingReservedTokenBalance);
    }

    /// @notice Mints new project tokens to a beneficiary. Optionally reserves a portion according to the ruleset's
    /// reserved percent (which accumulates until `sendReservedTokensToSplitsOf` is called).
    /// @dev Can be called by the project owner, an operator with `MINT_TOKENS` permission, a project terminal, or the
    /// data hook. If `allowOwnerMinting` is false in the current ruleset, only terminals and the data hook can mint.
    /// @param projectId The ID of the project whose project tokens are being minted.
    /// @param tokenCount The total number of project tokens to mint (the beneficiary's share plus the reserved share if
    /// `useReservedPercent` is true), as a fixed point number with 18 decimals.
    /// @param beneficiary The address that receives the non-reserved portion of the minted project tokens.
    /// @param memo A memo to pass along to the emitted event.
    /// @param useReservedPercent Whether to apply the ruleset's reserved percent.
    /// @return beneficiaryTokenCount The number of project tokens minted to `beneficiary` (excluding the reserved
    /// share), as a fixed point number with 18 decimals.
    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        string calldata memo,
        bool useReservedPercent
    )
        external
        override
        returns (uint256 beneficiaryTokenCount)
    {
        // There should be tokens to mint.
        if (tokenCount == 0) revert JBController_ZeroTokensToMint({projectId: projectId, beneficiary: beneficiary});

        // Keep a reference to the reserved percent.
        uint256 reservedPercent;

        // Get a reference to the project's ruleset.
        JBRuleset memory ruleset = _currentRulesetOf(projectId);

        // Cache common values used in both permission checks.
        address sender = _msgSender();
        bool senderIsTerminal = _isTerminalOf({projectId: projectId, terminal: sender});
        bool senderIsTerminalOrDataHook = senderIsTerminal || sender == ruleset.dataHook();
        // Only query the data hook if the sender isn't already a terminal or the data hook itself.
        bool senderHasDataHookMintPermission = !senderIsTerminalOrDataHook
            && _hasDataHookMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: sender});

        // Minting is restricted to: the project's owner, addresses with permission to `MINT_TOKENS`, the project's
        // terminals, and the project's data hook.
        _requirePermissionAllowingOverrideFrom({
            account: _ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.MINT_TOKENS,
            alsoGrantAccessIf: senderIsTerminalOrDataHook || senderHasDataHookMintPermission
        });

        // If the message sender is not the project's terminal or data hook, the ruleset must have `allowOwnerMinting`
        // set to `true`.
        if (
            ruleset.id != 0 && !ruleset.allowOwnerMinting() && !senderIsTerminalOrDataHook
                && !senderHasDataHookMintPermission
        ) {
            revert JBController_MintNotAllowedAndNotTerminalOrHook({caller: sender});
        }

        // Determine the reserved percent to use.
        reservedPercent = useReservedPercent ? ruleset.reservedPercent() : 0;

        // Split the requested token count into beneficiary and reserved portions.
        (beneficiaryTokenCount,) = _splitTokenCount({tokenCount: tokenCount, reservedPercent: reservedPercent});

        if (beneficiaryTokenCount != 0) {
            // Mint the tokens.
            TOKENS.mintFor({holder: beneficiary, projectId: projectId, count: beneficiaryTokenCount});
        }

        emit MintTokens({
            beneficiary: beneficiary,
            projectId: projectId,
            tokenCount: tokenCount,
            beneficiaryTokenCount: beneficiaryTokenCount,
            memo: memo,
            reservedPercent: reservedPercent,
            caller: sender
        });

        // Add any reserved tokens to the pending reserved token balance.
        if (reservedPercent > 0) {
            pendingReservedTokenBalanceOf[projectId] += tokenCount - beneficiaryTokenCount;
        }
    }

    /// @notice Queues new rulesets to take effect after the current one ends. Each queued ruleset must be approved by
    /// the previous ruleset's approval hook (if one is set) before it can take effect.
    /// @dev Can only be called by the project's owner or an operator with `QUEUE_RULESETS` permission.
    /// @param projectId The ID of the project to queue rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the last ruleset which was successfully queued.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo
    )
        external
        override
        returns (uint256 rulesetId)
    {
        // Make sure there are rulesets being queued.
        if (rulesetConfigurations.length == 0) {
            revert JBController_RulesetsArrayEmpty({
                projectId: projectId, rulesetConfigurationCount: rulesetConfigurations.length
            });
        }

        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: _ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS,
            alsoGrantAccessIf: _msgSender() == OMNICHAIN_RULESET_OPERATOR
        });

        // Queue the rulesets.
        rulesetId = _queueRulesets({projectId: projectId, rulesetConfigurations: rulesetConfigurations});

        emit QueueRulesets({rulesetId: rulesetId, projectId: projectId, memo: memo, caller: _msgSender()});
    }

    /// @notice Mints and distributes all pending reserved tokens to the project's reserved token split recipients.
    /// Anyone can call this — it's permissionless.
    /// @dev If splits don't add up to 100%, the remainder goes to the project owner.
    /// @param projectId The ID of the project to send reserved tokens for.
    /// @return The amount of reserved tokens minted and sent.
    function sendReservedTokensToSplitsOf(uint256 projectId) external override returns (uint256) {
        return _sendReservedTokensToSplitsOf(projectId);
    }

    /// @notice Configures how a project distributes payouts and reserved tokens. Locked splits from the current
    /// configuration must be preserved in the new split groups.
    /// @dev Can only be called by the project's owner or an operator with `SET_SPLIT_GROUPS` permission.
    /// @param projectId The ID of the project to set the split groups of.
    /// @param rulesetId The ID of the ruleset the split groups should be active in. Use a `rulesetId` of 0 to set the
    /// default split groups, which are used when a ruleset has no splits set. If there are no default splits and no
    /// splits are set, all splits are sent to the project's owner.
    /// @param splitGroups An array of split groups to set.
    function setSplitGroupsOf(
        uint256 projectId,
        uint256 rulesetId,
        JBSplitGroup[] calldata splitGroups
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_SPLIT_GROUPS
        });

        // Set the split groups.
        SPLITS.setSplitGroupsOf({projectId: projectId, rulesetId: rulesetId, splitGroups: splitGroups});
    }

    /// @notice Set a project's token. If the project's token is already set, this will revert.
    /// @dev Can only be called by the project's owner or an address with the owner's permission to `SET_TOKEN`.
    /// @param projectId The ID of the project to set the token of.
    /// @param token The new token's address.
    function setTokenFor(uint256 projectId, IJBToken token) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_TOKEN
        });

        // Get a reference to the current ruleset.
        JBRuleset memory ruleset = _currentRulesetOf(projectId);

        // If there's no current ruleset, get a reference to the upcoming one.
        if (ruleset.id == 0) ruleset = _upcomingRulesetOf(projectId);

        // If owner minting is disabled for the ruleset, the owner cannot change the token.
        if (!ruleset.allowSetCustomToken()) revert JBController_RulesetSetTokenNotAllowed(projectId);

        TOKENS.setTokenFor({projectId: projectId, token: token});
    }

    /// @notice Sets the name and symbol of a project's token.
    /// @dev Can only be called by the project's owner or an address with the owner's permission to
    /// `SET_TOKEN_METADATA`.
    /// @param projectId The ID of the project to update the token for.
    /// @param name The new name.
    /// @param symbol The new symbol.
    function setTokenMetadataOf(uint256 projectId, string calldata name, string calldata symbol) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_TOKEN_METADATA
        });

        TOKENS.setTokenMetadataFor({projectId: projectId, name: name, symbol: symbol});
    }

    /// @notice Set a project's metadata URI.
    /// @dev This is typically an IPFS hash, optionally with an `ipfs://` prefix.
    /// @dev Can only be called by the project's owner or an address with the owner's permission to
    /// `SET_PROJECT_URI`.
    /// @param projectId The ID of the project to set the metadata URI of.
    /// @param uri The metadata URI to set.
    function setUriOf(uint256 projectId, string calldata uri) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: _ownerOf(projectId), projectId: projectId, permissionId: JBPermissionIds.SET_PROJECT_URI
        });

        // Set the project's metadata URI.
        uriOf[projectId] = uri;

        emit SetUri({projectId: projectId, uri: uri, caller: _msgSender()});
    }

    /// @notice Transfers internal credits (unclaimed tokens) from one address to another. Credits function like tokens
    /// but live inside the protocol rather than as an ERC-20.
    /// @dev Can only be called by the credit holder or an operator with `TRANSFER_CREDITS` permission. The current
    /// ruleset must not have credit transfers paused.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project to transfer credits for.
    /// @param recipient The address to transfer credits to.
    /// @param creditCount The number of credits to transfer.
    function transferCreditsFrom(
        address holder,
        uint256 projectId,
        address recipient,
        uint256 creditCount
    )
        external
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.TRANSFER_CREDITS});

        // Get a reference to the project's ruleset.
        JBRuleset memory ruleset = _currentRulesetOf(projectId);

        // Credit transfers must not be paused.
        if (ruleset.pauseCreditTransfers()) {
            revert JBController_CreditTransfersPaused({projectId: projectId, rulesetId: ruleset.id});
        }

        TOKENS.transferCreditsFrom({holder: holder, projectId: projectId, recipient: recipient, count: creditCount});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns a paginated history of a project's rulesets (with decoded metadata), sorted newest-first.
    /// @param projectId The ID of the project to get the rulesets of.
    /// @param startingId The ID of the ruleset to begin with. This will be the latest ruleset in the result. If the
    /// `startingId` is 0, passed, the project's latest ruleset will be used.
    /// @param size The maximum number of rulesets to return.
    /// @return rulesets The array of rulesets with their metadata.
    function allRulesetsOf(
        uint256 projectId,
        uint256 startingId,
        uint256 size
    )
        external
        view
        override
        returns (JBRulesetWithMetadata[] memory rulesets)
    {
        // Get the rulesets (without metadata).
        JBRuleset[] memory baseRulesets = RULESETS.allOf({projectId: projectId, startingId: startingId, size: size});

        // Keep a reference to the number of rulesets.
        uint256 numberOfRulesets = baseRulesets.length;

        // Initialize the array being returned.
        rulesets = new JBRulesetWithMetadata[](numberOfRulesets);

        // Populate the array with rulesets AND their metadata.
        for (uint256 i; i < numberOfRulesets;) {
            // Set the ruleset being iterated on.
            JBRuleset memory baseRuleset = baseRulesets[i];

            // Set the returned value.
            rulesets[i] = JBRulesetWithMetadata({ruleset: baseRuleset, metadata: baseRuleset.expandMetadata()});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the ruleset currently governing a project, along with its decoded metadata.
    /// @param projectId The ID of the project to get the current ruleset of.
    /// @return ruleset The current ruleset's struct.
    /// @return metadata The current ruleset's metadata.
    function currentRulesetOf(uint256 projectId)
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset = _currentRulesetOf(projectId);
        metadata = ruleset.expandMetadata();
    }

    /// @notice Get the `JBRuleset` and `JBRulesetMetadata` corresponding to the specified `rulesetId`.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @return ruleset The ruleset's struct.
    /// @return metadata The ruleset's metadata.
    function getRulesetOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset = RULESETS.getRulesetOf({projectId: projectId, rulesetId: rulesetId});
        metadata = ruleset.expandMetadata();
    }

    /// @notice Gets the latest ruleset queued for a project, its approval status, and its metadata.
    /// @dev The 'latest queued ruleset' is the ruleset initialized furthest in the future (at the end of the ruleset
    /// queue).
    /// @param projectId The ID of the project to get the latest ruleset of.
    /// @return ruleset The struct for the project's latest queued ruleset.
    /// @return metadata The ruleset's metadata.
    /// @return approvalStatus The ruleset's approval status.
    function latestQueuedRulesetOf(uint256 projectId)
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata, JBApprovalStatus approvalStatus)
    {
        (ruleset, approvalStatus) = RULESETS.latestQueuedOf(projectId);
        metadata = ruleset.expandMetadata();
    }

    /// @notice Previews how many beneficiary and reserved tokens `mintTokensOf(...)` would produce.
    /// @param projectId The ID of the project to mint tokens for.
    /// @param tokenCount The number of tokens to mint, including any reserved tokens.
    /// @param useReservedPercent Whether to apply the ruleset's reserved percent.
    /// @return beneficiaryTokenCount The number of tokens that would be minted for the beneficiary.
    /// @return reservedTokenCount The number of tokens that would be reserved.
    function previewMintOf(
        uint256 projectId,
        uint256 tokenCount,
        bool useReservedPercent
    )
        external
        view
        override
        returns (uint256 beneficiaryTokenCount, uint256 reservedTokenCount)
    {
        // A zero preview amount means there are no tokens to split.
        if (tokenCount == 0) return (0, 0);

        // Keep a reference to the current ruleset.
        JBRuleset memory ruleset = _currentRulesetOf(projectId);

        return
            _splitTokenCount({
                tokenCount: tokenCount, reservedPercent: useReservedPercent ? ruleset.reservedPercent() : 0
            });
    }

    /// @notice Whether the project's current ruleset allows migrating to a different controller.
    /// @param projectId The ID of the project to check.
    /// @return A `bool` which is true if the project allows controllers to be set.
    function setControllerAllowed(uint256 projectId) external view returns (bool) {
        return _currentRulesetOf(projectId).expandMetadata().allowSetController;
    }

    /// @notice Whether the project's current ruleset allows changing its terminals.
    /// @param projectId The ID of the project to check.
    /// @return A `bool` which is true if the project allows terminals to be set.
    function setTerminalsAllowed(uint256 projectId) external view returns (bool) {
        return _currentRulesetOf(projectId).expandMetadata().allowSetTerminals;
    }

    /// @notice Returns the project's total token supply including tokens that have been reserved but not yet minted.
    /// @param projectId The ID of the project to get the total token supply of.
    /// @return The total supply of the project's token, including pending reserved tokens.
    function totalTokenSupplyWithReservedTokensOf(uint256 projectId) external view override returns (uint256) {
        // Add the reserved tokens to the total supply.
        return TOKENS.totalSupplyOf(projectId) + pendingReservedTokenBalanceOf[projectId];
    }

    /// @notice Returns the ruleset that will take effect after the current one ends, along with its decoded metadata.
    /// @dev If an upcoming ruleset isn't found, returns an empty ruleset with all properties set to 0.
    /// @param projectId The ID of the project to get the next ruleset of.
    /// @return ruleset The upcoming ruleset's struct.
    /// @return metadata The upcoming ruleset's metadata.
    function upcomingRulesetOf(uint256 projectId)
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset = _upcomingRulesetOf(projectId);
        metadata = ruleset.expandMetadata();
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBController).interfaceId || interfaceId == type(IJBProjectUriRegistry).interfaceId
            || interfaceId == type(IJBDirectoryAccessControl).interfaceId
            || interfaceId == type(IJBMigratable).interfaceId || interfaceId == type(IJBPermissioned).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Set up a project's terminals.
    /// @param projectId The ID of the project to set up terminals for.
    /// @param terminalConfigurations The terminals to set up.
    function _configureTerminals(uint256 projectId, JBTerminalConfig[] calldata terminalConfigurations) internal {
        // Initialize an array of terminals to populate.
        IJBTerminal[] memory terminals = new IJBTerminal[](terminalConfigurations.length);

        for (uint256 i; i < terminalConfigurations.length;) {
            // Set the terminal configuration being iterated on.
            JBTerminalConfig memory terminalConfig = terminalConfigurations[i];

            // Add the accounting contexts for the specified tokens.
            terminalConfig.terminal
                .addAccountingContextsFor({
                    projectId: projectId, accountingContexts: terminalConfig.accountingContextsToAccept
                });

            // Add the terminal.
            terminals[i] = terminalConfig.terminal;
            unchecked {
                ++i;
            }
        }

        // Set the terminals in the directory.
        if (terminalConfigurations.length > 0) {
            DIRECTORY.setTerminalsOf({projectId: projectId, terminals: terminals});
        }
    }

    /// @notice Queues one or more rulesets and stores information pertinent to the configuration.
    /// @param projectId The ID of the project to queue rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @return rulesetId The ID of the last ruleset that was successfully queued.
    function _queueRulesets(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations
    )
        internal
        returns (uint256 rulesetId)
    {
        for (uint256 i; i < rulesetConfigurations.length;) {
            // Get a reference to the ruleset config being iterated on.
            JBRulesetConfig memory rulesetConfig = rulesetConfigurations[i];

            // Make sure its reserved percent is valid.
            if (rulesetConfig.metadata.reservedPercent > JBConstants.MAX_RESERVED_PERCENT) {
                revert JBController_InvalidReservedPercent({
                    percent: rulesetConfig.metadata.reservedPercent, limit: JBConstants.MAX_RESERVED_PERCENT
                });
            }

            // Make sure its cash out tax rate is valid.
            if (rulesetConfig.metadata.cashOutTaxRate > JBConstants.MAX_CASH_OUT_TAX_RATE) {
                revert JBController_InvalidCashOutTaxRate({
                    rate: rulesetConfig.metadata.cashOutTaxRate, limit: JBConstants.MAX_CASH_OUT_TAX_RATE
                });
            }

            // Queue its ruleset.
            JBRuleset memory ruleset = RULESETS.queueFor({
                projectId: projectId,
                duration: rulesetConfig.duration,
                weight: rulesetConfig.weight,
                weightCutPercent: rulesetConfig.weightCutPercent,
                approvalHook: rulesetConfig.approvalHook,
                metadata: JBRulesetMetadataResolver.packRulesetMetadata(rulesetConfig.metadata),
                mustStartAtOrAfter: rulesetConfig.mustStartAtOrAfter
            });

            // Set its split groups.
            SPLITS.setSplitGroupsOf({
                projectId: projectId, rulesetId: ruleset.id, splitGroups: rulesetConfig.splitGroups
            });

            // Set its fund access limits.
            FUND_ACCESS_LIMITS.setFundAccessLimitsFor({
                projectId: projectId, rulesetId: ruleset.id, fundAccessLimitGroups: rulesetConfig.fundAccessLimitGroups
            });

            // If this is the last configuration being queued, return the ruleset's ID.
            if (i == rulesetConfigurations.length - 1) {
                rulesetId = ruleset.id;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Send project tokens to a split group.
    /// @dev This is used to send reserved tokens to the reserved token split group.
    /// @param projectId The ID of the project the splits belong to.
    /// @param rulesetId The ID of the split group's ruleset.
    /// @param groupId The ID of the split group.
    /// @param tokenCount The number of tokens to send.
    /// @param token The token to send.
    /// @return leftoverTokenCount If the split percents don't add up to 100%, the leftover amount is returned.
    function _sendReservedTokensToSplitGroupOf(
        uint256 projectId,
        uint256 rulesetId,
        uint256 groupId,
        uint256 tokenCount,
        IJBToken token
    )
        internal
        returns (uint256 leftoverTokenCount)
    {
        // Set the leftover amount to the initial amount.
        leftoverTokenCount = tokenCount;

        // Get a reference to the split group.
        JBSplit[] memory splits = SPLITS.splitsOf({projectId: projectId, rulesetId: rulesetId, groupId: groupId});

        // Keep a reference to the number of splits being iterated on.
        uint256 numberOfSplits = splits.length;

        // Cache _msgSender() before the loop.
        address messageSender = _msgSender();

        // Send the tokens to the splits.
        for (uint256 i; i < numberOfSplits;) {
            // Get a reference to the split being iterated on.
            JBSplit memory split = splits[i];

            // Calculate the amount to send to the split.
            uint256 splitTokenCount =
                mulDiv({x: tokenCount, y: split.percent, denominator: JBConstants.SPLITS_TOTAL_PERCENT});

            // Mints tokens for the split if needed.
            if (splitTokenCount > 0) {
                // 1. If the split has a `hook`, call the hook's `processSplitWith` function.
                // 2. Otherwise, if the split has a `projectId`, try to pay the project using the split's `beneficiary`,
                // or the `_msgSender()` if the split has no beneficiary.
                // 3. Otherwise, if the split has a beneficiary, send the tokens to the split's beneficiary.
                // 4. Otherwise, send the tokens to the `_msgSender()`.

                // If the split has a hook, call its `processSplitWith` function.
                if (split.hook != IJBSplitHook(address(0))) {
                    if (token != IJBToken(address(0))) {
                        // ERC-20: grant the hook an allowance and let it pull tokens via transferFrom.
                        IERC20(address(token)).forceApprove({spender: address(split.hook), value: splitTokenCount});
                    } else {
                        // Credits: send directly — there is no allowance mechanism for credits.
                        TOKENS.transferCreditsFrom({
                            holder: address(this),
                            projectId: projectId,
                            recipient: address(split.hook),
                            count: splitTokenCount
                        });
                    }

                    try split.hook
                        .processSplitWith(
                            JBSplitHookContext({
                                token: address(token),
                                amount: splitTokenCount,
                                decimals: 18, // Hard-coded in `JBTokens`.
                                projectId: projectId,
                                groupId: groupId,
                                split: split
                            })
                        ) {}
                    catch (bytes memory reason) {
                        emit SplitHookReverted({projectId: projectId, hook: address(split.hook), reason: reason});
                    }

                    // For ERC-20 tokens, burn any tokens the hook did not consume.
                    if (token != IJBToken(address(0))) {
                        uint256 remaining =
                            IERC20(address(token)).allowance({owner: address(this), spender: address(split.hook)});
                        if (remaining > 0) {
                            IERC20(address(token)).forceApprove({spender: address(split.hook), value: 0});
                            TOKENS.burnFrom({holder: address(this), projectId: projectId, count: remaining});
                        }
                    }
                    // If the split has a project ID, try to pay the project. If that fails, pay the beneficiary.
                } else {
                    // Pay the project using the split's beneficiary if one was provided. Otherwise, use the message
                    // sender.
                    address beneficiary = split.beneficiary != address(0) ? split.beneficiary : messageSender;

                    if (split.projectId != 0) {
                        // Get a reference to the receiving project's primary payment terminal for the token.
                        IJBTerminal terminal = token == IJBToken(address(0))
                            ? IJBTerminal(address(0))
                            : DIRECTORY.primaryTerminalOf({projectId: split.projectId, token: address(token)});

                        // If the project doesn't have a token, or if the receiving project doesn't have a terminal
                        // which accepts the token, send the tokens to the beneficiary.
                        if (address(token) == address(0) || address(terminal) == address(0)) {
                            // Mint the tokens to the beneficiary.
                            _sendTokens({
                                projectId: projectId, tokenCount: splitTokenCount, recipient: beneficiary, token: token
                            });
                        } else {
                            // Use the `projectId` in the pay metadata.
                            bytes memory metadata = bytes(abi.encodePacked(projectId));

                            // Try to fulfill the payment.
                            try this.executePayReservedTokenToTerminal({
                                projectId: split.projectId,
                                terminal: terminal,
                                token: token,
                                splitTokenCount: splitTokenCount,
                                beneficiary: beneficiary,
                                metadata: metadata
                            }) {}
                            catch (bytes memory reason) {
                                emit ReservedDistributionReverted({
                                    projectId: projectId,
                                    split: split,
                                    tokenCount: splitTokenCount,
                                    reason: reason,
                                    caller: messageSender
                                });

                                // If it fails, transfer the tokens from this contract to the beneficiary.
                                IERC20(address(token)).safeTransfer({to: beneficiary, value: splitTokenCount});
                            }
                        }
                    } else if (beneficiary == address(0xdead)) {
                        // If the split has no project ID, and the beneficiary is 0xdead, burn.
                        TOKENS.burnFrom({holder: address(this), projectId: projectId, count: splitTokenCount});
                    } else {
                        // If the split has no project Id, send to beneficiary.
                        _sendTokens({
                            projectId: projectId, tokenCount: splitTokenCount, recipient: beneficiary, token: token
                        });
                    }
                }

                // Subtract the amount sent from the leftover.
                leftoverTokenCount -= splitTokenCount;
            }

            emit SendReservedTokensToSplit({
                projectId: projectId,
                rulesetId: rulesetId,
                groupId: groupId,
                split: split,
                tokenCount: splitTokenCount,
                caller: messageSender
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Sends pending reserved tokens to the project's reserved token splits.
    /// @dev If the project has no reserved token splits, or if they don't add up to 100%, leftover tokens are sent to
    /// the project's owner.
    /// @param projectId The ID of the project to send reserved tokens for.
    /// @return tokenCount The amount of reserved tokens minted and sent.
    function _sendReservedTokensToSplitsOf(uint256 projectId) internal returns (uint256 tokenCount) {
        // Get a reference to the number of tokens that need to be minted.
        tokenCount = pendingReservedTokenBalanceOf[projectId];

        // Revert if there are no pending reserved tokens
        if (tokenCount == 0) revert JBController_NoReservedTokens({projectId: projectId});

        // Get the ruleset to read the reserved percent from.
        JBRuleset memory ruleset = _currentRulesetOf(projectId);

        // Get a reference to the project's owner.
        address owner = _ownerOf(projectId);

        // Reset the pending reserved token balance.
        pendingReservedTokenBalanceOf[projectId] = 0;

        // Mint the tokens to this contract.
        IJBToken token = TOKENS.mintFor({holder: address(this), projectId: projectId, count: tokenCount});

        // Send reserved tokens to splits and get a reference to the amount left after the splits have all been paid.
        uint256 leftoverTokenCount = tokenCount == 0
            ? 0
            : _sendReservedTokensToSplitGroupOf({
                projectId: projectId,
                rulesetId: ruleset.id,
                groupId: JBSplitGroupIds.RESERVED_TOKENS,
                tokenCount: tokenCount,
                token: token
            });

        // Mint any leftover tokens to the project owner.
        if (leftoverTokenCount > 0) {
            _sendTokens({projectId: projectId, tokenCount: leftoverTokenCount, recipient: owner, token: token});
        }

        emit SendReservedTokensToSplits({
            rulesetId: ruleset.id,
            rulesetCycleNumber: ruleset.cycleNumber,
            projectId: projectId,
            owner: owner,
            tokenCount: tokenCount,
            leftoverAmount: leftoverTokenCount,
            caller: _msgSender()
        });
    }

    /// @notice Send tokens from this contract to a recipient.
    /// @param projectId The ID of the project the tokens belong to.
    /// @param tokenCount The number of tokens to send.
    /// @param recipient The address to send the tokens to.
    /// @param token The token to send, if one exists
    function _sendTokens(uint256 projectId, uint256 tokenCount, address recipient, IJBToken token) internal {
        if (token != IJBToken(address(0))) {
            IERC20(address(token)).safeTransfer({to: recipient, value: tokenCount});
        } else {
            TOKENS.transferCreditsFrom({
                holder: address(this), projectId: projectId, recipient: recipient, count: tokenCount
            });
        }
    }

    /// @notice Splits a token count into beneficiary and reserved portions.
    /// @param tokenCount The total token count, including reserved tokens.
    /// @param reservedPercent The reserved percent to apply, out of `JBConstants.MAX_RESERVED_PERCENT`.
    /// @return beneficiaryTokenCount The number of tokens for the beneficiary.
    /// @return reservedTokenCount The number of tokens to reserve.
    function _splitTokenCount(
        uint256 tokenCount,
        uint256 reservedPercent
    )
        internal
        pure
        returns (uint256 beneficiaryTokenCount, uint256 reservedTokenCount)
    {
        // Compute the beneficiary's portion after removing the reserved share.
        beneficiaryTokenCount = mulDiv({
            x: tokenCount,
            y: JBConstants.MAX_RESERVED_PERCENT - reservedPercent,
            denominator: JBConstants.MAX_RESERVED_PERCENT
        });

        // The remaining tokens are reserved.
        reservedTokenCount = tokenCount - beneficiaryTokenCount;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice The project's current ruleset.
    /// @param projectId The ID of the project to check.
    /// @return The project's current ruleset.
    function _currentRulesetOf(uint256 projectId) internal view returns (JBRuleset memory) {
        return RULESETS.currentOf(projectId);
    }

    /// @notice Indicates whether the provided address has mint permission for the project byway of the data hook.
    /// @param projectId The ID of the project to check.
    /// @param ruleset The ruleset to check.
    /// @param addr The address to check.
    /// @return A flag indicating if the provided address has mint permission for the project.
    function _hasDataHookMintPermissionFor(
        uint256 projectId,
        JBRuleset memory ruleset,
        address addr
    )
        internal
        view
        returns (bool)
    {
        address dataHook = ruleset.dataHook();

        return dataHook != address(0)
            && IJBRulesetDataHook(dataHook).hasMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: addr});
    }

    /// @notice Indicates whether the provided address is a terminal for the project.
    /// @param projectId The ID of the project to check.
    /// @param terminal The address to check.
    /// @return A flag indicating if the provided address is a terminal for the project.
    function _isTerminalOf(uint256 projectId, address terminal) internal view returns (bool) {
        return DIRECTORY.isTerminalOf({projectId: projectId, terminal: IJBTerminal(terminal)});
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

    /// @notice The owner of a project.
    /// @param projectId The ID of the project to get the owner of.
    /// @return The owner of the project.
    function _ownerOf(uint256 projectId) internal view returns (address) {
        return PROJECTS.ownerOf(projectId);
    }

    /// @notice The project's upcoming ruleset.
    /// @param projectId The ID of the project to check.
    /// @return The project's upcoming ruleset.
    function _upcomingRulesetOf(uint256 projectId) internal view returns (JBRuleset memory) {
        return RULESETS.upcomingOf(projectId);
    }
}
