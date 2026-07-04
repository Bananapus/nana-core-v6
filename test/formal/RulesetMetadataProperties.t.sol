// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";

/// @title RulesetMetadataProperties
/// @notice Formal verification of `JBRulesetMetadataResolver` bit-layout edge cases using symbolic execution.
/// @dev Works with both Halmos (`check_*`) and forge test (`testFuzz_*`). The full pack→expand round trip (all
///      fields within their bit ranges) is already proven in `BondingCurveProperties`. This file covers the two
///      edge cases that round trip does NOT exercise, both documented as sharp edges in the resolver's natspec:
///      (1) the custom `metadata` field is silently truncated to 14 bits, and (2) the version bits (0-3) must never
///      spill into `reservedPercent` (bit 4+). The packing is pure bit-shift/mask (no `mulDiv`), so Halmos proves
///      these over the full input domain fast.
contract RulesetMetadataProperties is Test {
    /// @dev Wrap a packed metadata word into a `JBRuleset` so the resolver getters can read it.
    function _wrap(uint256 packed) internal pure returns (JBRuleset memory) {
        return JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });
    }

    // =========================================================================
    // Property 1: the custom `metadata` field is truncated to 14 bits (upper 2 bits ignored)
    // =========================================================================
    /// @notice `packRulesetMetadata` masks the custom `metadata` field with `& 0x3FFF`, so packing then reading it
    ///         back always yields the low 14 bits of the input and can never exceed `0x3FFF`. This documents the
    ///         intentional narrowing the struct natspec notes ("upper 2 bits are ignored") — a value above `0x3FFF`
    ///         is silently dropped, not stored. The round-trip test in `BondingCurveProperties` assumes
    ///         `extraMetadata <= 0x3FFF`, so this above-range behavior is otherwise unproven.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_metadata_customFieldTruncatedTo14Bits(uint16 metadata_) public pure {
        JBRulesetMetadata memory m;
        m.metadata = metadata_;
        uint16 out = JBRulesetMetadataResolver.metadata(_wrap(JBRulesetMetadataResolver.packRulesetMetadata(m)));

        assert(out == (metadata_ & 0x3FFF));
        assert(out <= 0x3FFF);
    }

    function testFuzz_metadata_customFieldTruncatedTo14Bits(uint16 metadata_) public pure {
        JBRulesetMetadata memory m;
        m.metadata = metadata_;
        uint16 out = JBRulesetMetadataResolver.metadata(_wrap(JBRulesetMetadataResolver.packRulesetMetadata(m)));

        assertEq(out, metadata_ & 0x3FFF, "metadata truncated to low 14 bits");
        assertLe(out, 0x3FFF, "metadata never exceeds 14-bit max");
    }

    // =========================================================================
    // Property 2: version bits (0-3) are always 1 and never spill into `reservedPercent`
    // =========================================================================
    /// @notice `packRulesetMetadata` writes version `1` into bits 0-3 unconditionally, and `reservedPercent` begins
    ///         at bit 4. This proves the exact concern the packing natspec flags: the version field never corrupts
    ///         `reservedPercent`, for any reservedPercent value.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_metadata_versionBitsIsolatedFromReservedPercent(uint16 reservedPercent) public pure {
        JBRulesetMetadata memory m;
        m.reservedPercent = reservedPercent;
        uint256 packed = JBRulesetMetadataResolver.packRulesetMetadata(m);

        assert(packed & 0xF == 1); // version occupies bits 0-3 and is always 1
        assert(JBRulesetMetadataResolver.reservedPercent(_wrap(packed)) == reservedPercent); // bits 4-19 intact
    }

    function testFuzz_metadata_versionBitsIsolatedFromReservedPercent(uint16 reservedPercent) public pure {
        JBRulesetMetadata memory m;
        m.reservedPercent = reservedPercent;
        uint256 packed = JBRulesetMetadataResolver.packRulesetMetadata(m);

        assertEq(packed & 0xF, 1, "version bits always 1");
        assertEq(JBRulesetMetadataResolver.reservedPercent(_wrap(packed)), reservedPercent, "reservedPercent intact");
    }
}
