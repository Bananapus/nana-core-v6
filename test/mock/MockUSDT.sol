// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Mimics Tether (USDT) whose transfer/transferFrom/approve return void instead of bool.
/// @dev Uses inline assembly to return empty data (no bool), matching USDT's on-chain behavior.
/// This breaks naive IERC20 callers that expect a bool return value.
contract MockUSDT {
    // Token metadata matching USDT's 6-decimal convention.
    string public name = "Mock Tether USD";
    // Short ticker symbol for the mock token.
    string public symbol = "USDT";
    // USDT uses 6 decimals, not 18 like most ERC-20 tokens.
    uint8 public decimals = 6;
    // Running total of all minted tokens.
    uint256 public totalSupply;

    // Maps each address to its token balance.
    mapping(address => uint256) public balanceOf;
    // Maps owner => spender => allowance for delegated transfers.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Mints tokens to a recipient (test helper, not part of USDT interface).
    /// @param to The address to receive newly minted tokens.
    /// @param amount The number of tokens to mint.
    function mint(address to, uint256 amount) external {
        // Credit the recipient's balance with the minted amount.
        balanceOf[to] += amount;
        // Increase the total supply to reflect the new tokens.
        totalSupply += amount;
    }

    /// @notice Sets the spender's allowance. Returns VOID like real USDT.
    /// @param spender The address authorized to spend tokens.
    /// @param amount The maximum amount the spender can transfer.
    function approve(address spender, uint256 amount) external {
        // Record the new allowance for the caller-spender pair.
        allowance[msg.sender][spender] = amount;
        // Use assembly to return without any data (void), matching USDT behavior.
        assembly {
            return(0, 0)
        }
    }

    /// @notice Transfers tokens from caller to recipient. Returns VOID like real USDT.
    /// @param to The address to receive the tokens.
    /// @param amount The number of tokens to transfer.
    function transfer(address to, uint256 amount) external {
        // Ensure the sender has enough tokens to cover the transfer.
        require(balanceOf[msg.sender] >= amount, "MockUSDT: insufficient balance");
        // Debit the sender's balance by the transfer amount.
        balanceOf[msg.sender] -= amount;
        // Credit the recipient's balance with the transferred tokens.
        balanceOf[to] += amount;
        // Use assembly to return without any data (void), matching USDT behavior.
        assembly {
            return(0, 0)
        }
    }

    /// @notice Transfers tokens on behalf of an owner. Returns VOID like real USDT.
    /// @param from The address whose tokens are being spent.
    /// @param to The address to receive the tokens.
    /// @param amount The number of tokens to transfer.
    function transferFrom(address from, address to, uint256 amount) external {
        // Ensure the owner has enough tokens for the transfer.
        require(balanceOf[from] >= amount, "MockUSDT: insufficient balance");
        // Ensure the caller is authorized to spend at least this amount.
        require(allowance[from][msg.sender] >= amount, "MockUSDT: insufficient allowance");
        // Reduce the caller's remaining allowance by the transferred amount.
        allowance[from][msg.sender] -= amount;
        // Debit the owner's balance by the transfer amount.
        balanceOf[from] -= amount;
        // Credit the recipient's balance with the transferred tokens.
        balanceOf[to] += amount;
        // Use assembly to return without any data (void), matching USDT behavior.
        assembly {
            return(0, 0)
        }
    }
}
