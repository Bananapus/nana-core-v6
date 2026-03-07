// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {JBPermissions} from "../src/JBPermissions.sol";
import {IJBPermissions} from "../src/interfaces/IJBPermissions.sol";
import {JBPermissionsData} from "../src/structs/JBPermissionsData.sol";

/// @title PermissionsHandler
/// @notice Stateful handler for JBPermissions invariant testing.
///         Randomly sets, revokes, and checks permissions while tracking expected state.
contract PermissionsHandler is CommonBase, StdCheats, StdUtils {
    JBPermissions public immutable permissions;

    address[] public accounts;
    address[] public operators;
    uint56[] public projectIds;

    // Ghost state: track what we've set.
    // Keyed by keccak256(operator, account, projectId).
    mapping(bytes32 => uint256) public expectedPacked;

    // Counters.
    uint256 public setCount;
    uint256 public revokeCount;
    uint256 public rootSetCount;
    uint256 public rootForwardAttempts;
    uint256 public rootForwardBlocked;
    uint256 public wildcardSetAttempts;
    uint256 public wildcardSetBlocked;

    constructor() {
        permissions = new JBPermissions(address(0));

        accounts.push(makeAddr("accountA"));
        accounts.push(makeAddr("accountB"));
        accounts.push(makeAddr("accountC"));

        operators.push(makeAddr("operatorX"));
        operators.push(makeAddr("operatorY"));
        operators.push(makeAddr("operatorZ"));

        projectIds.push(1);
        projectIds.push(2);
        projectIds.push(3);
    }

    /// @notice Set random permissions for a random (operator, account, projectId) triple.
    function setPermissions(
        uint256 accountSeed,
        uint256 operatorSeed,
        uint256 projectSeed,
        uint8[] memory permissionIds
    )
        public
    {
        address account = accounts[bound(accountSeed, 0, accounts.length - 1)];
        address operator = operators[bound(operatorSeed, 0, operators.length - 1)];
        uint56 projectId = projectIds[bound(projectSeed, 0, projectIds.length - 1)];

        // Filter out permission ID 0 (invalid) and truncate long arrays.
        if (permissionIds.length > 10) {
            assembly {
                mstore(permissionIds, 10)
            }
        }

        uint8[] memory validIds = new uint8[](permissionIds.length);
        uint256 validCount;
        for (uint256 i; i < permissionIds.length; i++) {
            if (permissionIds[i] > 0) {
                validIds[validCount] = permissionIds[i];
                validCount++;
            }
        }

        // Resize to valid count.
        uint8[] memory finalIds = new uint8[](validCount);
        for (uint256 i; i < validCount; i++) {
            finalIds[i] = validIds[i];
        }

        // Track expected state.
        bytes32 key = keccak256(abi.encodePacked(operator, account, projectId));
        uint256 packed;
        for (uint256 i; i < validCount; i++) {
            packed |= uint256(1) << finalIds[i];
        }
        expectedPacked[key] = packed;

        // Account sets permissions for itself.
        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: finalIds})
        );

        setCount++;

        // Track ROOT sets.
        for (uint256 i; i < validCount; i++) {
            if (finalIds[i] == 1) {
                rootSetCount++;
                break;
            }
        }
    }

    /// @notice Revoke permissions by setting empty array.
    function revokePermissions(uint256 accountSeed, uint256 operatorSeed, uint256 projectSeed) public {
        address account = accounts[bound(accountSeed, 0, accounts.length - 1)];
        address operator = operators[bound(operatorSeed, 0, operators.length - 1)];
        uint56 projectId = projectIds[bound(projectSeed, 0, projectIds.length - 1)];

        bytes32 key = keccak256(abi.encodePacked(operator, account, projectId));
        expectedPacked[key] = 0;

        uint8[] memory emptyIds = new uint8[](0);

        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: emptyIds})
        );

        revokeCount++;
    }

    /// @notice Attempt ROOT forwarding (should always be blocked).
    function attemptRootForwarding(uint256 accountSeed, uint256 projectSeed) public {
        address account = accounts[bound(accountSeed, 0, accounts.length - 1)];
        address operator = operators[0]; // operatorX
        address thirdParty = operators[1]; // operatorY
        uint56 projectId = projectIds[bound(projectSeed, 0, projectIds.length - 1)];

        rootForwardAttempts++;

        // First give operator ROOT.
        uint8[] memory rootPerms = new uint8[](1);
        rootPerms[0] = 1; // ROOT

        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: rootPerms})
        );

        // Update ghost state.
        bytes32 rootKey = keccak256(abi.encodePacked(operator, account, projectId));
        expectedPacked[rootKey] = uint256(1) << 1;

        // Now operator tries to forward ROOT to thirdParty.
        vm.prank(operator);
        try permissions.setPermissionsFor(
            account, JBPermissionsData({operator: thirdParty, projectId: projectId, permissionIds: rootPerms})
        ) {
            // Should not reach here.
        } catch {
            rootForwardBlocked++;
        }
    }

    /// @notice Attempt wildcard permission setting by operator (should be blocked).
    function attemptWildcardByOperator(uint256 accountSeed, uint256 projectSeed) public {
        address account = accounts[bound(accountSeed, 0, accounts.length - 1)];
        address operator = operators[0];
        address thirdParty = operators[1];
        uint56 projectId = projectIds[bound(projectSeed, 0, projectIds.length - 1)];

        wildcardSetAttempts++;

        // Give operator ROOT on a specific project.
        uint8[] memory rootPerms = new uint8[](1);
        rootPerms[0] = 1;

        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: rootPerms})
        );

        bytes32 rootKey = keccak256(abi.encodePacked(operator, account, projectId));
        expectedPacked[rootKey] = uint256(1) << 1;

        // Operator tries to set permission on wildcard project (0).
        uint8[] memory somePerms = new uint8[](1);
        somePerms[0] = 5;

        vm.prank(operator);
        try permissions.setPermissionsFor(
            account, JBPermissionsData({operator: thirdParty, projectId: 0, permissionIds: somePerms})
        ) {
            // Should not reach here.
        } catch {
            wildcardSetBlocked++;
        }
    }

    /// @notice Get the expected packed permissions for a triple.
    function getExpected(address operator, address account, uint56 projectId) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(operator, account, projectId));
        return expectedPacked[key];
    }
}

