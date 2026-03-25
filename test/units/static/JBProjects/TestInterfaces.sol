// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBProjectsSetup} from "./JBProjectsSetup.sol";

contract TestSupportsInterface_Local is JBProjectsSetup {
    function setUp() public {
        super.projectsSetup();
    }

    function test_WhenInterfaceIdIsIJBProjects() external {
        // it will return true
    }

    function test_WhenInterfaceIdIsIERC721() external {
        // it will return true
    }

    function test_WhenInterfaceIdIsIERC721Metadata() external {
        // it will return true
    }

    function test_WhenInterfaceIdIsAnythingElse() external {
        // it will return false
    }
}
