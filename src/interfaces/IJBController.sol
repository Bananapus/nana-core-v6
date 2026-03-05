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
import {IJBTerminal} from "./IJBTerminal.sol";
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

/// @notice Coordinates rulesets and project tokens, and is the entry point for most operations related to rulesets and
/// project tokens.
interface IJBController is IERC165, IJBProjectUriRegistry, IJBDirectoryAccessControl {
    event BurnTokens(
        address indexed holder, uint256 indexed projectId, uint256 tokenCount, string memo, address caller
    );
    event DeployERC20(
        uint256 indexed projectId, address indexed deployer, bytes32 salt, bytes32 saltHash, address caller
    );
    event LaunchProject(uint256 rulesetId, uint256 projectId, string projectUri, string memo, address caller);
    event LaunchRulesets(uint256 rulesetId, uint256 projectId, string memo, address caller);
    event MintTokens(
        address indexed beneficiary,
        uint256 indexed projectId,
        uint256 tokenCount,
        uint256 beneficiaryTokenCount,
        string memo,
        uint256 reservedPercent,
        address caller
    );
    event PrepMigration(uint256 indexed projectId, address from, address caller);
    event QueueRulesets(uint256 rulesetId, uint256 projectId, string memo, address caller);
    event ReservedDistributionReverted(
        uint256 indexed projectId, JBSplit split, uint256 tokenCount, bytes reason, address caller
    );
    event SendReservedTokensToSplit(
        uint256 indexed projectId,
        uint256 indexed rulesetId,
        uint256 indexed groupId,
        JBSplit split,
        uint256 tokenCount,
        address caller
    );
    event SendReservedTokensToSplits(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address owner,
        uint256 tokenCount,
        uint256 leftoverAmount,
        address caller
    );
    event SetUri(uint256 indexed projectId, string uri, address caller);

    /// @notice The directory of terminals and controllers for projects.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The contract that stores fund access limits for each project.
    function FUND_ACCESS_LIMITS() external view returns (IJBFundAccessLimits);

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

    /// @notice The address of the contract that manages omnichain ruleset ops.
    function OMNICHAIN_RULESET_OPERATOR() external view returns (address);

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
    /// @param unitCurrency The currency being priced by the feed.
    /// @param feed The price feed to add.
    function addPriceFeed(uint256 projectId, uint256 pricingCurrency, uint256 unitCurrency, IJBPriceFeed feed) external;

    /// @notice Burns a holder's project tokens or credits.
    /// @param holder The address whose tokens are being burned.
    /// @param projectId The ID of the project whose tokens are being burned.
    /// @param tokenCount The number of tokens to burn.
    /// @param memo A memo to pass along to the emitted event.
    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata memo) external;

    /// @notice Redeems credits to claim tokens into a beneficiary's account.
    /// @param holder The address to redeem credits from.
    /// @param projectId The ID of the project whose tokens are being claimed.
    /// @param tokenCount The number of tokens to claim.
    /// @param beneficiary The account the claimed tokens will go to.
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
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the last successfully queued ruleset.
    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo
    )
        external
        returns (uint256 rulesetId);

    /// @notice Mints new project tokens or credits to a beneficiary, optionally reserving a portion.
    /// @param projectId The ID of the project whose tokens are being minted.
    /// @param tokenCount The number of tokens to mint, including any reserved tokens.
    /// @param beneficiary The address which will receive the non-reserved tokens.
    /// @param memo A memo to pass along to the emitted event.
    /// @param useReservedPercent Whether to apply the ruleset's reserved percent.
    /// @return beneficiaryTokenCount The number of tokens minted for the beneficiary.
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

    /// @notice Transfers credits from one address to another.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project whose credits are being transferred.
    /// @param recipient The address to transfer credits to.
    /// @param creditCount The number of credits to transfer.
    function transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 creditCount) external;
}