/// @title PermissionsInvariantTest
/// @notice Stateful invariant tests proving JBPermissions maintains consistency
///         through random set/revoke cycles.
contract PermissionsInvariantTest is Test {
    PermissionsHandler handler;

    function setUp() public {
        handler = new PermissionsHandler();
        targetContract(address(handler));
    }

    /// @notice Packed permissions in storage always match what was last set.
    function invariant_packedMatchesExpected() public view {
        JBPermissions perms = handler.permissions();

        // Check all (operator, account, projectId) combinations.
        for (uint256 o; o < 3; o++) {
            for (uint256 a; a < 3; a++) {
                for (uint256 p; p < 3; p++) {
                    address operator = handler.operators(o);
                    address account = handler.accounts(a);
                    uint56 projectId = handler.projectIds(p);

                    uint256 expected = handler.getExpected(operator, account, projectId);
                    uint256 actual = perms.permissionsOf(operator, account, projectId);

                    assertEq(actual, expected, "Packed permissions mismatch");
                }
            }
        }
    }

    /// @notice Bit 0 is never set in any stored permissions.
    function invariant_bit0NeverSet() public view {
        JBPermissions perms = handler.permissions();

        for (uint256 o; o < 3; o++) {
            for (uint256 a; a < 3; a++) {
                for (uint256 p; p < 3; p++) {
                    uint256 packed =
                        perms.permissionsOf(handler.operators(o), handler.accounts(a), handler.projectIds(p));
                    assertFalse((packed & 1) == 1, "Bit 0 should never be set");
                }
            }
        }
    }

    /// @notice ROOT forwarding is always blocked.
    function invariant_rootForwardingAlwaysBlocked() public view {
        if (handler.rootForwardAttempts() > 0) {
            assertEq(
                handler.rootForwardBlocked(),
                handler.rootForwardAttempts(),
                "All ROOT forwarding attempts must be blocked"
            );
        }
    }

    /// @notice Wildcard permission setting by operators is always blocked.
    function invariant_wildcardByOperatorAlwaysBlocked() public view {
        if (handler.wildcardSetAttempts() > 0) {
            assertEq(
                handler.wildcardSetBlocked(),
                handler.wildcardSetAttempts(),
                "All wildcard-by-operator attempts must be blocked"
            );
        }
    }

    /// @notice hasPermission returns true iff the bit is set (no false positives/negatives).
    function invariant_hasPermissionMatchesBits() public view {
        JBPermissions perms = handler.permissions();

        // Spot-check a few permission IDs across all triples.
        uint256[5] memory checkIds = [uint256(1), 2, 5, 42, 255];

        for (uint256 o; o < 3; o++) {
            for (uint256 a; a < 3; a++) {
                for (uint256 p; p < 3; p++) {
                    address operator = handler.operators(o);
                    address account = handler.accounts(a);
                    uint56 projectId = handler.projectIds(p);

                    uint256 packed = perms.permissionsOf(operator, account, projectId);

                    for (uint256 c; c < checkIds.length; c++) {
                        bool expected = ((packed >> checkIds[c]) & 1) == 1;
                        bool actual = perms.hasPermission(operator, account, projectId, checkIds[c], false, false);
                        assertEq(actual, expected, "hasPermission must match bit state");
                    }
                }
            }
        }
    }
}

