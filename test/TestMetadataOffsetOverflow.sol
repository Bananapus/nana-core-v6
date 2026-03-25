// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MetadataResolverHelper} from "./helpers/MetadataResolverHelper.sol";
import {JBMetadataResolver} from "../src/libraries/JBMetadataResolver.sol";

/// @notice Regression test for uint8 overflow in addToMetadata offset increment.
///
/// @dev    When `addToMetadata` grows the lookup table by one word, it increments every existing
///         offset byte by 1. If any offset byte is already 255, the old code silently wrapped to 0,
///         corrupting the lookup table. After the fix it must revert with
///         `JBMetadataResolver_MetadataTooLong`.
contract TestMetadataOffsetOverflow is Test {
    MetadataResolverHelper parser;

    function setUp() external {
        parser = new MetadataResolverHelper();
    }

    /// @notice Build metadata whose existing offset byte is 255, then call `addToMetadata` so that
    ///         the table must grow by one word. The offset increment (255 + 1) must revert.
    function test_addToMetadata_offsetOverflow_reverts() external {
        // We construct metadata by hand so that an existing offset byte equals 255.
        //
        // Layout:
        //   [0..31]   32 bytes reserved (all zeros)
        //   [32..36]  id1 (4 bytes) + offset1 (1 byte = 255)
        //   [37..63]  padding (zeros) to fill the first lookup-table word
        //
        // For offset1 = 255, the "data" region notionally starts at byte 255*32 = 8160.
        // We need originalMetadata.length >= 255*32 + 32 = 8192 so the library can compute
        // `numberOfWordslastData` without underflow and the metadata looks structurally valid.
        //
        // The lookup table occupies word 1 (bytes 32..63), so firstOffset = 2 would be
        // the normal case for a single entry fitting in one word. But we're forcing offset1 = 255
        // to trigger the overflow.
        //
        // However, the code path that increments offsets only fires when the new entry does NOT
        // fit in the current last table word (i + TOTAL_ID_SIZE >= firstOffset * WORD_SIZE).
        // With one existing entry (5 bytes at position 32..36) and firstOffset derived from the
        // first entry's offset byte, we need to ensure the table is full enough to trigger growth.
        //
        // Strategy: fill the lookup table so that it occupies exactly `firstOffset - 1` words
        // (i.e. words 1 through firstOffset-1), and the last entry's position is near the end
        // of that region. Then adding one more entry will overflow the table word, triggering
        // the offset increment loop.
        //
        // Simpler approach: pack 6 entries into the table (6 * 5 = 30 bytes, which fills word 1
        // almost completely at bytes 32..61). firstOffset comes from the first entry's offset byte.
        // Set all 6 offset bytes to 255. The table ends at byte 61, and firstOffset = 255 means
        // data starts at 255*32 = 8160. When we add entry 7, position 62 + 5 = 67 >= 255*32
        // is false... so this won't trigger growth.
        //
        // The growth condition is `i + TOTAL_ID_SIZE >= firstOffset * WORD_SIZE` where i is the
        // byte index of the last non-zero byte scanning backward from firstOffset*WORD_SIZE - 1.
        // With firstOffset = 2, data starts at byte 64. 6 entries take bytes 32..61. The 7th
        // entry would start at byte 62, and 62 + 5 = 67 >= 64, triggering growth. But we need
        // offset = 255 to trigger overflow.
        //
        // The key insight: we need firstOffset to be small (so the table is nearly full and growth
        // is triggered), but one of the EXISTING offset bytes to be 255.
        //
        // We can achieve this by:
        //   - Having 6 entries in the table (30 bytes, nearly filling one 32-byte word)
        //   - firstOffset = 2 (from the first entry, normal for 1 table word)
        //   - The last entry has offset byte = 255
        //   - We need enough data padding to make the metadata length consistent.
        //
        // Actually, the simplest approach: use createMetadata to build valid metadata with many
        // entries so offsets are high, then manually patch an offset byte to 255. But that's
        // fragile. Instead, let's hand-craft minimal metadata that triggers the exact code path.

        // Minimal approach: 6 entries in lookup table, first offset = 2.
        // Entry offsets: [2, 3, 4, 5, 6, 255]
        // Data: 5 entries of 1 word each at offsets 2-6, plus a huge gap to offset 255.
        // Total metadata length must be at least 255*32 + 32 = 8192.

        bytes memory originalMetadata = new bytes(8192);

        // Word 0 (bytes 0-31): reserved - leave as zeros.

        // Word 1 (bytes 32-63): lookup table with 6 entries (30 bytes + 2 bytes padding).
        // Entry 1: id=0x11111111, offset=2
        originalMetadata[32] = 0x11;
        originalMetadata[33] = 0x11;
        originalMetadata[34] = 0x11;
        originalMetadata[35] = 0x11;
        originalMetadata[36] = bytes1(uint8(2)); // offset = 2

        // Entry 2: id=0x22222222, offset=3
        originalMetadata[37] = 0x22;
        originalMetadata[38] = 0x22;
        originalMetadata[39] = 0x22;
        originalMetadata[40] = 0x22;
        originalMetadata[41] = bytes1(uint8(3)); // offset = 3

        // Entry 3: id=0x33333333, offset=4
        originalMetadata[42] = 0x33;
        originalMetadata[43] = 0x33;
        originalMetadata[44] = 0x33;
        originalMetadata[45] = 0x33;
        originalMetadata[46] = bytes1(uint8(4)); // offset = 4

        // Entry 4: id=0x44444444, offset=5
        originalMetadata[47] = 0x44;
        originalMetadata[48] = 0x44;
        originalMetadata[49] = 0x44;
        originalMetadata[50] = 0x44;
        originalMetadata[51] = bytes1(uint8(5)); // offset = 5

        // Entry 5: id=0x55555555, offset=6
        originalMetadata[52] = 0x55;
        originalMetadata[53] = 0x55;
        originalMetadata[54] = 0x55;
        originalMetadata[55] = 0x55;
        originalMetadata[56] = bytes1(uint8(6)); // offset = 6

        // Entry 6: id=0x66666666, offset=255 -- this is the one that will overflow
        originalMetadata[57] = 0x66;
        originalMetadata[58] = 0x66;
        originalMetadata[59] = 0x66;
        originalMetadata[60] = 0x66;
        originalMetadata[61] = bytes1(uint8(255)); // offset = 255 -- will overflow on increment

        // Bytes 62-63: padding (zeros) -- already zero.

        // Fill some data at offset 2 (byte 64) through offset 6 (byte 224) so the structure
        // is valid. Just leave as zeros (already initialized).

        // Fill one word of data at offset 255 (byte 8160) to make numberOfWordslastData = 1.
        // Just needs to exist in the allocation, which it does since length = 8192.
        originalMetadata[8160] = 0xAB; // Some non-zero data.

        // The new data to add (must be >= 32 bytes and padded to 32).
        bytes memory dataToAdd = abi.encode(uint256(42));

        // Now call addToMetadata. The code will:
        // 1. Find firstOffset = 2 (from byte 36)
        // 2. Scan backward from byte 63 to find the last non-zero byte: byte 61 (offset=255)
        // 3. Check if new entry fits: 61 + 5 = 66 >= 2*32 = 64 => YES, table must grow
        // 4. Loop to increment all offset bytes -- byte 61 has value 255, 255+1 overflows!
        //
        // Before the fix: wraps to 0 silently, corrupting the table.
        // After the fix: reverts with JBMetadataResolver_MetadataTooLong.
        vm.expectRevert(JBMetadataResolver.JBMetadataResolver_MetadataTooLong.selector);
        parser.addDataToMetadata(originalMetadata, bytes4(0x77777777), dataToAdd);
    }

    /// @notice Sanity check: adding to metadata with offset < 255 still works after the fix.
    function test_addToMetadata_offsetNoOverflow_succeeds() external view {
        // Use the library normally: create metadata with a few entries, then add one more.
        bytes4[] memory ids = new bytes4[](2);
        bytes[] memory datas = new bytes[](2);

        ids[0] = bytes4(0x11111111);
        ids[1] = bytes4(0x22222222);
        datas[0] = abi.encode(uint256(100));
        datas[1] = abi.encode(uint256(200));

        bytes memory metadata = parser.createMetadata(ids, datas);

        // Add a third entry -- offsets are small, no overflow.
        bytes memory modified = parser.addDataToMetadata(metadata, bytes4(0x33333333), abi.encode(uint256(300)));

        // Verify all three entries are retrievable.
        (bool found1, bytes memory data1) = parser.getDataFor(bytes4(0x11111111), modified);
        assertTrue(found1);
        assertEq(abi.decode(data1, (uint256)), 100);

        (bool found2, bytes memory data2) = parser.getDataFor(bytes4(0x22222222), modified);
        assertTrue(found2);
        assertEq(abi.decode(data2, (uint256)), 200);

        (bool found3, bytes memory data3) = parser.getDataFor(bytes4(0x33333333), modified);
        assertTrue(found3);
        assertEq(abi.decode(data3, (uint256)), 300);
    }
}
