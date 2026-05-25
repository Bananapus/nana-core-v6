// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBDirectoryAccessControl} from "./IJBDirectoryAccessControl.sol";
import {IJBFundAccessLimits} from "./IJBFundAccessLimits.sol";
import {IJBPriceFeed} from "./IJBPriceFeed.sol";
import {IJBPrices} from "./IJBPrices.sol";
import {IJBProjects} from "./IJBProjects.sol";
import {IJBProjectUriRegistry} from "./IJBProjectUriRegistry.sol";
import {IJBRulesets} from "./IJBRulesets.sol";
import {IJBSplits} from "./IJBSplits.sol";
import {IJBToken} from "./IJBToken.sol";
import {IJBTokens} from "./IJBTokens.sol";
import {JBApprovalStatus} from "./../enums/JBApprovalStatus.sol";
import {JBRuleset} from "./../structs/JBRuleset.sol";
import {JBRulesetConfig} from "./../structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "./../structs/JBRulesetMetadata.sol";
import {JBRulesetWithMetadata} from "./../structs/JBRulesetWithMetadata.sol";
import {JBSplit} from "./../structs/JBSplit.sol";
import {JBSplitGroup} from "./../structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "./../structs/JBTerminalConfig.sol";

/// @notice The interface for the protocol's project controller — launch projects, queue rulesets, mint/burn tokens,
/// deploy ERC-20s, distribute reserved tokens, and manage all project configuration. This is the primary contract
/// project owners and frontends interact with.
interface IJBController is IERC165, IJBProjectUriRegistry, IJBDirectoryAccessControl {
    /// @notice Tokens were burned from a holder's balance.
    /// @param holder The address whose tokens were burned.
    /// @param projectId The ID of the project whose tokens were burned.
    /// @param tokenCount The number of tokens burned.
    /// @param memo A memo associated with the burn.
    /// @param caller The address that called the burn function.
    event BurnTokens(
        address indexed holder, uint256 indexed projectId, uint256 tokenCount, string memo, address caller
    );

    /// @notice An ERC-20 token was deployed for a project.
    /// @param projectId The ID of the project the token was deployed for.
    /// @param deployer The address that deployed the token.
    /// @param salt The salt used for deterministic deployment.
    /// @param saltHash The hash of the salt.
    /// @param caller The address that called the deploy function.
    event DeployERC20(
        uint256 indexed projectId, address indexed deployer, bytes32 salt, bytes32 saltHash, address caller
    );

    /// @notice A project was launched with its initial rulesets and terminals.
    /// @param rulesetId The ID of the first queued ruleset.
    /// @param projectId The ID of the newly created project.
    /// @param projectUri The metadata URI of the project.
    /// @param memo A memo associated with the launch.
    /// @param caller The address that called the launch function.
    event LaunchProject(uint256 rulesetId, uint256 projectId, string projectUri, string memo, address caller);

    /// @notice Rulesets were launched for an existing project.
    /// @param rulesetId The ID of the first queued ruleset.
    /// @param projectId The ID of the project.
    /// @param projectUri The metadata URI of the project.
    /// @param memo A memo associated with the launch.
    /// @param caller The address that called the launch function.
    event LaunchRulesets(uint256 rulesetId, uint256 projectId, string projectUri, string memo, address caller);

    /// @notice Tokens were minted for a beneficiary.
    /// @param beneficiary The address that received the minted tokens.
    /// @param projectId The ID of the project whose tokens were minted.
    /// @param tokenCount The total number of tokens minted, including reserved tokens.
    /// @param beneficiaryTokenCount The number of tokens minted for the beneficiary.
    /// @param memo A memo associated with the mint.
    /// @param reservedPercent The reserved percent applied to the mint, out of `JBConstants.MAX_RESERVED_PERCENT`.
    /// @param caller The address that called the mint function.
    event MintTokens(
        address indexed beneficiary,
        uint256 indexed projectId,
        uint256 tokenCount,
        uint256 beneficiaryTokenCount,
        string memo,
        uint256 reservedPercent,
        address caller
    );

    /// @notice Rulesets were queued for a project.
    /// @param rulesetId The ID of the first queued ruleset.
    /// @param projectId The ID of the project.
    /// @param memo A memo associated with the queue operation.
    /// @param caller The address that called the queue function.
    event QueueRulesets(uint256 rulesetId, uint256 projectId, string memo, address caller);