/// @title PermissionsBitPackingTest
/// @notice Formal property tests for JBPermissions bit-packing roundtrip
///         and hasPermissions batch logic.
contract PermissionsBitPackingTest is Test {
    JBPermissions permissions;

    address account = makeAddr("account");
    address operator = makeAddr("operator");
    uint56 projectId = 7;

    function setUp() public {
        permissions = new JBPermissions(address(0));
    }

    /// @notice hasPermissions with an empty array returns true (vacuous truth).
    function test_hasPermissions_emptyArray_returnsTrue() public view {
        uint256[] memory empty = new uint256[](0);
        bool result = permissions.hasPermissions(operator, account, projectId, empty, false, false);
        assertTrue(result, "Empty permission array should return true (vacuous truth)");
    }

    /// @notice Fuzz: set N permissions, verify each bit is set and all others are not.
    function testFuzz_bitPackingRoundtrip(uint8 id1, uint8 id2, uint8 id3) public {
        // Bound to valid range (1-255).
        id1 = uint8(bound(uint256(id1), 1, 255));
        id2 = uint8(bound(uint256(id2), 1, 255));
        id3 = uint8(bound(uint256(id3), 1, 255));

        uint8[] memory ids = new uint8[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: ids})
        );

        // Each set ID should return true.
        assertTrue(
            permissions.hasPermission(operator, account, projectId, id1, false, false),
            "id1 should be set"
        );
        assertTrue(
            permissions.hasPermission(operator, account, projectId, id2, false, false),
            "id2 should be set"
        );
        assertTrue(
            permissions.hasPermission(operator, account, projectId, id3, false, false),
            "id3 should be set"
        );

        // Verify the packed value has exactly the right bits.
        uint256 packed = permissions.permissionsOf(operator, account, projectId);
        uint256 expectedPacked = (uint256(1) << id1) | (uint256(1) << id2) | (uint256(1) << id3);
        assertEq(packed, expectedPacked, "Packed value should exactly match OR of set bits");

        // Bit 0 must not be set.
        assertFalse((packed & 1) == 1, "Bit 0 must never be set");
    }

    /// @notice hasPermissions batch check: all permissions must be present.
    function test_hasPermissions_batch_allRequired() public {
        uint8[] memory ids = new uint8[](3);
        ids[0] = 5;
        ids[1] = 10;
        ids[2] = 200;

        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: ids})
        );

        // All three set → true.
        uint256[] memory check3 = new uint256[](3);
        check3[0] = 5;
        check3[1] = 10;
        check3[2] = 200;
        assertTrue(
            permissions.hasPermissions(operator, account, projectId, check3, false, false),
            "All three should pass"
        );

        // Missing one (15 not set) → false.
        uint256[] memory check4 = new uint256[](4);
        check4[0] = 5;
        check4[1] = 10;
        check4[2] = 200;
        check4[3] = 15;
        assertFalse(
            permissions.hasPermissions(operator, account, projectId, check4, false, false),
            "Missing permission 15 should fail batch check"
        );
    }

    /// @notice Event emission includes correct packed value.
    function test_eventEmission_packedValue() public {
        uint8[] memory ids = new uint8[](2);
        ids[0] = 3;
        ids[1] = 7;

        uint256 expectedPacked = (uint256(1) << 3) | (uint256(1) << 7);

        vm.expectEmit(true, true, true, true);
        emit IJBPermissions.OperatorPermissionsSet(operator, account, projectId, ids, expectedPacked, account);

        vm.prank(account);
        permissions.setPermissionsFor(
            account, JBPermissionsData({operator: operator, projectId: projectId, permissionIds: ids})
        );
    }
}
