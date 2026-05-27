// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {JBFeelessSetup} from "./JBFeelessSetup.sol";

contract TestSupportsInterface_Local is JBFeelessSetup {
    function setUp() public {
        super.feelessAddressesSetup();
    }

    function test_WhenItSupportsEitherIJBFeelessAddressesOrIERC165() external view {
        // it should return true
        assertTrue(IERC165(address(_feelessAddresses)).supportsInterface(type(IJBFeelessAddresses).interfaceId));
        assertTrue(IERC165(address(_feelessAddresses)).supportsInterface(type(IERC165).interfaceId));
    }

    function test_WhenAskedIfSupportsNonIJBFeelessAddressesOrIERC165() external view {
        // it should return false
        assertFalse(IERC165(address(_feelessAddresses)).supportsInterface(0x12345678));
        assertFalse(IERC165(address(_feelessAddresses)).supportsInterface(0x12345679));
    }
}
