// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {IJBMultiTerminal} from "../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminalStore} from "../../../src/interfaces/IJBTerminalStore.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBTokens} from "../../../src/interfaces/IJBTokens.sol";

/// @notice Comprehensive handler for JBTerminalStore invariant testing.
/// @dev Extends the basic handler with 10 operations including reserves, allowance, burns, claims, time, and fees.
contract ComprehensiveHandler is Test {
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
    uint256 public ghost_totalAllowanceUsed;
    uint256 public ghost_feeProjectBalanceLast;
    uint256 public ghost_feeProjectBalanceDecreased; // should always be 0

    // Track actors
    address[] public actors;
    mapping(address => bool) public isActor;
    uint256 public constant NUM_ACTORS = 5;

    // Operation counters for debugging
    uint256 public callCount_pay;
    uint256 public callCount_cashOut;
    uint256 public callCount_sendPayouts;
    uint256 public callCount_addToBalance;
    uint256 public callCount_sendReservedTokens;
    uint256 public callCount_useAllowance;
    uint256 public callCount_burnTokens;
    uint256 public callCount_claimCredits;
    uint256 public callCount_advanceTime;
    uint256 public callCount_processHeldFees;

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
            address actor = address(uint160(0x2000 + i));
            actors.push(actor);
            isActor[actor] = true;
        }

        // Initialize fee project balance tracking
        ghost_feeProjectBalanceLast = store.balanceOf(address(terminal), 1, JBConstants.NATIVE_TOKEN);
    }

    /// @notice Selects an actor based on a seed.
    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Track fee project balance monotonicity.
    function _trackFeeProjectBalance() internal {
        uint256 currentFeeBalance = store.balanceOf(address(terminal), 1, JBConstants.NATIVE_TOKEN);
        if (currentFeeBalance < ghost_feeProjectBalanceLast) {
            ghost_feeProjectBalanceDecreased++;
        }
        ghost_feeProjectBalanceLast = currentFeeBalance;
    }

    // ─── Operation 1: Pay ─────────────────────────────────────────────

    function payProject(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);
        address actor = _getActor(actorSeed);

        vm.deal(actor, amount);
        vm.prank(actor);
        terminal.pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        ghost_totalPaidIn += amount;
        callCount_pay++;
        _trackFeeProjectBalance();
    }

    // ─── Operation 2: Cash Out ────────────────────────────────────────

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
        callCount_cashOut++;
        _trackFeeProjectBalance();
    }

    // ─── Operation 3: Send Payouts ────────────────────────────────────

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
        }) returns (uint256 amountPaidOut) {
            ghost_totalPaidOut += amountPaidOut;
        } catch {}

        callCount_sendPayouts++;
        _trackFeeProjectBalance();
    }

    // ─── Operation 4: Add to Balance ──────────────────────────────────

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
        callCount_addToBalance++;
        _trackFeeProjectBalance();
    }

    // ─── Operation 5: Send Reserved Tokens ────────────────────────────

    function sendReservedTokens() public {
        try controller.sendReservedTokensToSplitsOf(projectId) {} catch {}
        callCount_sendReservedTokens++;
        _trackFeeProjectBalance();
    }

    // ─── Operation 6: Use Allowance ───────────────────────────────────

    function useAllowance(uint256 amount) public {
        uint256 balance = store.balanceOf(address(terminal), projectId, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        amount = bound(amount, 0.001 ether, 3 ether);

        vm.prank(projectOwner);
        try terminal.useAllowanceOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(projectOwner),
            feeBeneficiary: payable(projectOwner),
            memo: "allowance"
        }) returns (uint256 netAmountPaidOut) {
            ghost_totalAllowanceUsed += netAmountPaidOut;
        } catch {}

        callCount_useAllowance++;
        _trackFeeProjectBalance();
    }

    // ─── Operation 7: Burn Tokens ─────────────────────────────────────

    function burnTokens(uint256 actorSeed, uint256 burnPercent) public {
        address actor = _getActor(actorSeed);
        uint256 tokenBalance = tokens.totalBalanceOf(actor, projectId);
        if (tokenBalance == 0) return;

        burnPercent = bound(burnPercent, 1, 100);
        uint256 burnCount = (tokenBalance * burnPercent) / 100;
        if (burnCount == 0) return;

        vm.prank(actor);
        try controller.burnTokensOf({holder: actor, projectId: projectId, tokenCount: burnCount, memo: "burn"}) {}
        catch {}

        callCount_burnTokens++;
    }

    // ─── Operation 8: Claim Credits as ERC20 ──────────────────────────

    function claimCredits(uint256 actorSeed, uint256 claimPercent) public {
        address actor = _getActor(actorSeed);
        uint256 creditBalance = tokens.creditBalanceOf(actor, projectId);
        if (creditBalance == 0) return;

        claimPercent = bound(claimPercent, 1, 100);
        uint256 claimCount = (creditBalance * claimPercent) / 100;
        if (claimCount == 0) return;

        vm.prank(actor);
        try controller.claimTokensFor({holder: actor, projectId: projectId, tokenCount: claimCount, beneficiary: actor})
        {} catch {}

        callCount_claimCredits++;
    }

    // ─── Operation 9: Advance Time ────────────────────────────────────

    function advanceTime(uint256 timeSeed) public {
        uint256 timeJump = bound(timeSeed, 1 hours, 90 days);
        vm.warp(block.timestamp + timeJump);
        callCount_advanceTime++;
    }

    // ─── Operation 10: Process Held Fees ──────────────────────────────

    function processHeldFees(uint256 count) public {
        count = bound(count, 1, 10);
        try terminal.processHeldFeesOf(projectId, JBConstants.NATIVE_TOKEN, count) {} catch {}
        callCount_processHeldFees++;
        _trackFeeProjectBalance();
    }

    receive() external payable {}
}
