// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBToken} from "./IJBToken.sol";

/// @notice Manages minting, burning, and balances of projects' tokens and token credits.
interface IJBTokens {
    event DeployERC20(
        uint256 indexed projectId, IJBToken indexed token, string name, string symbol, bytes32 salt, address caller
    );
    event Burn(
        address indexed holder,
        uint256 indexed projectId,
        uint256 count,
        uint256 creditBalance,
        uint256 tokenBalance,
        address caller
    );
    event ClaimTokens(
        address indexed holder,
        uint256 indexed projectId,
        uint256 creditBalance,
        uint256 count,
        address beneficiary,
        address caller
    );
    event Mint(
        address indexed holder, uint256 indexed projectId, uint256 count, bool tokensWereClaimed, address caller
    );
    event SetToken(uint256 indexed projectId, IJBToken indexed token, address caller);
    event TransferCredits(
        address indexed holder, uint256 indexed projectId, address indexed recipient, uint256 count, address caller
    );

    /// @notice Returns the credit balance for a holder and project.
    /// @param holder The address to get the credit balance of.
    /// @param projectId The ID of the project to get the credit balance for.
    /// @return The credit balance.
    function creditBalanceOf(address holder, uint256 projectId) external view returns (uint256);

    /// @notice Returns the project ID associated with a token.
    /// @param token The token to get the project ID of.
    /// @return The project ID.
    function projectIdOf(IJBToken token) external view returns (uint256);

    /// @notice Returns the token for a project.
    /// @param projectId The ID of the project to get the token of.
    /// @return The project's token.
    function tokenOf(uint256 projectId) external view returns (IJBToken);

    /// @notice Returns the total credit supply for a project.
    /// @param projectId The ID of the project to get the total credit supply of.
    /// @return The total credit supply.
    function totalCreditSupplyOf(uint256 projectId) external view returns (uint256);

    /// @notice Returns the total balance (tokens + credits) for a holder and project.
    /// @param holder The address to get the total balance of.
    /// @param projectId The ID of the project to get the total balance for.
    /// @return balance The combined token and credit balance.
    function totalBalanceOf(address holder, uint256 projectId) external view returns (uint256 balance);

    /// @notice Returns the total supply (tokens + credits) for a project.
    /// @param projectId The ID of the project to get the total supply of.
    /// @return The total supply.
    function totalSupplyOf(uint256 projectId) external view returns (uint256);

    /// @notice Burns tokens and/or credits from a holder's balance.
    /// @param holder The address to burn tokens from.
    /// @param projectId The ID of the project whose tokens are being burned.
    /// @param count The number of tokens to burn.
    function burnFrom(address holder, uint256 projectId, uint256 count) external;

    /// @notice Claims tokens from a holder's credits into a beneficiary's account.
    /// @param holder The address to claim credits from.
    /// @param projectId The ID of the project whose tokens are being claimed.
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
    /// @param projectId The ID of the project whose tokens are being minted.
    /// @param count The number of tokens to mint.
    /// @return token The project's token, if one exists.
    function mintFor(address holder, uint256 projectId, uint256 count) external returns (IJBToken token);

    /// @notice Sets a project's token.
    /// @param projectId The ID of the project to set the token of.
    /// @param token The token to set.
    function setTokenFor(uint256 projectId, IJBToken token) external;

    /// @notice Transfers credits from one holder to another.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project whose credits are being transferred.
    /// @param recipient The address to transfer credits to.
    /// @param count The number of credits to transfer.
    function transferCreditsFrom(address holder, uint256 projectId, address recipient, uint256 count) external;
}
