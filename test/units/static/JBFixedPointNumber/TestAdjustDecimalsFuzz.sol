// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBFixedPointNumber} from "../../../../src/libraries/JBFixedPointNumber.sol";

/// @notice Fuzz tests for JBFixedPointNumber.adjustDecimals.
contract TestAdjustDecimalsFuzz_Local is JBTest {
    function setUp() external {}

    /// @notice Same decimals returns the value unchanged.
    function testFuzz_sameDecimals(uint256 value, uint8 decimals) external pure {
        decimals = uint8(bound(uint256(decimals), 0, 36));
        uint256 result = JBFixedPointNumber.adjustDecimals(value, decimals, decimals);
        assertEq(result, value, "same decimals should return value unchanged");
    }

    /// @notice Scale up then down round-trip preserves value (modulo rounding loss).
    function testFuzz_roundTrip_upThenDown(uint256 value, uint8 fromDecimals, uint8 toDecimals) external pure {
        fromDecimals = uint8(bound(uint256(fromDecimals), 0, 18));
        toDecimals = uint8(bound(uint256(toDecimals), fromDecimals, 36));

        // Avoid overflow: value * 10^(toDecimals - fromDecimals) must fit in uint256
        uint256 scaleFactor = 10 ** (toDecimals - fromDecimals);
        if (scaleFactor > 0 && value > type(uint256).max / scaleFactor) return;

        uint256 scaled = JBFixedPointNumber.adjustDecimals(value, fromDecimals, toDecimals);
        uint256 restored = JBFixedPointNumber.adjustDecimals(scaled, toDecimals, fromDecimals);

        assertEq(restored, value, "round trip (up then down) should restore original value");
    }

    /// @notice Scale down then up loses precision but never exceeds original.
    function testFuzz_roundTrip_downThenUp(uint256 value, uint8 fromDecimals, uint8 toDecimals) external pure {
        fromDecimals = uint8(bound(uint256(fromDecimals), 0, 36));
        toDecimals = uint8(bound(uint256(toDecimals), 0, fromDecimals));

        uint256 scaled = JBFixedPointNumber.adjustDecimals(value, fromDecimals, toDecimals);

        // Scale back up
        uint256 scaleFactor = 10 ** (fromDecimals - toDecimals);
        if (scaleFactor > 0 && scaled > type(uint256).max / scaleFactor) return;

        uint256 restored = JBFixedPointNumber.adjustDecimals(scaled, toDecimals, fromDecimals);

        assertLe(restored, value, "round trip (down then up) should not exceed original");
    }

    /// @notice Scaling up increases value when decimals differ.
    function testFuzz_scaleUp_increases(uint256 value, uint8 fromDecimals, uint8 toDecimals) external pure {
        value = bound(value, 1, 1e36);
        fromDecimals = uint8(bound(uint256(fromDecimals), 0, 18));
        toDecimals = uint8(bound(uint256(toDecimals), fromDecimals + 1, 36));

        uint256 result = JBFixedPointNumber.adjustDecimals(value, fromDecimals, toDecimals);
        assertGt(result, value, "scaling up with more decimals should increase value");
    }

    /// @notice Scaling down returns zero for small values.
    function testFuzz_scaleDown_smallValue(uint8 fromDecimals, uint8 toDecimals) external pure {
        fromDecimals = uint8(bound(uint256(fromDecimals), 1, 36));
        toDecimals = uint8(bound(uint256(toDecimals), 0, fromDecimals - 1));

        uint256 scaleFactor = 10 ** (fromDecimals - toDecimals);
        // Value smaller than the scale factor should round to 0
        uint256 value = scaleFactor - 1;

        uint256 result = JBFixedPointNumber.adjustDecimals(value, fromDecimals, toDecimals);
        assertEq(result, 0, "value below scale factor should round to 0");
    }
}
