// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBMetadataResolver} from "../../../../src/libraries/JBMetadataResolver.sol";

/// @notice Wrapper contract to expose JBMetadataResolver internal functions for testing.
contract MetadataResolverHarness {
    function createMetadata(bytes4[] memory ids, bytes[] memory datas) external pure returns (bytes memory) {
        return JBMetadataResolver.createMetadata(ids, datas);
    }

    function getDataFor(bytes4 id, bytes memory metadata) external pure returns (bool found, bytes memory targetData) {
        return JBMetadataResolver.getDataFor(id, metadata);
    }

    function addToMetadata(
        bytes memory originalMetadata,
        bytes4 idToAdd,
        bytes memory dataToAdd
    )
        external
        pure
        returns (bytes memory)
    {
        return JBMetadataResolver.addToMetadata(originalMetadata, idToAdd, dataToAdd);
    }

    function getId(string memory purpose, address target) external pure returns (bytes4) {
        return JBMetadataResolver.getId(purpose, target);
    }
}

/// @notice Fuzz tests for JBMetadataResolver library.
contract TestMetadataResolverFuzz_Local is JBTest {
    MetadataResolverHarness harness;

    function setUp() external {
        harness = new MetadataResolverHarness();
    }

    //*********************************************************************//
    // --- Single Entry Round-Trip -------------------------------------- //
    //*********************************************************************//

    /// @notice createMetadata with 1 entry, then getDataFor retrieves it.
    function testFuzz_singleEntry_roundTrip(bytes4 id, uint256 value) external view {
        vm.assume(id != bytes4(0)); // 0 ID would be confused with padding

        bytes4[] memory ids = new bytes4[](1);
        ids[0] = id;

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodePacked(bytes32(value)); // Padded to 32 bytes

        bytes memory metadata = harness.createMetadata(ids, datas);

        (bool found, bytes memory result) = harness.getDataFor(id, metadata);
        assertTrue(found, "ID should be found");
        assertEq(abi.decode(result, (uint256)), value, "data should match");
    }

    /// @notice Missing ID returns (false, "").
    function testFuzz_missingId_returnsEmpty(bytes4 id, bytes4 searchId, uint256 value) external view {
        vm.assume(id != bytes4(0));
        vm.assume(searchId != bytes4(0));
        vm.assume(id != searchId);

        bytes4[] memory ids = new bytes4[](1);
        ids[0] = id;

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodePacked(bytes32(value));

        bytes memory metadata = harness.createMetadata(ids, datas);

        (bool found, bytes memory result) = harness.getDataFor(searchId, metadata);
        assertFalse(found, "non-existent ID should not be found");
        assertEq(result.length, 0, "data should be empty");
    }

    //*********************************************************************//
    // --- Two Entry Round-Trip ----------------------------------------- //
    //*********************************************************************//

    /// @notice createMetadata with 2 entries, both are retrievable.
    function testFuzz_twoEntries_roundTrip(bytes4 id1, bytes4 id2, uint256 value1, uint256 value2) external view {
        vm.assume(id1 != bytes4(0) && id2 != bytes4(0));
        vm.assume(id1 != id2);

        bytes4[] memory ids = new bytes4[](2);
        ids[0] = id1;
        ids[1] = id2;

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodePacked(bytes32(value1));
        datas[1] = abi.encodePacked(bytes32(value2));

        bytes memory metadata = harness.createMetadata(ids, datas);

        // Check first entry
        (bool found1, bytes memory result1) = harness.getDataFor(id1, metadata);
        assertTrue(found1, "first ID should be found");
        assertEq(abi.decode(result1, (uint256)), value1, "first data should match");

        // Check second entry
        (bool found2, bytes memory result2) = harness.getDataFor(id2, metadata);
        assertTrue(found2, "second ID should be found");
        assertEq(abi.decode(result2, (uint256)), value2, "second data should match");
    }

    //*********************************************************************//
    // --- addToMetadata Round-Trip ------------------------------------- //
    //*********************************************************************//

    /// @notice addToMetadata on empty metadata creates valid entry.
    function testFuzz_addToEmpty_roundTrip(bytes4 id, uint256 value) external view {
        vm.assume(id != bytes4(0));

        bytes memory empty = new bytes(0);
        bytes memory dataToAdd = abi.encodePacked(bytes32(value));

        bytes memory metadata = harness.addToMetadata(empty, id, dataToAdd);

        (bool found, bytes memory result) = harness.getDataFor(id, metadata);
        assertTrue(found, "added ID should be found");
        assertEq(abi.decode(result, (uint256)), value, "added data should match");
    }

    /// @notice addToMetadata preserves existing entries.
    function testFuzz_addPreservesExisting(bytes4 id1, bytes4 id2, uint256 value1, uint256 value2) external view {
        vm.assume(id1 != bytes4(0) && id2 != bytes4(0));
        vm.assume(id1 != id2);

        // Create metadata with first entry
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = id1;

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodePacked(bytes32(value1));

        bytes memory metadata = harness.createMetadata(ids, datas);

        // Add second entry
        metadata = harness.addToMetadata(metadata, id2, abi.encodePacked(bytes32(value2)));

        // Both should be retrievable
        (bool found1, bytes memory result1) = harness.getDataFor(id1, metadata);
        assertTrue(found1, "original ID should still be found");
        assertEq(abi.decode(result1, (uint256)), value1, "original data should be preserved");

        (bool found2, bytes memory result2) = harness.getDataFor(id2, metadata);
        assertTrue(found2, "added ID should be found");
        assertEq(abi.decode(result2, (uint256)), value2, "added data should match");
    }

    //*********************************************************************//
    // --- Edge Cases --------------------------------------------------- //
    //*********************************************************************//

    /// @notice Empty/short metadata returns (false, "").
    function testFuzz_shortMetadata_returnsEmpty(bytes4 id, uint8 length) external view {
        vm.assume(id != bytes4(0));
        length = uint8(bound(uint256(length), 0, 37)); // <= MIN_METADATA_LENGTH

        bytes memory shortData = new bytes(length);

        (bool found, bytes memory result) = harness.getDataFor(id, shortData);
        assertFalse(found, "short metadata should return false");
        assertEq(result.length, 0, "short metadata should return empty bytes");
    }

    /// @notice getId produces deterministic results.
    function testFuzz_getId_deterministic(string memory purpose, address target) external view {
        bytes4 id1 = harness.getId(purpose, target);
        bytes4 id2 = harness.getId(purpose, target);
        assertEq(id1, id2, "same inputs should produce same ID");
    }

    /// @notice getId with very different targets produces different IDs.
    /// @dev Only tests addresses that differ in the first 4 bytes to avoid XOR collision.
    function testFuzz_getId_differentTargets(uint256 seed1, uint256 seed2) external view {
        vm.assume(seed1 != seed2);
        address target1 = address(uint160(seed1));
        address target2 = address(uint160(seed2));
        vm.assume(target1 != target2);

        bytes4 id1 = harness.getId("test", target1);
        bytes4 id2 = harness.getId("test", target2);

        // Due to 4-byte truncation, collisions are possible but statistically rare
        // for truly random addresses. We just verify they're computed without reverting.
        // If they happen to collide, that's fine - it's a 1/2^32 chance per pair.
        if (bytes4(bytes20(target1)) != bytes4(bytes20(target2))) {
            assertTrue(id1 != id2, "IDs with different high-4-byte addresses should differ");
        }
    }

    //*********************************************************************//
    // --- Length Mismatch ---------------------------------------------- //
    //*********************************************************************//

    /// @notice createMetadata with mismatched lengths reverts.
    function test_lengthMismatch_reverts() external {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = bytes4(0x11111111);
        ids[1] = bytes4(0x22222222);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodePacked(bytes32(uint256(100)));

        vm.expectRevert(JBMetadataResolver.JBMetadataResolver_LengthMismatch.selector);
        harness.createMetadata(ids, datas);
    }

    /// @notice createMetadata with unpadded data reverts.
    function test_unpaddedData_reverts() external {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = bytes4(0x11111111);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodePacked(uint8(42)); // Only 1 byte, not padded

        vm.expectRevert(JBMetadataResolver.JBMetadataResolver_DataNotPadded.selector);
        harness.createMetadata(ids, datas);
    }
}
