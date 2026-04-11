// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit, Nonces} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBToken} from "./interfaces/IJBToken.sol";
import {IJBTokens} from "./interfaces/IJBTokens.sol";

/// @notice An ERC-20 token that can be used by a project in `JBTokens` and `JBController`.
/// @dev By default, a project uses "credits" to track balances. Once a project sets their `IJBToken` using
/// `JBController.deployERC20For(...)` or `JBController.setTokenFor(...)`, credits can be redeemed to claim tokens.
/// @dev `JBController.deployERC20For(...)` deploys a `JBERC20` contract and sets it as the project's token.
contract JBERC20 is ERC20Votes, ERC20Permit, IERC1271, IJBToken {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBERC20_AlreadyInitialized();
    error JBERC20_Unauthorized();

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The token's name.
    // slither-disable-next-line shadowing-state
    string private _name;

    /// @notice The token's symbol.
    // slither-disable-next-line shadowing-state
    string private _symbol;

    //*********************************************************************//
    // ---------------------- public stored properties ------------------- //
    //*********************************************************************//

    /// @notice The JBTokens contract that owns this token.
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBTokens public TOKENS;

    /// @notice The projects contract used to resolve project ownership.
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBProjects public PROJECTS;

    /// @notice The permissions contract used to check operator permissions.
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBPermissions public PERMISSIONS;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev Set `_name` on the implementation contract to prevent it from being initialized directly.
    /// Clones start with empty `_name`, so `initialize(...)` works only on clones.
    constructor() ERC20("invalid", "invalid") ERC20Permit("JBToken") {
        _name = "invalid";
    }

    //*********************************************************************//
    // --------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    /// @notice Only the JBTokens contract can call this function.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyTokens() {
        if (msg.sender != address(TOKENS)) revert JBERC20_Unauthorized();
        _;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Burn some outstanding tokens.
    /// @dev Can only be called by the JBTokens contract.
    /// @param account The address to burn tokens from.
    /// @param amount The amount of tokens to burn, as a fixed point number with 18 decimals.
    function burn(address account, uint256 amount) external override onlyTokens {
        return _burn({account: account, value: amount});
    }

    /// @notice Mints more of this token.
    /// @dev Can only be called by the JBTokens contract.
    /// @param account The address to mint the new tokens to.
    /// @param amount The amount of tokens to mint, as a fixed point number with 18 decimals.
    function mint(address account, uint256 amount) external override onlyTokens {
        return _mint({account: account, value: amount});
    }

    /// @notice Sets the token's name and symbol.
    /// @dev Can only be called by the JBTokens contract.
    /// @param name_ The new name.
    /// @param symbol_ The new symbol.
    function setMetadata(string memory name_, string memory symbol_) external override onlyTokens {
        _name = name_;
        _symbol = symbol_;
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initializes the token.
    /// @param name_ The token's name.
    /// @param symbol_ The token's symbol.
    /// @param tokens The JBTokens contract that manages this token.
    /// @param projects The projects contract for resolving project ownership.
    /// @param permissions The permissions contract for checking operator permissions.
    function initialize(
        string memory name_,
        string memory symbol_,
        address tokens,
        address projects,
        address permissions
    )
        public
        override
    {
        // Prevent re-initialization by reverting if a name is already set or if the provided name is empty.
        if (bytes(_name).length != 0 || bytes(name_).length == 0) revert JBERC20_AlreadyInitialized();

        _name = name_;
        _symbol = symbol_;
        TOKENS = IJBTokens(tokens);
        PROJECTS = IJBProjects(projects);
        PERMISSIONS = IJBPermissions(permissions);
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice This token can only be added to a project when its created by the `JBTokens` contract.
    function canBeAddedTo(uint256) external pure override returns (bool) {
        return false;
    }

    /// @notice Validates a signature on behalf of this token contract (ERC-1271).
    /// @dev Allows the project owner or an operator with `SIGN_FOR_ERC20` permission to sign messages on behalf of
    /// this token. Useful for Etherscan contract verification and other off-chain signature flows.
    /// @param hash The hash of the data being signed.
    /// @param signature The signature to validate.
    /// @return magicValue `0x1626ba7e` if the signature is valid, `0xffffffff` otherwise.
    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4 magicValue) {
        // Recover the signer from the signature. Return invalid if recovery fails.
        (address signer, ECDSA.RecoverError error,) = ECDSA.tryRecover(hash, signature);
        if (error != ECDSA.RecoverError.NoError) return 0xffffffff;

        // Get the project ID this token belongs to.
        uint256 projectId = TOKENS.projectIdOf(IJBToken(address(this)));

        // Get the project owner (the NFT holder).
        address projectOwner = PROJECTS.ownerOf(projectId);

        // The project owner can always sign.
        if (signer == projectOwner) return IERC1271.isValidSignature.selector;

        // Check if the signer has the SIGN_FOR_ERC20 permission from the project owner.
        if (
            PERMISSIONS.hasPermission({
                operator: signer,
                account: projectOwner,
                projectId: projectId,
                permissionId: JBPermissionIds.SIGN_FOR_ERC20,
                includeRoot: true,
                includeWildcardProjectId: true
            })
        ) return IERC1271.isValidSignature.selector;

        return 0xffffffff;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The balance of the given address.
    /// @param account The account to get the balance of.
    /// @return The number of tokens owned by the `account`, as a fixed point number with 18 decimals.
    function balanceOf(address account) public view override(ERC20, IJBToken) returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice The number of decimals used for this token's fixed point accounting.
    /// @return The number of decimals.
    function decimals() public view override(ERC20, IJBToken) returns (uint8) {
        return super.decimals();
    }

    /// @notice The token's name.
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /// @notice Required override.
    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice The token's symbol.
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /// @notice The total supply of this ERC20 i.e. the total number of tokens in existence.
    /// @return The total supply of this ERC20, as a fixed point number.
    function totalSupply() public view override(ERC20, IJBToken) returns (uint256) {
        return super.totalSupply();
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Required override.
    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Votes) {
        super._update({from: from, to: to, value: value});
    }
}
