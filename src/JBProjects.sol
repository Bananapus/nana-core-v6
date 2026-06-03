// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ERC721, Context} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBTokenUriResolver} from "./interfaces/IJBTokenUriResolver.sol";

/// @notice Each Juicebox project is an ERC-721 NFT. Whoever holds the NFT owns the project and can configure its
/// rulesets, terminals, and permissions. Projects are created with `createFor` and the resulting token ID is used as
/// the project's ID across the entire protocol.
contract JBProjects is ERC721, ERC2771Context, Ownable, IJBProjects {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the configured creation fee exceeds the allowed maximum.
    error JBProjects_CreationFeeExceedsMax(uint256 fee, uint256 max);

    /// @notice Thrown when the native value sent does not equal the required creation fee.
    error JBProjects_InvalidCreationFee(uint256 value, uint256 requiredFee);

    /// @notice Thrown when a non-zero creation fee is configured without a fee receiver.
    error JBProjects_ZeroCreationFeeReceiver();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The maximum native-token fee the owner can require to create a project.
    /// @dev Hardcoded as a cap on the owner's `setCreationFee` authority so the fee can never become an effective
    /// barrier to project creation.
    uint256 public constant override MAX_CREATION_FEE = 0.001 ether;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The native-token fee required to create a project.
    uint256 public override creationFee;

    /// @notice The address that receives project creation fees.
    address payable public override creationFeeReceiver;

    /// @notice The number of projects that have been created using this contract.
    /// @dev The count is incremented with each new project created.
    /// @dev The resulting ERC-721 token ID for each project is the newly incremented count value.
    uint256 public override count;

    /// @notice The contract resolving each project ID to its ERC721 URI.
    IJBTokenUriResolver public override tokenUriResolver;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param owner The owner of the contract who can set metadata.
    /// @param feeProjectOwner The address that will receive the fee-project. If `address(0)` the fee-project will not
    /// be minted.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        address owner,
        address feeProjectOwner,
        address trustedForwarder
    )
        ERC721("Juicebox Projects", "JUICEBOX")
        Ownable(owner)
        ERC2771Context(trustedForwarder)
    {
        if (feeProjectOwner != address(0)) {
            createFor(feeProjectOwner);
        }
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Set the native-token fee required to create a project and the address that receives it.
    /// @dev Only this contract's owner can change the fee. A non-zero fee requires a non-zero receiver. The fee may
    /// not exceed `MAX_CREATION_FEE`.
    /// @param fee The required creation fee. Set to 0 to disable creation fees. Must be `<= MAX_CREATION_FEE`.
    /// @param receiver The address that receives project creation fees.
    function setCreationFee(uint256 fee, address payable receiver) external override onlyOwner {
        // Enforce the hardcoded ceiling so the owner can never price project creation out of reach.
        if (fee > MAX_CREATION_FEE) revert JBProjects_CreationFeeExceedsMax({fee: fee, max: MAX_CREATION_FEE});

        // Non-zero fees need somewhere to go.
        if (fee != 0 && receiver == address(0)) revert JBProjects_ZeroCreationFeeReceiver();

        // Store the fee configuration.
        creationFee = fee;
        creationFeeReceiver = receiver;

        emit SetCreationFee({fee: fee, receiver: receiver, caller: _msgSender()});
    }

    /// @notice Set the contract that resolves project NFT metadata (the `tokenURI`). This controls what artwork and
    /// JSON metadata is returned for each project's ERC-721 token.
    /// @dev Only this contract's owner can change the resolver.
    /// @param resolver The address of the new resolver.
    function setTokenUriResolver(IJBTokenUriResolver resolver) external override onlyOwner {
        // Store the new resolver.
        tokenUriResolver = resolver;

        emit SetTokenUriResolver({resolver: resolver, caller: _msgSender()});
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Create a new project for the specified owner, which mints an NFT (ERC-721) into their wallet.
    /// @dev Anyone can create a project on an owner's behalf.
    /// @dev Requires exactly `creationFee` native tokens. The fee is forwarded after the project NFT is minted.
    /// @param owner The address that will be the owner of the project.
    /// @return projectId The token ID of the newly created project.
    function createFor(address owner) public payable override returns (uint256 projectId) {
        // Keep a reference to the fee. It must be paid exactly to avoid accidental overpayment.
        uint256 fee = creationFee;
        if (msg.value != fee) revert JBProjects_InvalidCreationFee({value: msg.value, requiredFee: fee});

        // Increment the count, which will be used as the ID.
        projectId = ++count;

        emit Create({projectId: projectId, owner: owner, caller: _msgSender()});

        // Mint the project.
        _safeMint({to: owner, tokenId: projectId});

        // Forward the fee if one is configured.
        if (fee != 0) {
            address payable receiver = creationFeeReceiver;
            if (receiver == address(0)) revert JBProjects_ZeroCreationFeeReceiver();
            Address.sendValue({recipient: receiver, amount: fee});
        }
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC721) returns (bool) {
        return interfaceId == type(IJBProjects).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the URI where the ERC-721 standard JSON of a project is hosted.
    /// @param projectId The ID of the project to get a URI of.
    /// @return The token URI to use for the provided `projectId`.
    function tokenURI(uint256 projectId) public view override returns (string memory) {
        // Keep a reference to the resolver.
        IJBTokenUriResolver resolver = tokenUriResolver;

        // If there's no resolver, there's no URI.
        if (resolver == IJBTokenUriResolver(address(0))) return "";

        // Return the resolved URI.
        return resolver.getUri(projectId);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
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
}
