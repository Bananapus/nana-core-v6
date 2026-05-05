// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBToken} from "./IJBToken.sol";

/// @notice Interface for the dual-token system. Manages credits (internal balances) and ERC-20 tokens for every
/// project. Credits are minted first and can later be claimed as transferable ERC-20 tokens.
interface IJBTokens {
    /// @notice Tokens or credits were burned from a holder's balance.
    /// @param holder The address whose tokens were burned.
    /// @param projectId The ID of the project whose tokens were burned.
    /// @param count The number of tokens burned.
    /// @param creditBalance The holder's remaining credit balance after the burn.
    /// @param tokenBalance The holder's remaining token balance after the burn.
    /// @param caller The address that called the burn function.
    event Burn(
        address indexed holder,
        uint256 indexed projectId,
        uint256 count,
        uint256 creditBalance,
        uint256 tokenBalance,
        address caller
    );

    /// @notice Credits were claimed as ERC-20 tokens.
    /// @param holder The address whose credits were claimed.
    /// @param projectId The ID of the project whose tokens were claimed.
    /// @param creditBalance The holder's remaining credit balance after the claim.
    /// @param count The number of tokens claimed.
    /// @param beneficiary The address that received the claimed tokens.
    /// @param caller The address that called the claim function.
    event ClaimTokens(
        address indexed holder,
        uint256 indexed projectId,
        uint256 creditBalance,
        uint256 count,
        address beneficiary,
        address caller
    );

    /// @notice An ERC-20 token was deployed for a project.
    /// @param projectId The ID of the project the token was deployed for.
    /// @param token The deployed token.
    /// @param name The token's name.
    /// @param symbol The token's symbol.
    /// @param salt The salt used for deterministic deployment.
    /// @param caller The address that deployed the token.
    event DeployERC20(
        uint256 indexed projectId, IJBToken indexed token, string name, string symbol, bytes32 salt, address caller
    );

    /// @notice Tokens or credits were minted for a holder.
    /// @param holder The address that received the minted tokens.
    /// @param projectId The ID of the project whose tokens were minted.
    /// @param count The number of tokens minted.
    /// @param tokensWereClaimed Whether the tokens were claimed as ERC-20 tokens.
    /// @param caller The address that called the mint function.
    event Mint(
        address indexed holder, uint256 indexed projectId, uint256 count, bool tokensWereClaimed, address caller
    );

    /// @notice A project's token was set.
    /// @param projectId The ID of the project whose token was set.
    /// @param token The token that was set.
    /// @param caller The address that set the token.
    event SetToken(uint256 indexed projectId, IJBToken indexed token, address caller);

    /// @notice A project token's name and symbol were updated.
    /// @param projectId The ID of the project whose token was updated.
    /// @param name The new token name.
    /// @param symbol The new token symbol.
    /// @param caller The address that called the function.
    event SetTokenMetadata(uint256 indexed projectId, string name, string symbol, address caller);

    /// @notice Credits were transferred from one holder to another.
    /// @param holder The address that transferred the credits.
    /// @param projectId The ID of the project whose credits were transferred.
    /// @param recipient The address that received the credits.
    /// @param count The number of credits transferred.
    /// @param caller The address that called the transfer function.
    event TransferCredits(
        address indexed holder, uint256 indexed projectId, address indexed recipient, uint256 count, address caller
    );

    /// @notice Returns the credit balance for a holder and project.
    /// @param holder The address to get the credit balance of.
    /// @param projectId The ID of the project to get the credit balance for.
    /// @return The credit balance.
    function creditBalanceOf(address holder, uint256 projectId) external view returns (uint256);

    /// @notice The project ID that a given ERC-20 token contract is associated with.
    /// @param token The token to get the project ID of.
    /// @return The project ID.
    function projectIdOf(IJBToken token) external view returns (uint256);

    /// @notice Returns the token for a project.
    /// @param projectId The ID of the project to get the token of.
    /// @return The project's token.
    function tokenOf(uint256 projectId) external view returns (IJBToken);

    /// @notice Returns the total balance (tokens + credits) for a holder and project.
    /// @param holder The address to get the total balance of.
    /// @param projectId The ID of the project to get the total balance for.
    /// @return balance The combined token and credit balance.
    function totalBalanceOf(address holder, uint256 projectId) external view returns (uint256 balance);

    /// @notice Returns the total credit supply for a project.
    /// @param projectId The ID of the project to get the total credit supply of.
    /// @return The total credit supply.
    function totalCreditSupplyOf(uint256 projectId) external view returns (uint256);

    /// @notice Returns the total supply (tokens + credits) for a project.
    /// @param projectId The ID of the project to get the total supply of.
    /// @return The total supply.
    function totalSupplyOf(uint256 projectId) external view returns (uint256);

    /// @notice Burns tokens and/or credits from a holder's balance.
    /// @param holder The address to burn tokens from.
    /// @param projectId The ID of the project to burn tokens for.
    /// @param count The number of tokens to burn.
    function burnFrom(address holder, uint256 projectId, uint256 count) external;

    /// @notice Claims tokens from a holder's credits into a beneficiary's account.
    /// @param holder The address to claim credits from.
    /// @param projectId The ID of the project whose tokens are to claim.
    /// @param count The number of tokens to claim.
    /// @param beneficiary The address to send the claimed tokens to.
    function claimTokensFor(address holder, uint256 projectId, uint256 count, address beneficiary) external;

    /// @notice Deploys an ERC-20 token for a project.
    /// @param projectId The ID of the project to deploy the ERC-20 for.
    /// @param name The ERC-20's name.
    /// @param symbol The ERC-20's symbol.
    /// @param salt The salt used for deterministic clone deployment.
    /// @return token The deployed token.
    function deployERC20For(
        uint256 projectId,
        string calldata name,
        string calldata symbol,
        bytes32 salt
    )
        external
        returns (IJBToken token);

    /// @notice Mints tokens or credits for a holder.
    /// @param holder The address to mint tokens for.
    /// @param projectId The ID of the project whose tokens are to mint.
    /// @param count The number of tokens to mint.
    /// @return token The project's token, if one exists.
    function mintFor(address holder, uint256 projectId, uint256 count) external returns (IJBToken token);

    /// @notice Sets a project's token.
    /// @param projectId The ID of the project to set the token of.
    /// @param token The token to set.
    function setTokenFor(uint256 projectId, IJBToken token) external;

    /// @notice Sets the name and symbol of a project's token.
    /// @param projectId The ID of the project to update the token for.
    /// @param name The new name.
    /// @param symbol The new symbol.
    function setTokenMetadataFor(uint256 projectId, string calldata name, string calldata symbol) external;

    /// @notice Transfers credits from one holder to another.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project whose credits are to transfer.
    /// @param recipient The address to transfer credits to.
    /// @param count The number of credits to transfer.
    function transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 count) external;
}
