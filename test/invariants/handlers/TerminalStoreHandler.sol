// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {IJBMultiTerminal} from "../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminalStore} from "../../../src/interfaces/IJBTerminalStore.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBTokens} from "../../../src/interfaces/IJBTokens.sol";

/// @notice Handler contract for JBTerminalStore invariant testing.
/// @dev Wraps terminal operations and tracks ghost variables for conservation checks.
contract TerminalStoreHandler is Test {
    IJBMultiTerminal public terminal;
    IJBTerminalStore public store;
    IJBController public controller;
    IJBTokens public tokens;

    uint256 public projectId;
    address public projectOwner;

    // Ghost variables for fund tracking
    uint256 public ghost_totalPaidIn;
    uint256 public ghost_totalCashedOut;
    uint256 public ghost_totalPaidOut;
    uint256 public ghost_totalAddedToBalance;

    // Track actors
    address[] public actors;
    mapping(address => bool) public isActor;
    uint256 public constant NUM_ACTORS = 5;

    constructor(
        IJBMultiTerminal _terminal,
        IJBTerminalStore _store,
        IJBController _controller,
        IJBTokens _tokens,
        uint256 _projectId,
        address _projectOwner
    ) {
        terminal = _terminal;
        store = _store;
        controller = _controller;
        tokens = _tokens;
        projectId = _projectId;
        projectOwner = _projectOwner;

        // Create actor addresses
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);
            isActor[actor] = true;
        }
    }

    /// @notice Selects an actor based on a seed.
    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Pay the project with native tokens.
    function payProject(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);
        address actor = _getActor(actorSeed);

        vm.deal(actor, amount);
        vm.prank(actor);
        terminal.pay{value: amount}({
            projectId: projectId,
            amount: amount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        ghost_totalPaidIn += amount;
    }

    /// @notice Cash out tokens for native tokens.
    function cashOutTokens(uint256 actorSeed, uint256 cashOutPercent) public {
        address actor = _getActor(actorSeed);
        uint256 tokenBalance = tokens.totalBalanceOf(actor, projectId);
        if (tokenBalance == 0) return;

        cashOutPercent = bound(cashOutPercent, 1, 100);
        uint256 cashOutCount = (tokenBalance * cashOutPercent) / 100;
        if (cashOutCount == 0) return;

        vm.prank(actor);
        uint256 reclaimAmount = terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: new bytes(0)
        });

        ghost_totalCashedOut += reclaimAmount;
    }

    /// @notice Send payouts from the project.
    function sendPayouts(uint256 amount) public {
        uint256 balance = store.balanceOf(address(terminal), projectId, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(projectOwner);
        try terminal.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        }) returns (
            uint256 amountPaidOut
        ) {
            ghost_totalPaidOut += amountPaidOut;
        } catch {
            // Payout may fail if there's no payout limit configured
        }
    }

    /// @notice Add to project balance without minting tokens.
    function addToBalance(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 50 ether);

        vm.deal(address(this), amount);
        terminal.addToBalanceOf{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        ghost_totalAddedToBalance += amount;
    }

    receive() external payable {}
}
