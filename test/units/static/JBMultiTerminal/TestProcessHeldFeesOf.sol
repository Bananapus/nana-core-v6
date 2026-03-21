// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "../../../../src/interfaces/IJBFeeTerminal.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "../../../../src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBSplits} from "../../../../src/interfaces/IJBSplits.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "../../../../src/interfaces/IJBTokens.sol";
import {JBFees} from "../../../../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBFee} from "../../../../src/structs/JBFee.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/// @dev Harness that exposes internal held fee storage for direct manipulation in tests.
contract ForTest_JBMultiTerminal is JBMultiTerminal {
    constructor(
        IJBFeelessAddresses feelessAddresses,
        IJBPermissions permissions,
        IJBProjects projects,
        IJBSplits splits,
        IJBTerminalStore store,
        IJBTokens tokens,
        IPermit2 permit2,
        address trustedForwarder
    )
        JBMultiTerminal(feelessAddresses, permissions, projects, splits, store, tokens, permit2, trustedForwarder)
    {}

    function forTestAddHeldFee(uint256 projectId, address token, JBFee memory fee) external {
        _heldFeesOf[projectId][token].push(fee);
    }

    function forTestSetNextHeldFeeIndex(uint256 projectId, address token, uint256 index) external {
        _nextHeldFeeIndexOf[projectId][token] = index;
    }
}

