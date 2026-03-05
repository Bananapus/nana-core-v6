// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {IJBMultiTerminal} from "../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminalStore} from "../../../src/interfaces/IJBTerminalStore.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBTokens} from "../../../src/interfaces/IJBTokens.sol";

/// @notice Multi-project economic handler for invariant testing.
/// @dev Manages 3 projects with distinct configurations and 10 actors.
///      Project A: 20% reserved, 60% cash out tax, splits 50% to B
///      Project B: 0% reserved, 0% cash out tax, splits 50% to C
///      Project C: 50% reserved, 80% cash out tax
contract EconomicHandler is Test {
    IJBMultiTerminal public terminal;
    IJBTerminalStore public store;
    IJBController public controller;
    IJBTokens public tokens;

    uint256 public projectA;
    uint256 public projectB;
    uint256 public projectC;
    address public projectOwner;

    // Ghost variables for conservation tracking
    uint256 public ghost_totalPaidInA;
    uint256 public ghost_totalPaidInB;
    uint256 public ghost_totalPaidInC;
    uint256 public ghost_totalCashedOutA;
    uint256 public ghost_totalCashedOutB;
    uint256 public ghost_totalCashedOutC;
    uint256 public ghost_totalPaidOutA;
    uint256 public ghost_totalPaidOutB;
    uint256 public ghost_totalPaidOutC;
    uint256 public ghost_totalAddedToBalanceA;

    // Fee project tracking
    uint256 public ghost_feeProjectBalance;
    uint256 public ghost_feeProjectBalancePrev;
    bool public ghost_feeProjectBalanceDecreased;

    // Cross-project split tracking
    bool public ghost_splitCascadeOccurred;
    uint256 public ghost_projectBBalanceBeforeSplit;
    uint256 public ghost_projectBBalanceAfterSplit;

    // Track actors
    address[] public actors;
    mapping(address => bool) public isActor;
    uint256 public constant NUM_ACTORS = 10;

    // Operation counters
    uint256 public callCount_payA;
    uint256 public callCount_payB;
    uint256 public callCount_payC;
    uint256 public callCount_cashOutA;
    uint256 public callCount_cashOutB;
    uint256 public callCount_cashOutC;
    uint256 public callCount_sendPayoutsA;
    uint256 public callCount_sendPayoutsB;
    uint256 public callCount_sendPayoutsC;
    uint256 public callCount_addToBalanceA;
    uint256 public callCount_sendReservedA;
    uint256 public callCount_sendReservedC;
    uint256 public callCount_advanceTime;

    // Per-actor tracking
    mapping(address => uint256) public actorPaidInA;
    mapping(address => uint256) public actorCashedOutA;

    constructor(
        IJBMultiTerminal _terminal,
        IJBTerminalStore _store,
        IJBController _controller,
        IJBTokens _tokens,
        uint256 _projectA,
        uint256 _projectB,
        uint256 _projectC,
        address _projectOwner
    ) {
        terminal = _terminal;
        store = _store;
        controller = _controller;
        tokens = _tokens;
        projectA = _projectA;
        projectB = _projectB;
        projectC = _projectC;
        projectOwner = _projectOwner;

        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = address(uint160(0x3000 + i));
            actors.push(actor);
            isActor[actor] = true;
        }

        ghost_feeProjectBalance = store.balanceOf(address(terminal), 1, JBConstants.NATIVE_TOKEN);
        ghost_feeProjectBalancePrev = ghost_feeProjectBalance;
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _trackFeeProjectBalance() internal {
        ghost_feeProjectBalancePrev = ghost_feeProjectBalance;
        ghost_feeProjectBalance = store.balanceOf(address(terminal), 1, JBConstants.NATIVE_TOKEN);
        if (ghost_feeProjectBalance < ghost_feeProjectBalancePrev) {
            ghost_feeProjectBalanceDecreased = true;
        }
    }

    // =========================================================================
    // Operations
    // =========================================================================

    function payProjectA(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 5 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.pay{value: amount}(projectA, JBConstants.NATIVE_TOKEN, amount, actor, 0, "", "") {
            ghost_totalPaidInA += amount;
            actorPaidInA[actor] += amount;
            callCount_payA++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function payProjectB(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 5 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.pay{value: amount}(projectB, JBConstants.NATIVE_TOKEN, amount, actor, 0, "", "") {
            ghost_totalPaidInB += amount;
            callCount_payB++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function payProjectC(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 5 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.pay{value: amount}(projectC, JBConstants.NATIVE_TOKEN, amount, actor, 0, "", "") {
            ghost_totalPaidInC += amount;
            callCount_payC++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function cashOutA(uint256 seed) external {
        address actor = _getActor(seed);
        // Use the actor's actual token balance (credits + ERC20), not total supply
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectA);
        if (actorBalance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, actorBalance);
        if (cashOutAmount == 0) return;

        vm.prank(actor);
        try terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectA,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: ""
        }) returns (
            uint256 reclaimAmount
        ) {
            ghost_totalCashedOutA += reclaimAmount;
            actorCashedOutA[actor] += reclaimAmount;
            callCount_cashOutA++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function cashOutB(uint256 seed) external {
        address actor = _getActor(seed);
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectB);
        if (actorBalance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, actorBalance);
        if (cashOutAmount == 0) return;

        vm.prank(actor);
        try terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectB,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: ""
        }) returns (
            uint256 reclaimAmount
        ) {
            ghost_totalCashedOutB += reclaimAmount;
            callCount_cashOutB++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function cashOutC(uint256 seed) external {
        address actor = _getActor(seed);
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectC);
        if (actorBalance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, actorBalance);
        if (cashOutAmount == 0) return;

        vm.prank(actor);
        try terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectC,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: ""
        }) returns (
            uint256 reclaimAmount
        ) {
            ghost_totalCashedOutC += reclaimAmount;
            callCount_cashOutC++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function sendPayoutsA(uint256 seed) external {
        uint256 balance = store.balanceOf(address(terminal), projectA, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        uint256 amount = bound(seed, 1, balance);

        // Track B's balance before payout (for cross-project split cascade)
        ghost_projectBBalanceBeforeSplit = store.balanceOf(address(terminal), projectB, JBConstants.NATIVE_TOKEN);

        vm.prank(projectOwner);
        try terminal.sendPayoutsOf({
            projectId: projectA,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        }) returns (
            uint256 amountPaidOut
        ) {
            ghost_totalPaidOutA += amountPaidOut;
            callCount_sendPayoutsA++;

            // Track B's balance after payout
            ghost_projectBBalanceAfterSplit = store.balanceOf(address(terminal), projectB, JBConstants.NATIVE_TOKEN);
            if (ghost_projectBBalanceAfterSplit > ghost_projectBBalanceBeforeSplit) {
                ghost_splitCascadeOccurred = true;
            }
        } catch {}
        _trackFeeProjectBalance();
    }

    function sendPayoutsB(uint256 seed) external {
        uint256 balance = store.balanceOf(address(terminal), projectB, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        uint256 amount = bound(seed, 1, balance);

        vm.prank(projectOwner);
        try terminal.sendPayoutsOf({
            projectId: projectB,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        }) returns (
            uint256 amountPaidOut
        ) {
            ghost_totalPaidOutB += amountPaidOut;
            callCount_sendPayoutsB++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function sendPayoutsC(uint256 seed) external {
        uint256 balance = store.balanceOf(address(terminal), projectC, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        uint256 amount = bound(seed, 1, balance);

        vm.prank(projectOwner);
        try terminal.sendPayoutsOf({
            projectId: projectC,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        }) returns (
            uint256 amountPaidOut
        ) {
            ghost_totalPaidOutC += amountPaidOut;
            callCount_sendPayoutsC++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function addToBalanceA(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 1 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.addToBalanceOf{value: amount}(projectA, JBConstants.NATIVE_TOKEN, amount, false, "", "") {
            ghost_totalAddedToBalanceA += amount;
            callCount_addToBalanceA++;
        } catch {}
        _trackFeeProjectBalance();
    }

    function sendReservedTokensA(uint256 seed) external {
        seed; // unused but needed for handler interface
        vm.prank(projectOwner);
        try controller.sendReservedTokensToSplitsOf(projectA) {
            callCount_sendReservedA++;
        } catch {}
    }

    function sendReservedTokensC(uint256 seed) external {
        seed;
        vm.prank(projectOwner);
        try controller.sendReservedTokensToSplitsOf(projectC) {
            callCount_sendReservedC++;
        } catch {}
    }

    function advanceTime(uint256 seed) external {
        uint256 delta = bound(seed, 1 hours, 30 days);
        vm.warp(block.timestamp + delta);
        callCount_advanceTime++;
    }
}
