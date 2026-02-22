// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {JBFees} from "../../../src/libraries/JBFees.sol";
import {JBFee} from "../../../src/structs/JBFee.sol";
import {IJBMultiTerminal} from "../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminalStore} from "../../../src/interfaces/IJBTerminalStore.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBTokens} from "../../../src/interfaces/IJBTokens.sol";
import {JBMultiTerminal} from "../../../src/JBMultiTerminal.sol";

/// @title Phase3Handler
/// @notice Stateful fuzzing handler with ghost variable tracking for strict invariant verification.
/// @dev 14 operations across 4 projects with 10 actors. Ghost variables track every fee flow,
///      enabling strict equality checks instead of the looser `>=` used in Phase 2.
contract Phase3Handler is Test {
    IJBMultiTerminal public terminal;
    IJBTerminalStore public store;
    IJBController public controller;
    IJBTokens public tokens;

    uint256 public constant PROJECT_FEE = 1;
    uint256 public projectId2;
    uint256 public projectId3;
    uint256 public projectId4;
    address public projectOwner;

    uint256 public constant FEE_PERCENT = 25; // 2.5% — matches JBMultiTerminal.FEE

    // =========================================================================
    // Actors
    // =========================================================================
    address[] public actors;
    uint256 public constant NUM_ACTORS = 10;

    // =========================================================================
    // Ghost Variables — strict accounting
    // =========================================================================

    // Per-project total inflows/outflows
    mapping(uint256 => uint256) public ghost_totalPaidIn;
    mapping(uint256 => uint256) public ghost_totalCashedOut;
    mapping(uint256 => uint256) public ghost_totalPaidOut;
    mapping(uint256 => uint256) public ghost_totalAllowanceUsed;
    mapping(uint256 => uint256) public ghost_totalAddedToBalance;

    // Fee tracking (key innovation for strict invariants)
    mapping(uint256 => uint256) public ghost_totalFeesDeducted;
    mapping(uint256 => uint256) public ghost_totalFeesSentToProject1;
    mapping(uint256 => uint256) public ghost_totalHeldFeeAmounts;
    mapping(uint256 => uint256) public ghost_totalReturnedFees;
    mapping(uint256 => uint256) public ghost_totalProcessedFees;

    // Per-actor tracking
    mapping(address => mapping(uint256 => uint256)) public ghost_actorContributed;
    mapping(address => mapping(uint256 => uint256)) public ghost_actorExtracted;

    // Token tracking
    mapping(uint256 => uint256) public ghost_totalReservesSent;

    // Global conservation
    uint256 public ghost_globalInflows;
    uint256 public ghost_globalOutflows;

    // Operation counters
    uint256 public callCount_pay2;
    uint256 public callCount_pay3;
    uint256 public callCount_cashOut2;
    uint256 public callCount_cashOut3;
    uint256 public callCount_sendPayouts2;
    uint256 public callCount_useAllowance2;
    uint256 public callCount_sendReserved2;
    uint256 public callCount_processHeldFees2;
    uint256 public callCount_addToBalanceReturn2;
    uint256 public callCount_addToBalanceNoReturn2;
    uint256 public callCount_burnTokens2;
    uint256 public callCount_burnTokens3;
    uint256 public callCount_claimCredits2;
    uint256 public callCount_advanceTime;

    constructor(
        IJBMultiTerminal _terminal,
        IJBTerminalStore _store,
        IJBController _controller,
        IJBTokens _tokens,
        uint256 _projectId2,
        uint256 _projectId3,
        uint256 _projectId4,
        address _projectOwner
    ) {
        terminal = _terminal;
        store = _store;
        controller = _controller;
        tokens = _tokens;
        projectId2 = _projectId2;
        projectId3 = _projectId3;
        projectId4 = _projectId4;
        projectOwner = _projectOwner;

        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = address(uint160(0x4000 + i));
            actors.push(actor);
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Compute the fee that would be deducted from `amount` (forward fee).
    function _feeFrom(uint256 amount) internal pure returns (uint256) {
        return JBFees.feeAmountFrom(amount, FEE_PERCENT);
    }

    // =========================================================================
    // 14 Operations
    // =========================================================================

    /// @notice Pay into project 2.
    function payProject2(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 5 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.pay{value: amount}(projectId2, JBConstants.NATIVE_TOKEN, amount, actor, 0, "", "") {
            ghost_totalPaidIn[projectId2] += amount;
            ghost_actorContributed[actor][projectId2] += amount;
            ghost_globalInflows += amount;
            callCount_pay2++;
        } catch {}
    }

    /// @notice Pay into project 3.
    function payProject3(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 5 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.pay{value: amount}(projectId3, JBConstants.NATIVE_TOKEN, amount, actor, 0, "", "") {
            ghost_totalPaidIn[projectId3] += amount;
            ghost_actorContributed[actor][projectId3] += amount;
            ghost_globalInflows += amount;
            callCount_pay3++;
        } catch {}
    }

    /// @notice Cash out tokens from project 2.
    function cashOutProject2(uint256 seed) external {
        address actor = _getActor(seed);
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectId2);
        if (actorBalance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, actorBalance);

        vm.prank(actor);
        try terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectId2,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: ""
        }) returns (uint256 reclaimAmount) {
            ghost_totalCashedOut[projectId2] += reclaimAmount;
            ghost_actorExtracted[actor][projectId2] += reclaimAmount;
            ghost_globalOutflows += reclaimAmount;
            // Cash out fee is deducted from reclaim when cashOutTaxRate < MAX
            uint256 feeAmount = _feeFrom(reclaimAmount);
            ghost_totalFeesDeducted[projectId2] += feeAmount;
            callCount_cashOut2++;
        } catch {}
    }

    /// @notice Cash out tokens from project 3.
    function cashOutProject3(uint256 seed) external {
        address actor = _getActor(seed);
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectId3);
        if (actorBalance == 0) return;

        uint256 cashOutAmount = bound(seed, 1, actorBalance);

        vm.prank(actor);
        try terminal.cashOutTokensOf({
            holder: actor,
            projectId: projectId3,
            cashOutCount: cashOutAmount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: ""
        }) returns (uint256 reclaimAmount) {
            ghost_totalCashedOut[projectId3] += reclaimAmount;
            ghost_actorExtracted[actor][projectId3] += reclaimAmount;
            ghost_globalOutflows += reclaimAmount;
            callCount_cashOut3++;
        } catch {}
    }

    /// @notice Send payouts from project 2.
    function sendPayoutsProject2(uint256 seed) external {
        uint256 balance = store.balanceOf(address(terminal), projectId2, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        uint256 amount = bound(seed, 1, balance);

        uint256 terminalBalBefore = address(terminal).balance;
        vm.prank(projectOwner);
        try terminal.sendPayoutsOf({
            projectId: projectId2,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        }) returns (uint256 amountPaidOut) {
            ghost_totalPaidOut[projectId2] += amountPaidOut;
            // Track actual ETH that left the terminal, not the gross recorded amount.
            // The fee stays in the terminal (paid to project #1 via internal _pay).
            uint256 actualOutflow = terminalBalBefore - address(terminal).balance;
            ghost_globalOutflows += actualOutflow;
            callCount_sendPayouts2++;
        } catch {}
    }

    /// @notice Use surplus allowance from project 2.
    function useAllowanceProject2(uint256 seed) external {
        uint256 balance = store.balanceOf(address(terminal), projectId2, JBConstants.NATIVE_TOKEN);
        if (balance == 0) return;

        uint256 amount = bound(seed, 1, balance > 3 ether ? 3 ether : balance);

        vm.prank(projectOwner);
        try terminal.useAllowanceOf({
            projectId: projectId2,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            beneficiary: payable(projectOwner),
            feeBeneficiary: payable(projectOwner),
            memo: ""
        }) returns (uint256 netAmountPaidOut) {
            ghost_totalAllowanceUsed[projectId2] += netAmountPaidOut;
            ghost_globalOutflows += netAmountPaidOut;
            callCount_useAllowance2++;
        } catch {}
    }

    /// @notice Send reserved tokens for project 2.
    function sendReservedTokens2(uint256 seed) external {
        seed; // suppress unused warning
        vm.prank(projectOwner);
        try controller.sendReservedTokensToSplitsOf(projectId2) returns (uint256 tokenCount) {
            ghost_totalReservesSent[projectId2] += tokenCount;
            callCount_sendReserved2++;
        } catch {}
    }

    /// @notice Process held fees for project 2.
    function processHeldFees2(uint256 seed) external {
        seed;

        // Advance time past the 28-day holding period to ensure fees are unlocked
        vm.warp(block.timestamp + 30 days);

        // Count available held fees
        JBFee[] memory fees = terminal.heldFeesOf(projectId2, JBConstants.NATIVE_TOKEN, 100);
        if (fees.length == 0) return;

        uint256 feeSum;
        for (uint256 i = 0; i < fees.length; i++) {
            feeSum += _feeFrom(fees[i].amount);
        }

        try terminal.processHeldFeesOf(projectId2, JBConstants.NATIVE_TOKEN, fees.length) {
            ghost_totalProcessedFees[projectId2] += feeSum;
            callCount_processHeldFees2++;
        } catch {}
    }

    /// @notice Add to balance with fee return.
    function addToBalanceReturnFees2(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 2 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        // Snapshot held fees before
        JBFee[] memory feesBefore = terminal.heldFeesOf(projectId2, JBConstants.NATIVE_TOKEN, 100);
        uint256 heldBefore;
        for (uint256 i = 0; i < feesBefore.length; i++) {
            heldBefore += feesBefore[i].amount;
        }

        vm.prank(actor);
        try terminal.addToBalanceOf{value: amount}(
            projectId2, JBConstants.NATIVE_TOKEN, amount, true, "", "" // shouldReturnHeldFees = true
        ) {
            ghost_totalAddedToBalance[projectId2] += amount;
            ghost_globalInflows += amount;

            // Track returned fees by measuring held fee change
            JBFee[] memory feesAfter = terminal.heldFeesOf(projectId2, JBConstants.NATIVE_TOKEN, 100);
            uint256 heldAfter;
            for (uint256 i = 0; i < feesAfter.length; i++) {
                heldAfter += feesAfter[i].amount;
            }
            if (heldBefore > heldAfter) {
                ghost_totalReturnedFees[projectId2] += (heldBefore - heldAfter);
            }
            callCount_addToBalanceReturn2++;
        } catch {}
    }

    /// @notice Add to balance without fee return.
    function addToBalanceNoReturn2(uint256 seed) external {
        uint256 amount = bound(seed, 0.001 ether, 2 ether);
        address actor = _getActor(seed);
        vm.deal(actor, amount);

        vm.prank(actor);
        try terminal.addToBalanceOf{value: amount}(
            projectId2, JBConstants.NATIVE_TOKEN, amount, false, "", "" // shouldReturnHeldFees = false
        ) {
            ghost_totalAddedToBalance[projectId2] += amount;
            ghost_globalInflows += amount;
            callCount_addToBalanceNoReturn2++;
        } catch {}
    }

    /// @notice Burn tokens for project 2.
    function burnTokens2(uint256 seed) external {
        address actor = _getActor(seed);
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectId2);
        if (actorBalance == 0) return;

        uint256 burnAmount = bound(seed, 1, actorBalance);

        vm.prank(actor);
        try controller.burnTokensOf({holder: actor, projectId: projectId2, tokenCount: burnAmount, memo: ""}) {
            callCount_burnTokens2++;
        } catch {}
    }

    /// @notice Burn tokens for project 3.
    function burnTokens3(uint256 seed) external {
        address actor = _getActor(seed);
        uint256 actorBalance = tokens.totalBalanceOf(actor, projectId3);
        if (actorBalance == 0) return;

        uint256 burnAmount = bound(seed, 1, actorBalance);

        vm.prank(actor);
        try controller.burnTokensOf({holder: actor, projectId: projectId3, tokenCount: burnAmount, memo: ""}) {
            callCount_burnTokens3++;
        } catch {}
    }

    /// @notice Claim credits as ERC20 for project 2.
    function claimCredits2(uint256 seed) external {
        address actor = _getActor(seed);

        // creditBalanceOf returns just the credit portion (not ERC20)
        uint256 creditBalance = tokens.creditBalanceOf(actor, projectId2);
        if (creditBalance == 0) return;

        uint256 claimAmount = bound(seed, 1, creditBalance);

        vm.prank(actor);
        try tokens.claimTokensFor({holder: actor, projectId: projectId2, count: claimAmount, beneficiary: actor}) {
            callCount_claimCredits2++;
        } catch {}
    }

    /// @notice Advance block time.
    function advanceTime(uint256 seed) external {
        uint256 delta = bound(seed, 1 hours, 30 days);
        vm.warp(block.timestamp + delta);
        callCount_advanceTime++;
    }

    // =========================================================================
    // View helpers for invariant checks
    // =========================================================================

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }
}
