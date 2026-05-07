// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {JBControlled} from "./abstract/JBControlled.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBToken} from "./interfaces/IJBToken.sol";
import {IJBTokens} from "./interfaces/IJBTokens.sol";

/// @notice Manages the dual-token system for every Juicebox project. When someone pays a project, the controller mints
/// tokens here — initially as internal "credits" tracked by this contract. Once a project deploys or attaches an
/// ERC-20, holders can claim their credits into transferable ERC-20 tokens. Burns always consume credits first.
/// @dev The total supply reported by `totalSupplyOf` is credits + ERC-20 supply combined, and is used by the terminal
/// to calculate cash-out values. Projects can deploy a new ERC-20 via `deployERC20For` or bring their own via
/// `setTokenFor` (must be 18 decimals).
contract JBTokens is JBControlled, IJBTokens {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBTokens_EmptyName(uint256 projectId);
    error JBTokens_EmptySymbol(uint256 projectId);
    error JBTokens_EmptyToken(uint256 projectId);
    error JBTokens_InsufficientCredits(uint256 count, uint256 creditBalance);
    error JBTokens_InsufficientTokensToBurn(uint256 count, uint256 tokenBalance);
    error JBTokens_OverflowAlert(uint256 value, uint256 limit);
    error JBTokens_ProjectAlreadyHasToken(IJBToken token);
    error JBTokens_TokenAlreadyBeingUsed(uint256 projectId);
    error JBTokens_TokenCantBeAdded(uint256 projectId);
    error JBTokens_TokenNotFound(uint256 projectId);
    error JBTokens_TokensMustHave18Decimals(uint256 decimals);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice A reference to the token implementation that'll be cloned as projects deploy their own tokens.
    IJBToken public immutable TOKEN;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Each holder's credit balance for each project.
    /// @custom:param holder The credit holder.
    /// @custom:param projectId The ID of the project to which the credits belong.
    mapping(address holder => mapping(uint256 projectId => uint256)) public override creditBalanceOf;

    /// @notice The project ID that a given ERC-20 token is associated with.
    /// @custom:param token The address of the token associated with the project.
    mapping(IJBToken token => uint256) public override projectIdOf;

    /// @notice Each project's attached token contract.
    /// @custom:param projectId The ID of the project the token belongs to.
    mapping(uint256 projectId => IJBToken) public override tokenOf;

    /// @notice The total supply of credits for each project.
    /// @custom:param projectId The ID of the project to which the credits belong.
    mapping(uint256 projectId => uint256) public override totalCreditSupplyOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param token The implementation of the token contract that project can deploy.
    constructor(IJBDirectory directory, IJBToken token) JBControlled(directory) {
        TOKEN = token;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Destroy a holder's tokens for a project. Credits (internal balance) are burned first; if more tokens
    /// need burning, the remaining amount is burned from the holder's ERC-20 balance.
    /// @dev Only a project's current controller can burn its tokens. Called during cash outs and manual burns.
    /// @param holder The address to burn tokens from.
    /// @param projectId The ID of the project the burned tokens belong to.
    /// @param count The number of tokens to burn.
    function burnFrom(address holder, uint256 projectId, uint256 count) external override onlyControllerOf(projectId) {
        // Get a reference to the project's current token.
        IJBToken token = tokenOf[projectId];

        // Get a reference to the amount of credits the holder has.
        uint256 creditBalance = creditBalanceOf[holder][projectId];

        // Get a reference to the amount of the project's current token the holder has in their wallet.
        uint256 tokenBalance = token == IJBToken(address(0)) ? 0 : token.balanceOf(holder);

        // There must be enough tokens to burn across the holder's combined token and credit balance.
        if (count > tokenBalance + creditBalance) {
            revert JBTokens_InsufficientTokensToBurn({count: count, tokenBalance: tokenBalance + creditBalance});
        }

        // The amount of tokens to burn.
        uint256 tokensToBurn;

        // Get a reference to how many tokens should be burned
        if (tokenBalance != 0) {
            // Burn credits before tokens.
            unchecked {
                tokensToBurn = creditBalance < count ? count - creditBalance : 0;
            }
        }

        // The amount of credits to burn.
        uint256 creditsToBurn;
        unchecked {
            creditsToBurn = count - tokensToBurn;
        }

        // Subtract the burned credits from the credit balance and credit supply.
        if (creditsToBurn > 0) {
            creditBalanceOf[holder][projectId] = creditBalanceOf[holder][projectId] - creditsToBurn;
            totalCreditSupplyOf[projectId] = totalCreditSupplyOf[projectId] - creditsToBurn;
        }

        emit Burn({
            holder: holder,
            projectId: projectId,
            count: count,
            creditBalance: creditBalance,
            tokenBalance: tokenBalance,
            caller: msg.sender
        });

        // Burn the tokens.
        if (tokensToBurn > 0) token.burn({account: holder, amount: tokensToBurn});
    }

    /// @notice Convert internal credits into transferable ERC-20 tokens. The credits are subtracted from the holder's
    /// balance and the equivalent ERC-20 tokens are minted to the beneficiary. The project must have an ERC-20
    /// deployed or attached.
    /// @dev Only a project's controller can claim that project's tokens.
    /// @param holder The owner of the credits to redeem.
    /// @param projectId The ID of the project to claim tokens for.
    /// @param count The number of tokens to claim.
    /// @param beneficiary The account into which the claimed tokens will go.
    function claimTokensFor(
        address holder,
        uint256 projectId,
        uint256 count,
        address beneficiary
    )
        external
        override
        onlyControllerOf(projectId)
    {
        // Get a reference to the project's current token.
        IJBToken token = tokenOf[projectId];

        // The project must have a token contract attached.
        if (token == IJBToken(address(0))) revert JBTokens_TokenNotFound({projectId: projectId});

        // Get a reference to the amount of credits the holder has.
        uint256 creditBalance = creditBalanceOf[holder][projectId];

        // There must be enough credits to claim.
        if (count > creditBalance) revert JBTokens_InsufficientCredits(count, creditBalance);

        unchecked {
            // Subtract the claim amount from the holder's credit balance.
            creditBalanceOf[holder][projectId] = creditBalance - count;

            // Subtract the claim amount from the project's total credit supply.
            totalCreditSupplyOf[projectId] -= count;
        }

        emit ClaimTokens({
            holder: holder,
            projectId: projectId,
            creditBalance: creditBalance,
            count: count,
            beneficiary: beneficiary,
            caller: msg.sender
        });

        // Mint the equivalent amount of the project's token for the holder.
        token.mint({account: beneficiary, amount: count});
    }

    /// @notice Deploy a new ERC-20 token for a project (cloned from the `TOKEN` implementation). Once deployed, holders
    /// can claim their credits into this transferable token. A project can only have one token — this reverts if one
    /// already exists.
    /// @dev Only a project's controller can deploy its token.
    /// @param projectId The ID of the project to deploy an ERC-20 token for.
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
        onlyControllerOf(projectId)
        returns (IJBToken token)
    {
        // There must be a name.
        if (bytes(name).length == 0) revert JBTokens_EmptyName({projectId: projectId});

        // There must be a symbol.
        if (bytes(symbol).length == 0) revert JBTokens_EmptySymbol({projectId: projectId});

        // The project shouldn't already have a token.
        if (tokenOf[projectId] != IJBToken(address(0))) revert JBTokens_ProjectAlreadyHasToken(tokenOf[projectId]);

        token = salt == bytes32(0)
            ? IJBToken(Clones.clone(address(TOKEN)))
            : IJBToken(
                Clones.cloneDeterministic({
                    implementation: address(TOKEN), salt: keccak256(abi.encode(msg.sender, salt))
                })
            );

        // Store the token contract.
        tokenOf[projectId] = token;

        // Store the project for the token.
        projectIdOf[token] = projectId;

        emit DeployERC20({
            projectId: projectId, token: token, name: name, symbol: symbol, salt: salt, caller: msg.sender
        });

        // Initialize the token.
        token.initialize({name: name, symbol: symbol, tokens: address(this)});
    }

    /// @notice Create new tokens for a holder. If the project has an ERC-20 deployed, tokens are minted directly to
    /// the holder's wallet. Otherwise, they're tracked as internal credits that can be claimed later.
    /// @dev Only a project's current controller can mint its tokens. Called during payments and reserved token
    /// distribution.
    /// @param holder The address receiving the new tokens.
    /// @param projectId The ID of the project to which the tokens belong.
    /// @param count The number of tokens to mint.
    /// @return token The address of the token that was minted, if the project has a token.
    function mintFor(
        address holder,
        uint256 projectId,
        uint256 count
    )
        external
        override
        onlyControllerOf(projectId)
        returns (IJBToken token)
    {
        // Get a reference to the project's current token.
        token = tokenOf[projectId];

        // Save a reference to whether there a token exists.
        bool tokensWereClaimed = token != IJBToken(address(0));

        // Cache the total supply to avoid a redundant external call on revert.
        uint256 supply = totalSupplyOf(projectId);

        // The total supply after minting can't exceed the maximum value storable in a uint208.
        if (supply + count > type(uint208).max) {
            revert JBTokens_OverflowAlert({value: supply + count, limit: type(uint208).max});
        }

        if (tokensWereClaimed) {
            // If tokens should be claimed, mint tokens into the holder's wallet.
            token.mint({account: holder, amount: count});
        } else {
            // Otherwise, add the tokens to their credits and the credit supply.
            creditBalanceOf[holder][projectId] += count;
            totalCreditSupplyOf[projectId] += count;
        }

        emit Mint({
            holder: holder, projectId: projectId, count: count, tokensWereClaimed: tokensWereClaimed, caller: msg.sender
        });
    }

    /// @notice Attach an existing ERC-20 token to a project (instead of deploying a new one). The token must use 18
    /// decimals and must not already be attached to another project. A project can only have one token.
    /// @dev Only a project's controller can set its token.
    /// @dev WARNING: If the ERC-20 has supply minted outside this contract, that supply will be included in
    /// `totalSupplyOf` and dilute cash-out values for all holders. Ensure the token's supply is appropriate before
    /// calling.
    /// @param projectId The ID of the project to set the token of.
    /// @param token The new token's address.
    function setTokenFor(uint256 projectId, IJBToken token) external override onlyControllerOf(projectId) {
        // Can't set to the zero address.
        if (token == IJBToken(address(0))) revert JBTokens_EmptyToken(projectId);

        // Can't set a token if the project is already associated with another token.
        if (tokenOf[projectId] != IJBToken(address(0))) revert JBTokens_ProjectAlreadyHasToken(tokenOf[projectId]);

        // Can't set a token if it's already associated with another project.
        if (projectIdOf[token] != 0) revert JBTokens_TokenAlreadyBeingUsed(projectIdOf[token]);

        // Can't change to a token that doesn't use 18 decimals.
        if (token.decimals() != 18) revert JBTokens_TokensMustHave18Decimals(token.decimals());

        // Make sure the token can be added to the project its being added to.
        if (!token.canBeAddedTo(projectId)) revert JBTokens_TokenCantBeAdded(projectId);

        // Store the new token.
        tokenOf[projectId] = token;

        // Store the project for the token.
        projectIdOf[token] = projectId;

        emit SetToken({projectId: projectId, token: token, caller: msg.sender});
    }

    /// @notice Update the name and symbol of a project's ERC-20 token. The project must already have a token deployed
    /// or attached.
    /// @dev Only a project's controller can set the token's name and symbol.
    /// @param projectId The ID of the project to update the token for.
    /// @param name The new name.
    /// @param symbol The new symbol.
    function setTokenMetadataFor(
        uint256 projectId,
        string calldata name,
        string calldata symbol
    )
        external
        override
        onlyControllerOf(projectId)
    {
        // Get a reference to the project's current token.
        IJBToken token = tokenOf[projectId];

        // The project must have a token contract attached.
        if (token == IJBToken(address(0))) revert JBTokens_TokenNotFound({projectId: projectId});

        // There must be a name.
        if (bytes(name).length == 0) revert JBTokens_EmptyName({projectId: projectId});

        // There must be a symbol.
        if (bytes(symbol).length == 0) revert JBTokens_EmptySymbol({projectId: projectId});

        emit SetTokenMetadata({projectId: projectId, name: name, symbol: symbol, caller: msg.sender});

        // Set the name and symbol.
        token.setMetadata({name: name, symbol: symbol});
    }

    /// @notice Move internal credits from one account to another. Credits are non-transferable on their own (they're
    /// just a balance in this contract), so this function enables transfers via the controller.
    /// @dev Only a project's controller can transfer credits for that project.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project to transfer credits for.
    /// @param recipient The recipient of the credits.
    /// @param count The number of token credits to transfer.
    function transferCreditsFrom(
        address holder,
        uint256 projectId,
        address recipient,
        uint256 count
    )
        external
        override
        onlyControllerOf(projectId)
    {
        // Get a reference to the holder's unclaimed project token balance.
        uint256 creditBalance = creditBalanceOf[holder][projectId];

        // The holder must have enough unclaimed tokens to transfer.
        if (count > creditBalance) revert JBTokens_InsufficientCredits(count, creditBalance);

        // Subtract from the holder's unclaimed token balance.
        unchecked {
            creditBalanceOf[holder][projectId] = creditBalance - count;
        }

        // Add the unclaimed project tokens to the recipient's balance.
        creditBalanceOf[recipient][projectId] += count;

        emit TransferCredits({
            holder: holder, projectId: projectId, recipient: recipient, count: count, caller: msg.sender
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Get a holder's complete balance for a project — both their internal credits and their ERC-20 token
    /// balance combined.
    /// @param holder The holder to get a balance for.
    /// @param projectId The project to get the `holder`'s balance for.
    /// @return balance The combined token and token credit balance of the `holder`.
    function totalBalanceOf(address holder, uint256 projectId) external view override returns (uint256 balance) {
        // Get a reference to the holder's credits for the project.
        balance = creditBalanceOf[holder][projectId];

        // Get a reference to the project's current token.
        IJBToken token = tokenOf[projectId];

        // If the project has a current token, add the holder's balance to the total.
        if (token != IJBToken(address(0))) {
            balance += token.balanceOf(holder);
        }
    }

    //*********************************************************************//
    // --------------------------- public views -------------------------- //
    //*********************************************************************//

    /// @notice Get the total token supply for a project — internal credits plus the ERC-20's `totalSupply()`. This is
    /// the denominator used in cash-out bonding curve calculations.
    /// @dev WARNING: Projects using `setTokenFor` with an external ERC-20 inherit that token's supply manipulation
    /// surface. If the external token has a separate minting authority, `totalSupply()` can be inflated outside of
    /// this contract, diluting cash-out values for all holders. Projects using `deployERC20For` are safe because the
    /// resulting `JBERC20` is exclusively owned by this `JBTokens` contract.
    /// @param projectId The ID of the project to get the total supply of.
    /// @return totalSupply The total supply of the project's tokens and token credits.
    function totalSupplyOf(uint256 projectId) public view override returns (uint256 totalSupply) {
        // Get a reference to the total supply of the project's credits
        totalSupply = totalCreditSupplyOf[projectId];

        // Get a reference to the project's current token.
        IJBToken token = tokenOf[projectId];

        // If the project has a current token, add its total supply to the total.
        if (token != IJBToken(address(0))) {
            totalSupply += token.totalSupply();
        }
    }
}
