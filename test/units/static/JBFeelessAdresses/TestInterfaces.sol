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
        bool result1 = IERC165(address(_feelessAddresses)).supportsInterface(type(IJBFeelessAddresses).interfaceId);
        assertTrue(result1);

        bool result2 = IERC165(address(_feelessAddresses)).supportsInterface(type(IERC165).interfaceId);
        assertTrue(result2);
    }

    function test_WhenAskedIfSupportsNonIJBFeelessAddressesOrIERC165() external view {
        // it should return false
        bool result1 = IERC165(address(_feelessAddresses)).supportsInterface(0x12345678);
        assertFalse(result1);

        bool result2 = IERC165(address(_feelessAddresses)).supportsInterface(0x12345679);
        assertFalse(result2);
    }
}
