// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBMetadataResolver} from "../../../../src/libraries/JBMetadataResolver.sol";

/// @notice Harness that exposes JBMetadataResolver internals and adds a combined operation
/// to test memory corruption from _sliceBytes within a single execution context.
contract M20M21Harness {
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

    /// @notice Adds an entry then immediately verifies all entries in one execution context.
    /// This catches memory corruption from _sliceBytes that wouldn't be visible across external calls.
    function addAndVerifyAll(
        bytes memory metadata,
        bytes4 newId,
        bytes memory newData,
        bytes4[] memory allIds,
        bytes32[] memory expectedValues
    )
        external
        pure
        returns (bool allCorrect)
    {
        // Add the new entry — this internally calls _sliceBytes with start > 0
        bytes memory updated = JBMetadataResolver.addToMetadata(metadata, newId, newData);

        // Verify all entries within the same execution context (same memory space)
        allCorrect = true;
        for (uint256 i; i < allIds.length; i++) {
            (bool found, bytes memory data) = JBMetadataResolver.getDataFor(allIds[i], updated);
            if (!found) {
                allCorrect = false;
                break;
            }
            if (
                keccak256(abi.encodePacked(bytes32(abi.decode(data, (uint256)))))
                    != keccak256(abi.encodePacked(expectedValues[i]))
            ) {
                allCorrect = false;
                break;
            }
        }
    }
}

