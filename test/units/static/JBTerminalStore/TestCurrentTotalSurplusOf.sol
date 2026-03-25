// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "../../../../src/interfaces/IJBFundAccessLimits.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../../../src/structs/JBCurrencyAmount.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBTerminalStoreSetup} from "./JBTerminalStoreSetup.sol";

contract TestCurrentTotalSurplusOf_Local is JBTerminalStoreSetup {
    uint256 _projectId = 1;
    uint256 _decimals = 18;

    // Mocks
    IJBTerminal _terminal1 = IJBTerminal(makeAddr("terminal1"));
    IJBTerminal _terminal2 = IJBTerminal(makeAddr("terminal2"));
    address _token = makeAddr("token");
    IJBController _controller = IJBController(makeAddr("controller"));
    IJBFundAccessLimits _accessLimits = IJBFundAccessLimits(makeAddr("funds"));

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 _currency = uint32(uint160(_token));

    function setUp() public {
        super.terminalStoreSetup();
    }

    /// @notice Helper to set balance for a terminal/project/token via vm.store.
    function _setBalance(address terminal, uint256 projectId, address token, uint256 balance) internal {
        bytes32 balanceOfSlot = keccak256(abi.encode(terminal, uint256(0)));
        bytes32 projectSlot = keccak256(abi.encode(projectId, uint256(balanceOfSlot)));
        bytes32 slot = keccak256(abi.encode(token, uint256(projectSlot)));
        vm.store(address(_store), slot, bytes32(balance));
    }

    /// @notice Helper to register an accounting context with the store (pranks as the terminal).
    function _registerContext(address terminal, JBAccountingContext memory ctx) internal {
        JBAccountingContext[] memory ctxs = new JBAccountingContext[](1);
        ctxs[0] = ctx;
        vm.prank(terminal);
        _store.recordAccountingContextOf(_projectId, ctxs);
    }

    function test_WhenTerminalsAreConfiguredInJBDirectory() external {
        // it will return the cumulative surplus

        // Set up terminals in directory
        IJBTerminal[] memory _terminals = new IJBTerminal[](2);
        _terminals[0] = _terminal1;
        _terminals[1] = _terminal2;

        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        // Set up accounting contexts for each terminal
        JBAccountingContext memory ctx = JBAccountingContext({token: _token, decimals: 18, currency: _currency});
        _registerContext(address(_terminal1), ctx);
        _registerContext(address(_terminal2), ctx);

        // Set balances: terminal1 = 1e18, terminal2 = 2e18
        _setBalance(address(_terminal1), _projectId, _token, 1e18);
        _setBalance(address(_terminal2), _projectId, _token, 2e18);

        // Mock ruleset
        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        // Mock controller and fund access limits (zero payout limits = all balance is surplus)
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller), abi.encodeCall(IJBController.FUND_ACCESS_LIMITS, ()), abi.encode(_accessLimits)
        );

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        // Mock payoutLimitsOf for terminal1
        mockExpect(
            address(_accessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.payoutLimitsOf, (_projectId, block.timestamp, address(_terminal1), _token)
            ),
            abi.encode(_emptyLimits)
        );
        // Mock payoutLimitsOf for terminal2
        mockExpect(
            address(_accessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.payoutLimitsOf, (_projectId, block.timestamp, address(_terminal2), _token)
            ),
            abi.encode(_emptyLimits)
        );

        uint256 sum = _store.currentTotalSurplusOf(_projectId, _decimals, _currency);
        assertEq(3e18, sum);
    }

    function test_WhenTerminalsAreNotConfiguredInJBDirectory() external {
        // it will return zero

        IJBTerminal[] memory _terminals = new IJBTerminal[](0);

        // mock call to JBDirectory terminalsOf
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        // Mock ruleset (needed by currentSurplusOf)
        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        uint256 sum = _store.currentTotalSurplusOf(_projectId, _decimals, _currency);
        assertEq(0, sum);
    }
}
