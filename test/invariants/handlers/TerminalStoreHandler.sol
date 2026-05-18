// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {Test} from "forge-std/Test.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminalStore} from "../../../src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "../../../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";

/// @notice Handler contract for JBTerminalStore invariant testing.
/// @dev Wraps terminal operations and tracks ghost variables for conservation checks.
contract TerminalStoreHandler is Test {
    IJBMultiTerminal public terminal;
    IJBMultiTerminal public terminal2;
    IJBTerminalStore public store;
    IJBController public controller;
    IJBTokens public tokens;

    uint256 public projectId;
    address public projectOwner;
    uint256[] public projectIds;

    // Ghost variables for fund tracking
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalPaidIn;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalCashedOut;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalPaidOut;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalAddedToBalance;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalMigrated;

    // Track actors
    address[] public actors;
    mapping(address => bool) public isActor;
    uint256 public constant NUM_ACTORS = 5;

    constructor(
        IJBMultiTerminal _terminal,
        IJBMultiTerminal _terminal2,
        IJBTerminalStore _store,
        IJBController _controller,
        IJBTokens _tokens,
        uint256[] memory _projectIds,
        address _projectOwner
    ) {
        terminal = _terminal;
        terminal2 = _terminal2;
        store = _store;
        controller = _controller;
        tokens = _tokens;
        projectId = _projectIds[0];
        projectOwner = _projectOwner;

        for (uint256 i; i < _projectIds.length;) {
            projectIds.push(_projectIds[i]);
            unchecked {
                ++i;
            }
        }

        // Create actor addresses
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);
            isActor[actor] = true;
        }
    }

    /// @notice Selects an actor based on a seed.
    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Selects one of the tracked projects based on a seed.
    function _getProject(uint256 seed) internal view returns (uint256) {
        return projectIds[seed % projectIds.length];
    }

    /// @notice Selects one of the two terminals in this invariant campaign.
    function _getTerminal(uint256 seed) internal view returns (IJBMultiTerminal) {
        return seed % 2 == 0 ? terminal : terminal2;
    }

    /// @notice Selects a source and destination terminal for a migration.
    function _getTerminalPair(uint256 seed)
        internal
        view
        returns (IJBMultiTerminal source, IJBMultiTerminal destination)
    {
        source = _getTerminal(seed);
        destination = source == terminal ? terminal2 : terminal;
    }

    /// @notice Add to project balance without minting tokens.
    function addToBalance(uint256 projectSeed, uint256 amount) public {
        amount = bound(amount, 0.01 ether, 50 ether);
        uint256 selectedProjectId = _getProject(projectSeed);
        IJBMultiTerminal selectedTerminal = _getTerminal(projectSeed);

        vm.deal(address(this), amount);
        selectedTerminal.addToBalanceOf{value: amount}({
            projectId: selectedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        ghost_totalAddedToBalance += amount;
    }

    /// @notice Cash out tokens for native tokens.
    function cashOutTokens(uint256 actorSeed, uint256 projectSeed, uint256 cashOutPercent) public {
        address actor = _getActor(actorSeed);
        uint256 selectedProjectId = _getProject(projectSeed);
        IJBMultiTerminal selectedTerminal = _getTerminal(cashOutPercent);
        uint256 tokenBalance = tokens.totalBalanceOf({holder: actor, projectId: selectedProjectId});
        if (tokenBalance == 0) return;

        cashOutPercent = bound(cashOutPercent, 1, 100);
        uint256 cashOutCount = (tokenBalance * cashOutPercent) / 100;
        if (cashOutCount == 0) return;

        vm.prank(actor);
        uint256 reclaimAmount = selectedTerminal.cashOutTokensOf({
            holder: actor,
            projectId: selectedProjectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(actor),
            metadata: new bytes(0),
            referralProjectId: 0
        });

        ghost_totalCashedOut += reclaimAmount;
    }

    /// @notice Migrate a project's native balance between the two tracked terminals.
    /// @dev Migration is deliberately excluded from the in/out ghost totals because it should only move value inside
    ///      the tracked terminal set. The invariant records it separately so corpus runs show that migration was hit.
    function migrateBalance(uint256 projectSeed, uint256 terminalSeed) public {
        (IJBMultiTerminal source, IJBMultiTerminal destination) = _getTerminalPair(terminalSeed);
        uint256 selectedProjectId = _getProject(projectSeed);
        uint256 balance =
            store.balanceOf({terminal: address(source), projectId: selectedProjectId, token: JBConstants.NATIVE_TOKEN});

        // A zero-balance migration cannot move funds or exercise the fee path, so keep the corpus focused on live
        // conservation moves.
        if (balance == 0) return;

        vm.prank(projectOwner);
        try source.migrateBalanceOf({
            projectId: selectedProjectId, token: JBConstants.NATIVE_TOKEN, to: destination
        }) returns (
            uint256 migratedBalance
        ) {
            ghost_totalMigrated += migratedBalance;
        } catch {
            // The invariant is about conservation across successful operations. Reverts can still happen if a future
            // corpus mutates permissions or terminal compatibility; they should not poison the sequence.
        }
    }

    /// @notice Pay the project with native tokens.
    function payProject(uint256 actorSeed, uint256 projectSeed, uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);
        address actor = _getActor(actorSeed);
        uint256 selectedProjectId = _getProject(projectSeed);
        IJBMultiTerminal selectedTerminal = _getTerminal(actorSeed + projectSeed);

        vm.deal(actor, amount);

        vm.prank(actor);
        selectedTerminal.pay{value: amount}({
            projectId: selectedProjectId,
            amount: amount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        ghost_totalPaidIn += amount;
    }

    /// @notice Send payouts from the project.
    function sendPayouts(uint256 projectSeed, uint256 amount) public {
        uint256 selectedProjectId = _getProject(projectSeed);
        IJBMultiTerminal selectedTerminal = _getTerminal(amount);
        uint256 balance = store.balanceOf({
            terminal: address(selectedTerminal), projectId: selectedProjectId, token: JBConstants.NATIVE_TOKEN
        });
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(projectOwner);
        try selectedTerminal.sendPayoutsOf({
            projectId: selectedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        }) returns (
            uint256 amountPaidOut
        ) {
            ghost_totalPaidOut += amountPaidOut;
        } catch {
            // Payout may fail if there's no payout limit configured
        }
    }

    receive() external payable {}
}
