// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBDirectorySetup} from "./JBDirectorySetup.sol";

/// @notice A mock controller that asserts the directory still points to it during migrate().
/// This validates that controllerOf is NOT updated before migrate() is called.
contract MockMigratingController is ERC165 {
    IJBDirectory public immutable DIRECTORY;
    uint256 public immutable PROJECT_ID;
    bool public migrateCalled;
    bool public directoryPointedToSelfDuringMigrate;

    constructor(IJBDirectory directory, uint256 projectId) {
        DIRECTORY = directory;
        PROJECT_ID = projectId;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IJBMigratable).interfaceId
            || interfaceId == type(IJBDirectoryAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    function setControllerAllowed(uint256) external pure returns (bool) {
        return true;
    }

    function migrate(uint256, IERC165) external {
        migrateCalled = true;
        // The critical assertion: during migrate(), the directory should still point to this controller.
        directoryPointedToSelfDuringMigrate = (address(DIRECTORY.controllerOf(PROJECT_ID)) == address(this));
    }

    function beforeReceiveMigrationFrom(IERC165, uint256) external {}

    function afterReceiveMigrationFrom(IERC165, uint256) external {}
}

/// @notice A simple new controller that accepts migration.
contract MockNewController is ERC165 {
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IJBMigratable).interfaceId || super.supportsInterface(interfaceId);
    }

    function migrate(uint256, IERC165) external {}

    function beforeReceiveMigrationFrom(IERC165, uint256) external {}

    function afterReceiveMigrationFrom(IERC165, uint256) external {}
}

contract TestSetControllerOfMigrationOrder is JBDirectorySetup {
    using stdStorage for StdStorage;

    uint256 constant PROJECT_ID = 1;

    function setUp() public {
        super.directorySetup();
    }

    /// @notice Verifies that during migrate(), the directory still points to the old controller.
    /// This test PASSES with the correct ordering (migrate before set) and FAILS if set happens before migrate.
    function test_DirectoryPointsToOldControllerDuringMigrate() external {
        // Deploy mock controllers with real code (not mocked addresses).
        MockMigratingController oldController = new MockMigratingController(_directory, PROJECT_ID);
        MockNewController newController = new MockNewController();

        // Set the old controller in the directory's storage.
        stdstore.target(address(_directory)).sig("controllerOf(uint256)").with_key(PROJECT_ID).depth(0).checked_write(
            address(oldController)
        );

        // Mock ownerOf to return this test contract as the project owner.
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(address(this)));

        // Mock project count to allow the project to exist.
        mockExpect(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(type(uint256).max));

        // Perform the migration.
        _directory.setControllerOf(PROJECT_ID, IERC165(address(newController)));

        // Verify migrate() was called.
        assertTrue(oldController.migrateCalled(), "migrate() should have been called on old controller");

        // Verify the directory pointed to the old controller during migrate().
        assertTrue(
            oldController.directoryPointedToSelfDuringMigrate(),
            "Directory should point to old controller during migrate()"
        );

        // Verify the directory now points to the new controller after everything completes.
        assertEq(
            address(_directory.controllerOf(PROJECT_ID)),
            address(newController),
            "Directory should point to new controller after migration"
        );
    }
}