/// @notice Tests for M-20 (_sliceBytes over-copy) and M-21 (addToMetadata offset overflow).
contract TestMetadataResolverM20M21 is JBTest {
    M20M21Harness harness;

    function setUp() external {
        harness = new M20M21Harness();
    }

    //*********************************************************************//
    // --- M-20: _sliceBytes memory over-copy --------------------------- //
    //*********************************************************************//

    /// @notice Verifies that addToMetadata preserves all entries when adding to metadata with
    /// multiple existing entries. The _sliceBytes call at line 129 uses start > 0, which on
    /// the buggy code would over-copy and corrupt subsequent memory operations.
    function test_M20_addToMetadataPreservesAllEntries() external view {
        bytes4 id1 = bytes4(0x11111111);
        bytes4 id2 = bytes4(0x22222222);
        bytes4 id3 = bytes4(0x33333333);

        uint256 val1 = 111;
        uint256 val2 = 222;
        uint256 val3 = 333;

        // Create metadata with 2 entries
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = id1;
        ids[1] = id2;

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodePacked(bytes32(val1));
        datas[1] = abi.encodePacked(bytes32(val2));

        bytes memory metadata = harness.createMetadata(ids, datas);

        // Add a 3rd entry — this exercises _sliceBytes with start > 0
        bytes4[] memory allIds = new bytes4[](3);
        allIds[0] = id1;
        allIds[1] = id2;
        allIds[2] = id3;

        bytes32[] memory expectedValues = new bytes32[](3);
        expectedValues[0] = bytes32(val1);
        expectedValues[1] = bytes32(val2);
        expectedValues[2] = bytes32(val3);

        bool allCorrect =
            harness.addAndVerifyAll(metadata, id3, abi.encodePacked(bytes32(val3)), allIds, expectedValues);

        assertTrue(allCorrect, "All entries should be retrievable after addToMetadata");
    }

    /// @notice Test with 4 sequential addToMetadata calls, each exercising _sliceBytes.
    /// More entries = more start > 0 cases = more chances for memory corruption.
    function test_M20_multipleSequentialAdds() external view {
        bytes4[5] memory ids =
            [bytes4(0x11111111), bytes4(0x22222222), bytes4(0x33333333), bytes4(0x44444444), bytes4(0x55555555)];
        uint256[5] memory vals = [uint256(100), uint256(200), uint256(300), uint256(400), uint256(500)];

        // Start with 1 entry via createMetadata
        bytes4[] memory initIds = new bytes4[](1);
        initIds[0] = ids[0];
        bytes[] memory initDatas = new bytes[](1);
        initDatas[0] = abi.encodePacked(bytes32(vals[0]));
        bytes memory metadata = harness.createMetadata(initIds, initDatas);

        // Add 4 more entries sequentially
        for (uint256 i = 1; i < 5; i++) {
            metadata = harness.addToMetadata(metadata, ids[i], abi.encodePacked(bytes32(vals[i])));
        }

        // Verify ALL entries are still correct
        for (uint256 i; i < 5; i++) {
            (bool found, bytes memory data) = harness.getDataFor(ids[i], metadata);
            assertTrue(found, string.concat("Entry ", vm.toString(i), " should be found"));
            assertEq(abi.decode(data, (uint256)), vals[i], string.concat("Entry ", vm.toString(i), " data mismatch"));
        }
    }

    /// @notice Verify that getDataFor returns the exact expected length for non-first entries.
    /// On buggy code, _sliceBytes copies more than needed, but the returned length should still
    /// be correct. This test verifies both length and content.
    function test_M20_getDataForReturnsCorrectLength() external view {
        bytes4 id1 = bytes4(0xAAAAAAAA);
        bytes4 id2 = bytes4(0xBBBBBBBB);

        // Entry 1: 2 words (64 bytes). Entry 2: 1 word (32 bytes).
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = id1;
        ids[1] = id2;

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodePacked(bytes32(uint256(0xAA)), bytes32(uint256(0xBB))); // 64 bytes
        datas[1] = abi.encodePacked(bytes32(uint256(0xCC))); // 32 bytes

        bytes memory metadata = harness.createMetadata(ids, datas);

        // Get entry 1 (first entry, start = firstOffset * 32)
        (bool found1, bytes memory data1) = harness.getDataFor(id1, metadata);
        assertTrue(found1, "Entry 1 should be found");
        assertEq(data1.length, 64, "Entry 1 should be 64 bytes");

        // Get entry 2 (second entry, start > firstOffset * 32)
        (bool found2, bytes memory data2) = harness.getDataFor(id2, metadata);
        assertTrue(found2, "Entry 2 should be found");
        assertEq(data2.length, 32, "Entry 2 should be exactly 32 bytes");
        assertEq(abi.decode(data2, (uint256)), 0xCC, "Entry 2 data should be 0xCC");
    }

    //*********************************************************************//
    // --- M-21: addToMetadata offset overflow -------------------------- //
    //*********************************************************************//

    /// @notice Verifies that addToMetadata reverts when the new offset would exceed 255.
    /// Uses 6 entries (table = 1 word, 30 bytes) with data totaling 253 words → total 255 words.
    /// Adding a 7th entry via addToMetadata forces the table from 1→2 words, incrementing all
    /// offsets by 1. This pushes newOffset from 255 to 256, triggering the overflow check.
    function test_M21_addToMetadataRevertsOnOffsetOverflow() external {
        // 6 entries: table = ceil(6*5/32) = 1 word. firstOffset = 2.
        // 5 entries × 42 words + 1 entry × 43 words = 253 words of data.
        // Total = 1 (reserved) + 1 (table) + 253 (data) = 255 words.
        // createMetadata final offset check: 255 > 255 → false → succeeds.
        bytes4[] memory ids = new bytes4[](6);
        ids[0] = bytes4(0x11111111);
        ids[1] = bytes4(0x22222222);
        ids[2] = bytes4(0x33333333);
        ids[3] = bytes4(0x44444444);
        ids[4] = bytes4(0x55555555);
        ids[5] = bytes4(0x66666666);

        bytes[] memory datas = new bytes[](6);
        // 5 entries of 42 words (1344 bytes) + 1 entry of 43 words (1376 bytes)
        for (uint256 i; i < 5; i++) {
            datas[i] = new bytes(1344);
            datas[i][0] = bytes1(uint8(i + 1));
        }
        datas[5] = new bytes(1376);
        datas[5][0] = 0x06;

        bytes memory metadata = harness.createMetadata(ids, datas);

        // Adding a 7th entry: table grows from 30 bytes (1 word) to 35 bytes (2 words).
        // All offsets += 1. lastOffset (212) becomes 213.
        // newOffset = 213 + 43 = 256 > 255 → revert.
        vm.expectRevert(JBMetadataResolver.JBMetadataResolver_MetadataTooLong.selector);
        harness.addToMetadata(metadata, bytes4(0x77777777), abi.encodePacked(bytes32(uint256(7))));
    }

    /// @notice Verifies that addToMetadata works when the offset is exactly at the boundary (255).
    /// Same 6-entry table expansion setup but with 1 less data word (total 254 words),
    /// so the expanded offset is exactly 255 — the maximum valid value.
    function test_M21_addToMetadataSucceedsAtBoundary() external view {
        // 6 entries × 42 words each = 252 words of data.
        // Total = 1 (reserved) + 1 (table) + 252 (data) = 254 words.
        bytes4[] memory ids = new bytes4[](6);
        ids[0] = bytes4(0x11111111);
        ids[1] = bytes4(0x22222222);
        ids[2] = bytes4(0x33333333);
        ids[3] = bytes4(0x44444444);
        ids[4] = bytes4(0x55555555);
        ids[5] = bytes4(0x66666666);

        bytes[] memory datas = new bytes[](6);
        for (uint256 i; i < 6; i++) {
            datas[i] = new bytes(1344); // 42 words each
            datas[i][0] = bytes1(uint8(i + 1));
        }

        bytes memory metadata = harness.createMetadata(ids, datas);

        // Adding 7th entry: table expands, all offsets += 1.
        // lastOffset (212) becomes 213. newOffset = 213 + 42 = 255 ≤ 255 → succeeds.
        bytes memory updated =
            harness.addToMetadata(metadata, bytes4(0x77777777), abi.encodePacked(bytes32(uint256(7))));

        // Verify the new entry is retrievable.
        (bool found, bytes memory data) = harness.getDataFor(bytes4(0x77777777), updated);
        assertTrue(found, "New entry should be found at boundary offset 255");
        assertEq(abi.decode(data, (uint256)), 7, "Boundary entry data should match");
    }
}