contract TestProcessHeldFeesOf_Local is JBTest {
    // Target Contract (harness)
    ForTest_JBMultiTerminal public _terminal;

    // Mocks
    IJBPermissions public permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects public projects = IJBProjects(makeAddr("projects"));
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets public rulesets = IJBRulesets(makeAddr("rulesets"));
    IJBTokens public tokens = IJBTokens(makeAddr("tokens"));
    IJBSplits public splits = IJBSplits(makeAddr("splits"));
    IJBTerminalStore public store = IJBTerminalStore(makeAddr("store"));
    IJBFeelessAddresses public feelessAddresses = IJBFeelessAddresses(makeAddr("feeless"));
    IPermit2 public permit2 = IPermit2(makeAddr("permit2"));
    address trustedForwarder = makeAddr("forwarder");

    uint256 _feeProjectId = 1;
    uint256 _projectId = 2;
    address _mockToken = makeAddr("token");
    address _beneficiary = makeAddr("beneficiary");

    function _setAccountingContext(uint256 projectId, address token, uint8 decimals, uint32 currency) internal {
        // Mock the store to return this accounting context
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), projectId, token)),
            abi.encode(JBAccountingContext({token: token, decimals: decimals, currency: currency}))
        );
    }

    function setUp() public {
        // Constructor will call to find directory and rulesets from the terminal store
        mockExpect(address(store), abi.encodeCall(IJBTerminalStore.DIRECTORY, ()), abi.encode(address(directory)));
        mockExpect(address(store), abi.encodeCall(IJBTerminalStore.RULESETS, ()), abi.encode(address(rulesets)));

        _terminal = new ForTest_JBMultiTerminal(
            feelessAddresses, permissions, projects, splits, store, tokens, permit2, trustedForwarder
        );
    }

    function test_WhenHeldFeeUnlockTimestampGTBlocktimestamp() external {
        // it will not process the fee (fee remains held)

        // Add a held fee with unlockTimestamp in the future
        uint48 futureTimestamp = uint48(block.timestamp + 1000);
        _terminal.forTestAddHeldFee(
            _projectId, _mockToken, JBFee({amount: 100, beneficiary: _beneficiary, unlockTimestamp: futureTimestamp})
        );

        // Mock the directory call to find the fee terminal (project 1 is the fee beneficiary)
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, _mockToken)),
            abi.encode(address(_terminal))
        );

        // Call processHeldFeesOf - the fee should NOT be processed because it's still locked
        _terminal.processHeldFeesOf(_projectId, _mockToken, 1);

        // Verify the fee is still held
        JBFee[] memory remaining = _terminal.heldFeesOf(_projectId, _mockToken, 10);
        assertEq(remaining.length, 1, "fee should still be held");
        assertEq(remaining[0].amount, 100, "fee amount should be unchanged");
        assertEq(remaining[0].unlockTimestamp, futureTimestamp, "unlock timestamp should be unchanged");
    }

    modifier whenHeldFeeIsUnlocked() {
        _;
    }

    function test_GivenExecuteProcessFeeSucceeds() external whenHeldFeeIsUnlocked {
        // it will process the fee and emit ProcessFee

        // Add a held fee that is already unlocked
        uint48 pastTimestamp = uint48(block.timestamp - 1);
        uint256 heldAmount = 1000;
        _terminal.forTestAddHeldFee(
            _projectId,
            _mockToken,
            JBFee({amount: heldAmount, beneficiary: _beneficiary, unlockTimestamp: pastTimestamp})
        );

        // The fee amount that will be calculated from the held amount
        uint256 expectedFeeAmount = JBFees.feeAmountFrom({amountBeforeFee: heldAmount, feePercent: _terminal.FEE()});

        // Set up accounting context for the fee beneficiary project (project 1) so _pay can build the token amount.
        _setAccountingContext(_feeProjectId, _mockToken, 0, uint32(uint160(_mockToken)));

        // Mock the directory call to find the fee terminal - return _terminal itself so it uses internal _pay
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, _mockToken)),
            abi.encode(address(_terminal))
        );

        // Mock executeProcessFee: when the terminal calls itself, it will call recordPaymentFrom on the store.
        // Since executeProcessFee is external and calls pay on the feeTerminal (which is _terminal itself),
        // we need to mock the internal pay path: recordPaymentFrom on the store.
        vm.mockCall(
            address(store),
            abi.encodeWithSelector(IJBTerminalStore.recordPaymentFrom.selector),
            abi.encode(
                JBRuleset({
                    cycleNumber: 1,
                    id: 1,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(0),
                new JBPayHookSpecification[](0)
            )
        );

        // Expect ProcessFee event
        vm.expectEmit();
        emit IJBFeeTerminal.ProcessFee({
            projectId: _projectId,
            token: _mockToken,
            amount: expectedFeeAmount,
            wasHeld: true,
            beneficiary: _beneficiary,
            caller: address(this)
        });

        _terminal.processHeldFeesOf(_projectId, _mockToken, 1);

        // Verify held fees are cleaned up
        JBFee[] memory remaining = _terminal.heldFeesOf(_projectId, _mockToken, 10);
        assertEq(remaining.length, 0, "held fees should be empty after processing");
    }

    function test_GivenExecuteProcessFeeFails() external whenHeldFeeIsUnlocked {
        // it will readd balance and emit FeeReverted

        // Add a held fee that is already unlocked
        uint48 pastTimestamp = uint48(block.timestamp - 1);
        uint256 heldAmount = 1000;
        _terminal.forTestAddHeldFee(
            _projectId,
            _mockToken,
            JBFee({amount: heldAmount, beneficiary: _beneficiary, unlockTimestamp: pastTimestamp})
        );

        // The fee amount that will be calculated from the held amount
        uint256 expectedFeeAmount = JBFees.feeAmountFrom({amountBeforeFee: heldAmount, feePercent: _terminal.FEE()});

        // Mock the directory call to find the fee terminal - return address(0) which will cause
        // executeProcessFee to revert with FeeTerminalNotFound
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, _mockToken)), abi.encode(address(0))
        );

        // Mock the recordAddedBalanceFor call that happens on fee revert (balance returned to project)
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_projectId, _mockToken, expectedFeeAmount)),
            abi.encode()
        );

        // Expect FeeReverted event
        vm.expectEmit(true, true, true, false);
        emit IJBFeeTerminal.FeeReverted({
            projectId: _projectId,
            token: _mockToken,
            feeProjectId: 1,
            amount: expectedFeeAmount,
            reason: "",
            caller: address(this)
        });

        _terminal.processHeldFeesOf(_projectId, _mockToken, 1);

        // Verify held fees are cleaned up (entry was deleted even though fee processing failed)
        JBFee[] memory remaining = _terminal.heldFeesOf(_projectId, _mockToken, 10);
        assertEq(remaining.length, 0, "held fees should be empty after failed processing");
    }
}