    /// @notice A reserved token distribution to a split reverted.
    /// @param projectId The ID of the project.
    /// @param split The split that the distribution reverted for.
    /// @param tokenCount The number of tokens that failed to distribute.
    /// @param reason The revert reason.
    /// @param caller The address that called the distribution function.
    event ReservedDistributionReverted(
        uint256 indexed projectId, JBSplit split, uint256 tokenCount, bytes reason, address caller
    );

    /// @notice A split hook's `processSplitWith` call reverted.
    /// @param projectId The ID of the project.
    /// @param hook The split hook that reverted.
    /// @param reason The revert reason.
    event SplitHookReverted(uint256 indexed projectId, address hook, bytes reason);

    /// @notice Reserved tokens were sent to a specific split.
    /// @param projectId The ID of the project.
    /// @param rulesetId The ID of the ruleset during the distribution.
    /// @param groupId The ID of the split group.
    /// @param split The split that received the tokens.
    /// @param tokenCount The number of tokens sent to the split.
    /// @param caller The address that called the distribution function.
    event SendReservedTokensToSplit(
        uint256 indexed projectId,
        uint256 indexed rulesetId,
        uint256 indexed groupId,
        JBSplit split,
        uint256 tokenCount,
        address caller
    );

    /// @notice Reserved tokens were distributed to a project's splits.
    /// @param rulesetId The ID of the ruleset during the distribution.
    /// @param rulesetCycleNumber The cycle number of the ruleset.
    /// @param projectId The ID of the project.
    /// @param owner The project's owner.
    /// @param tokenCount The total number of reserved tokens distributed.
    /// @param leftoverAmount The number of tokens left over after distribution.
    /// @param caller The address that called the distribution function.
    event SendReservedTokensToSplits(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address owner,
        uint256 tokenCount,
        uint256 leftoverAmount,
        address caller
    );

    /// @notice A project's metadata URI was set.
    /// @param projectId The ID of the project.
    /// @param uri The metadata URI that was set.
    /// @param caller The address that called the set URI function.
    event SetUri(uint256 indexed projectId, string uri, address caller);

    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The contract that stores fund access limits for each project.
    function FUND_ACCESS_LIMITS() external view returns (IJBFundAccessLimits);

    /// @notice The address of the contract that manages omnichain ruleset ops.
    function OMNICHAIN_RULESET_OPERATOR() external view returns (address);

    /// @notice The contract that stores prices for each project.
    function PRICES() external view returns (IJBPrices);

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The contract storing and managing project rulesets.
    function RULESETS() external view returns (IJBRulesets);

    /// @notice The contract that stores splits for each project.
    function SPLITS() external view returns (IJBSplits);

    /// @notice The contract that manages token minting and burning.
    function TOKENS() external view returns (IJBTokens);

    /// @notice Returns an array of a project's rulesets with metadata, sorted from latest to earliest.
    /// @param projectId The ID of the project to get the rulesets of.
    /// @param startingId The ID of the ruleset to begin with. If 0, the project's latest ruleset is used.
    /// @param size The maximum number of rulesets to return.
    /// @return rulesets The array of rulesets with their metadata.
    function allRulesetsOf(
        uint256 projectId,
        uint256 startingId,
        uint256 size
    )
        external
        view
        returns (JBRulesetWithMetadata[] memory rulesets);

