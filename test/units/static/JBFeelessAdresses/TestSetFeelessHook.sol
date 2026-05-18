// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBFeelessAddresses} from "../../../../src/JBFeelessAddresses.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBFeelessHook} from "../../../../src/interfaces/IJBFeelessHook.sol";
import {
    MockFeelessHook,
    MockNonConformingFeelessHook,
    MockEoaLikeFeelessHook
} from "../../../mock/MockFeelessHook.sol";
import {JBFeelessSetup} from "./JBFeelessSetup.sol";

contract TestSetFeelessHook_Local is JBFeelessSetup {
    address internal _user = makeAddr("user");
    address internal _multisig = makeAddr("multisig");
    MockFeelessHook internal _hook;

    function setUp() public {
        super.feelessAddressesSetup();
        _hook = new MockFeelessHook();
    }

    //*********************************************************************//
    // -------------------- setFeelessHook: access ----------------------- //
    //*********************************************************************//

    function test_SetFeelessHook_WhenCallerIsOwner_StoresAndEmits() external {
        vm.expectEmit();
        emit IJBFeelessAddresses.SetFeelessHook(_hook, _owner);

        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(address(_feelessAddresses.feelessHook()), address(_hook));
    }

    function test_SetFeelessHook_WhenCallerIsOwner_AcceptsZeroAddress() external {
        // First set a real hook so we can confirm zero clears it.
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);
        assertEq(address(_feelessAddresses.feelessHook()), address(_hook));

        vm.expectEmit();
        emit IJBFeelessAddresses.SetFeelessHook(IJBFeelessHook(address(0)), _owner);

        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(IJBFeelessHook(address(0)));

        assertEq(address(_feelessAddresses.feelessHook()), address(0));
    }

    function test_SetFeelessHook_RevertWhen_CallerIsNotOwner() external {
        vm.prank(_multisig);
        bytes4 selector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        vm.expectRevert(abi.encodeWithSelector(selector, _multisig));
        _feelessAddresses.setFeelessHook(_hook);
    }

    //*********************************************************************//
    // -------------------- setFeelessHook: validation ------------------- //
    //*********************************************************************//

    function test_SetFeelessHook_RevertWhen_HookDoesNotAdvertiseInterface() external {
        MockNonConformingFeelessHook bad = new MockNonConformingFeelessHook();

        vm.prank(_owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBFeelessAddresses.JBFeelessAddresses_InvalidFeelessHook.selector, IJBFeelessHook(address(bad))
            )
        );
        _feelessAddresses.setFeelessHook(IJBFeelessHook(address(bad)));
    }

    function test_SetFeelessHook_RevertWhen_HookHasNoSupportsInterface() external {
        // EOA-like contract: no supportsInterface implementation at all.
        MockEoaLikeFeelessHook bad = new MockEoaLikeFeelessHook();

        vm.prank(_owner);
        // The bare call returns no data, which solc decodes as a revert here.
        vm.expectRevert();
        _feelessAddresses.setFeelessHook(IJBFeelessHook(address(bad)));
    }

    function test_SetFeelessHook_RevertWhen_HookIsEoa() external {
        // A plain address has no code; supportsInterface call returns no data.
        address eoa = makeAddr("eoa-hook");

        vm.prank(_owner);
        vm.expectRevert();
        _feelessAddresses.setFeelessHook(IJBFeelessHook(eoa));
    }

    //*********************************************************************//
    // -------------------- isFeelessFor: hook integration --------------- //
    //*********************************************************************//

    function test_IsFeelessFor_ReturnsFalse_WhenNoHookAndNoStatic() external view {
        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 1}), false);
    }

    function test_IsFeelessFor_ReturnsTrue_WhenHookSaysTrue() external {
        _hook.setDefaultResult(true);
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), true);
    }

    function test_IsFeelessFor_ReturnsFalse_WhenHookSaysFalse() external {
        _hook.setDefaultResult(false);
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), false);
    }

    function test_IsFeelessFor_HookCannotShrinkStaticFeelessSet() external {
        // Set static feeless for the user globally.
        vm.prank(_owner);
        _feelessAddresses.setFeelessAddress(_user, true);

        // Hook says false — static should still win because of OR semantics.
        _hook.setDefaultResult(false);
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), true);
    }

    function test_IsFeelessFor_HookCanGrantPerProjectFeeless() external {
        _hook.setMode(3); // allowlist mode
        _hook.setAllowed(42, _user, true);

        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 42}), true);
        // Different project: hook says no, static says no.
        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 43}), false);
    }

    function test_IsFeelessFor_RevertingHookTreatedAsFalse_CustomError() external {
        _hook.setMode(1); // revert Nope()
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        // Should not bubble up — try/catch swallows the revert and returns false.
        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), false);
    }

    function test_IsFeelessFor_RevertingHookTreatedAsFalse_RequireString() external {
        _hook.setMode(2); // require(false, "nope")
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), false);
    }

    function test_IsFeelessFor_RevertingHookDoesNotShrinkStatic() external {
        // Static says feeless; hook reverts — must still be feeless.
        vm.prank(_owner);
        _feelessAddresses.setFeelessAddress(_user, true);

        _hook.setMode(1);
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), true);
    }

    function test_IsFeelessFor_ClearingHookRestoresStaticOnlyBehavior() external {
        // Hook says everyone is feeless.
        _hook.setDefaultResult(true);
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);
        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), true);

        // Clear the hook.
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(IJBFeelessHook(address(0)));

        assertEq(_feelessAddresses.isFeelessFor({addr: _user, projectId: 7}), false);
    }

    //*********************************************************************//
    // -------------------- fuzz: hook honored across inputs ------------- //
    //*********************************************************************//

    function testFuzz_IsFeelessFor_HookHonored(uint256 projectId, address addr, bool hookSays) external {
        // Avoid the wildcard sentinel projectId == 0 collision with static lookups (irrelevant here
        // since we set no statics, but keeps the test focused on hook behavior).
        vm.assume(projectId != 0);
        vm.assume(addr != address(0));

        _hook.setDefaultResult(hookSays);
        vm.prank(_owner);
        _feelessAddresses.setFeelessHook(_hook);

        assertEq(_feelessAddresses.isFeelessFor({addr: addr, projectId: projectId}), hookSays);
    }
}
