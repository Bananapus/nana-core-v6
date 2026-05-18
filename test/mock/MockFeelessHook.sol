// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBFeelessHook} from "../../src/interfaces/IJBFeelessHook.sol";

import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @notice Configurable `IJBFeelessHook` mock for unit tests.
/// @dev `mode` controls behavior of `isFeeless`:
///   - 0: returns `defaultResult` for any (projectId, addr)
///   - 1: reverts with `Nope()`
///   - 2: reverts via `require(false, "nope")`
///   - 3: returns `true` iff `(projectId, addr)` has been allowlisted via `setAllowed`
contract MockFeelessHook is ERC165, IJBFeelessHook {
    error Nope();

    uint256 public mode;
    bool public defaultResult;
    mapping(uint256 => mapping(address => bool)) internal _allowed;

    function setMode(uint256 newMode) external {
        mode = newMode;
    }

    function setDefaultResult(bool result) external {
        defaultResult = result;
    }

    function setAllowed(uint256 projectId, address addr, bool flag) external {
        _allowed[projectId][addr] = flag;
    }

    function isFeeless(uint256 projectId, address addr) external view override returns (bool) {
        if (mode == 1) revert Nope();
        if (mode == 2) require(false, "nope");
        if (mode == 3) return _allowed[projectId][addr];
        return defaultResult;
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IJBFeelessHook).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @notice Non-conforming "hook" that returns false for the IJBFeelessHook interfaceId in ERC-165.
/// @dev Used to test the `setFeelessHook` validation guard. Has the `isFeeless` selector so the
/// call shape matches, but its `supportsInterface` advertises only IERC165, not IJBFeelessHook.
contract MockNonConformingFeelessHook is ERC165 {
    function isFeeless(uint256, address) external pure returns (bool) {
        return true;
    }
}

/// @notice "Hook" with no `supportsInterface` at all — `setFeelessHook` should revert when this is passed.
contract MockEoaLikeFeelessHook {
    function isFeeless(uint256, address) external pure returns (bool) {
        return true;
    }
}
