// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBSplit} from "../../../../src/structs/JBSplit.sol";
import {IJBSplitHook} from "../../../../src/interfaces/IJBSplitHook.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice Tests that a pay-type split back into the same terminal reverts with MintNotAllowed.
contract TestSelfPayRevert_Local is JBMultiTerminalSetup {
    uint64 _projectId = 1;
    uint256 _defaultAmount = 1e18;
    address _sender = makeAddr("sender");
    address _native = JBConstants.NATIVE_TOKEN;

    function setUp() public {
        super.multiTerminalSetup();
    }

    /// @notice When a split routes a pay back to the same project on the same terminal,
    /// executePayout should revert with MintNotAllowed.
    function test_RevertWhen_SplitPaysBackToSameTerminal() external {
        // Build a split targeting the SAME project with preferAddToBalance = false (pay path).
        JBSplit memory split = JBSplit({
            preferAddToBalance: false,
            percent: 1_000_000_000,
            projectId: _projectId,
            beneficiary: payable(_sender),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // Mock primaryTerminalOf to return this terminal (self-referencing).
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_projectId, _native)),
            abi.encode(address(_terminal))
        );

        // executePayout requires msg.sender == address(this), so we call it via the terminal.
        // The terminal's try-catch in the split group lib would normally catch this.
        vm.prank(address(_terminal));
        vm.expectPartialRevert(JBMultiTerminal.JBMultiTerminal_MintNotAllowed.selector);
        JBMultiTerminal(payable(address(_terminal)))
            .executePayout({
            split: split,
            projectId: uint256(_projectId),
            token: _native,
            amount: _defaultAmount,
            originalMessageSender: _sender
        });
    }
}
