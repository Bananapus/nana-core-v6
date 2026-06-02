// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JBTerminalStore} from "../../src/JBTerminalStore.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Used for tests in TestAccessToFunds.sol
/// @dev Attempts to re-enter sendPayoutsOf after receiving control-flow.
contract MaliciousPayoutBeneficiary is IERC721Receiver, Test {
    function reEnter(address _terminal) internal {
        // Reentrancy attempt — payout limit already used, so the cap returns 0 (no funds extracted).
        uint256 _reentrantPayout = IJBMultiTerminal(_terminal)
            .sendPayoutsOf({
            projectId: 2,
            amount: 5 * 10 ** 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });
        assertEq(_reentrantPayout, 0);
    }

    receive() external payable {
        if (msg.value > 0) reEnter(address(msg.sender));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Used for tests in TestAccessToFunds.sol
/// @dev Attempts to re-enter useAllowanceOf after receiving control-flow.
contract MaliciousAllowanceBeneficiary is IERC721Receiver, Test {
    function reEnter(address _terminal) internal {
        vm.expectRevert(
            abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_InadequateControllerAllowance.selector, 1e19, 5e18)
        );

        IJBMultiTerminal(_terminal)
            .useAllowanceOf({
            projectId: 2,
            amount: 5 * 10 ** 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0,
            beneficiary: payable(address(this)),
            feeBeneficiary: payable(0x000000000000000000000000000000000000007B),
            memo: "MEMO"
        });
    }

    receive() external payable {
        if (msg.value > 0) reEnter(address(msg.sender));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