    /// @notice Returns a project's currently active ruleset and its metadata.
    /// @param projectId The ID of the project to get the current ruleset of.
    /// @return ruleset The current ruleset.
    /// @return metadata The current ruleset's metadata.
    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata);

    /// @notice Returns the ruleset and metadata for a specific ruleset ID.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @param rulesetId The ID of the ruleset to look up.
    /// @return ruleset The ruleset.
    /// @return metadata The ruleset's metadata.
    function getRulesetOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata);

    /// @notice Returns the latest queued ruleset for a project, its metadata, and its approval status.
    /// @param projectId The ID of the project to get the latest queued ruleset of.
    /// @return ruleset The latest queued ruleset.
    /// @return metadata The ruleset's metadata.
    /// @return approvalStatus The ruleset's approval status.
    function latestQueuedRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata, JBApprovalStatus approvalStatus);

    /// @notice Returns a project's unrealized reserved token balance.
    /// @param projectId The ID of the project to get the pending reserved token balance of.
    /// @return The pending reserved token balance.
    function pendingReservedTokenBalanceOf(uint256 projectId) external view returns (uint256);

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
        returns (uint256 beneficiaryTokenCount, uint256 reservedTokenCount);

    /// @notice Returns a project's total token supply including pending reserved tokens.
    /// @param projectId The ID of the project to get the total token supply of.
    /// @return The total supply including pending reserved tokens.
    function totalTokenSupplyWithReservedTokensOf(uint256 projectId) external view returns (uint256);

    /// @notice Returns a project's upcoming ruleset and its metadata.
    /// @param projectId The ID of the project to get the upcoming ruleset of.
    /// @return ruleset The upcoming ruleset.
    /// @return metadata The upcoming ruleset's metadata.
    function upcomingRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata);

    /// @notice Adds a price feed for a project.
    /// @param projectId The ID of the project to add the feed for.
    /// @param pricingCurrency The currency the feed's output price is in terms of.
    /// @param unitCurrency The currency the feed prices.
    /// @param feed The price feed to add.
    function addPriceFeedFor(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        IJBPriceFeed feed
    )
        external;

    /// @notice Burns a holder's project tokens or unclaimed project token credits, removing them from supply.
    /// @param holder The address whose project tokens (or credits) are being burned.
    /// @param projectId The ID of the project whose project tokens are being burned.
    /// @param tokenCount The number of project tokens (or credits) to burn.
    /// @param memo A memo to pass along to the emitted event.
    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata memo) external;

    /// @notice Converts project token credits into the project's ERC-20 representation, sending them to a beneficiary.
    /// @param holder The address whose project token credits are being redeemed.
    /// @param projectId The ID of the project whose project tokens are being claimed.
    /// @param tokenCount The number of project token credits to convert into ERC-20 project tokens.
    /// @param beneficiary The account that receives the resulting ERC-20 project tokens.
    function claimTokensFor(address holder, uint256 projectId, uint256 tokenCount, address beneficiary) external;

    /// @notice Deploys an ERC-20 token for a project.
    /// @param projectId The ID of the project to deploy the ERC-20 for.
    /// @param name The ERC-20's name.
    /// @param symbol The ERC-20's symbol.
    /// @param salt The salt used for deterministic ERC-1167 clone deployment.
    /// @return token The address of the deployed token.
    function deployERC20For(
        uint256 projectId,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    )
        external
        returns (IJBToken token);

    /// @notice Creates a project, queues its initial rulesets, and sets up its terminals.
    /// @param owner The project's owner. The project ERC-721 will be minted to this address.
    /// @param projectUri The project's metadata URI.
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
        returns (uint256 projectId);

    /// @notice Queues a project's initial rulesets and sets up terminals for it.
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
        returns (uint256 rulesetId);

    /// @notice Mints new project tokens (or credits) to a beneficiary, optionally reserving a portion for the ruleset's
    /// reserved splits.
    /// @param projectId The ID of the project whose project tokens are being minted.
    /// @param tokenCount The total number of project tokens to mint (the beneficiary's share plus the reserved share if
    /// `useReservedPercent` is true).
    /// @param beneficiary The address that receives the non-reserved portion of the minted project tokens.
    /// @param memo A memo to pass along to the emitted event.
    /// @param useReservedPercent Whether to apply the ruleset's reserved percent.
    /// @return beneficiaryTokenCount The number of project tokens minted to `beneficiary` (excluding the reserved
    /// share).
    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        string calldata memo,
        bool useReservedPercent
    )
        external
        returns (uint256 beneficiaryTokenCount);

    /// @notice Queues one or more rulesets to the end of a project's ruleset queue.
    /// @param projectId The ID of the project to queue rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the last successfully queued ruleset.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo
    )
        external
        returns (uint256 rulesetId);

    /// @notice Sends a project's pending reserved tokens to its reserved token splits.
    /// @param projectId The ID of the project to send reserved tokens for.
    /// @return The amount of reserved tokens minted and sent.
    function sendReservedTokensToSplitsOf(uint256 projectId) external returns (uint256);

    /// @notice Sets a project's split groups.
    /// @param projectId The ID of the project to set the split groups of.
    /// @param rulesetId The ID of the ruleset the split groups should be active in.
    /// @param splitGroups An array of split groups to set.
    function setSplitGroupsOf(uint256 projectId, uint256 rulesetId, JBSplitGroup[] calldata splitGroups) external;

    /// @notice Sets a project's token.
    /// @param projectId The ID of the project to set the token of.
    /// @param token The new token's address.
    function setTokenFor(uint256 projectId, IJBToken token) external;

    /// @notice Sets the name and symbol of a project's token.
    /// @param projectId The ID of the project to update the token for.
    /// @param name The new name.
    /// @param symbol The new symbol.
    function setTokenMetadataOf(uint256 projectId, string calldata name, string calldata symbol) external;

    /// @notice Transfers credits from one address to another.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project to transfer credits for.
    /// @param recipient The address to transfer credits to.
    /// @param creditCount The number of credits to transfer.
    function transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 creditCount) external;
}
