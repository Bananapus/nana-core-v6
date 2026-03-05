// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A token that can be used by a project in the Juicebox ecosystem.
interface IJBToken {
    /// @notice Returns the balance of an account.
    /// @param account The account to get the balance of.
    /// @return The number of tokens owned by the account.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns whether this token can be added to a given project.
    /// @param projectId The ID of the project to check.
    /// @return A flag indicating whether the token can be added.
    function canBeAddedTo(uint256 projectId) external view returns (bool);

    /// @notice Returns the number of decimals used by the token.
    /// @return The number of decimals.
    function decimals() external view returns (uint8);

    /// @notice Returns the total supply of the token.
    /// @return The total supply.
    function totalSupply() external view returns (uint256);

    /// @notice Initializes the token with a name, symbol, and owner.
    /// @param name The token's name.
    /// @param symbol The token's symbol.
    /// @param owner The token contract's owner.
    function initialize(string memory name, string memory symbol, address owner) external;

    /// @notice Burns tokens from an account.
    /// @param account The address to burn tokens from.
    /// @param amount The amount of tokens to burn.
    function burn(address account, uint256 amount) external;

    /// @notice Mints tokens to an account.
    /// @param account The address to mint tokens to.
    /// @param amount The amount of tokens to mint.
    function mint(address account, uint256 amount) external;
}
