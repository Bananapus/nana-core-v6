// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit, Nonces} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBToken} from "./interfaces/IJBToken.sol";
import {IJBTokens} from "./interfaces/IJBTokens.sol";

/// @notice The ERC-20 token implementation used by Juicebox projects. Includes ERC20Votes (governance delegation) and
/// ERC20Permit (gasless approvals). Deployed as a minimal clone via `JBController.deployERC20For` — once deployed,
/// holders can claim their internal credits into this transferable token.
/// @dev Only `JBTokens` can mint and burn. The project owner (via `SET_TOKEN_METADATA` permission) can rename the
/// token. Supports ERC-1271 signature validation for smart-contract wallets.
contract JBERC20 is ERC20Votes, ERC20Permit, JBPermissioned, IERC1271, IJBToken {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBERC20_AlreadyInitialized(uint256 currentNameLength, uint256 newNameLength);
    error JBERC20_Unauthorized(address caller, address tokens);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The projects contract used to resolve project ownership.
    IJBProjects public immutable PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The JBTokens contract that owns this token.
    /// @dev Set via `initialize` because JBERC20 is deployed before JBTokens (circular dependency).
    IJBTokens public TOKENS;

    //*********************************************************************//
    // -------------------- private stored properties -------------------- //
    //*********************************************************************//

    /// @notice The token's name.
    string private _name;

    /// @notice The token's symbol.
    string private _symbol;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev Set `_name` on the implementation contract to prevent it from being initialized directly.
    /// Clones start with empty `_name`, so `initialize(...)` works only on clones.
    /// @param permissions The permissions contract.
    /// @param projects The projects contract.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects
    )
        ERC20("invalid", "invalid")
        ERC20Permit("JBToken")
        JBPermissioned(permissions)
    {
        _name = "invalid";
        PROJECTS = projects;
    }

    //*********************************************************************//
    // --------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    /// @notice Only the JBTokens contract can call this function.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyTokens() {
        if (msg.sender != address(TOKENS)) revert JBERC20_Unauthorized({caller: msg.sender, tokens: address(TOKENS)});
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
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice This token can only be added to a project when its created by the `JBTokens` contract.
    function canBeAddedTo(uint256) external pure override returns (bool) {
        return false;
    }

    /// @notice Validates a signature on behalf of this token contract (ERC-1271).
    /// @dev Allows the project owner or an operator with `SIGN_FOR_ERC20` permission to sign messages on behalf of
    /// this token. Useful for Etherscan contract verification and other off-chain signature flows.
    /// @param hash The hash of the data to sign.
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

        // Valid if the signer is the project owner or has the SIGN_FOR_ERC20 permission.
        if (_hasPermissionFrom({
                operator: signer,
                account: projectOwner,
                projectId: projectId,
                permissionId: JBPermissionIds.SIGN_FOR_ERC20
            })) return IERC1271.isValidSignature.selector;

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

    /// @notice The token's name, set during initialization.
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /// @notice The current nonce for a given account, used for permit signatures.
    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice The token's ticker symbol, set during initialization.
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /// @notice The total supply of this ERC20 i.e. the total number of tokens in existence.
    /// @return The total supply of this ERC20, as a fixed point number.
    function totalSupply() public view override(ERC20, IJBToken) returns (uint256) {
        return super.totalSupply();
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initialize a new project token with the given name, symbol, and owner.
    /// @param name_ The token's name.
    /// @param symbol_ The token's symbol.
    /// @param tokens The JBTokens contract that manages this token.
    function initialize(string memory name_, string memory symbol_, address tokens) public override {
        // Prevent re-initialization by reverting if a name is already set or if the provided name is empty.
        if (bytes(_name).length != 0 || bytes(name_).length == 0) {
            revert JBERC20_AlreadyInitialized({
                currentNameLength: bytes(_name).length, newNameLength: bytes(name_).length
            });
        }

        _name = name_;
        _symbol = symbol_;
        TOKENS = IJBTokens(tokens);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Required override.
    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Votes) {
        super._update({from: from, to: to, value: value});
    }
}
