// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "../../../../src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

contract TestPreviewPayFor_Local is JBMultiTerminalSetup {
    uint256 _projectId = 1;
    uint256 _amount = 1e18;
    address _token = JBConstants.NATIVE_TOKEN;
    address _beneficiary = makeAddr("beneficiary");
    address _payer = makeAddr("payer");
    IJBController _controller = IJBController(makeAddr("controller"));

    function setUp() public {
        super.multiTerminalSetup();
    }

    function _setAccountingContext(address token, uint8 decimals, uint32 currency) internal {
        // Mock the store to return this accounting context
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, token)),
            abi.encode(JBAccountingContext({token: token, decimals: decimals, currency: currency}))
        );
    }

    function test_RevertsWhenTokenIsNotAccepted() external {
        // Mock accountingContextOf to return empty context (token not accepted)
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, _token)),
            abi.encode(JBAccountingContext({token: address(0), decimals: 0, currency: 0}))
        );

        vm.prank(_payer);
        vm.expectRevert(abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_TokenNotAccepted.selector, _token));
        JBMultiTerminal(address(_terminal)).previewPayFor(_projectId, _token, _amount, _beneficiary, "");
    }

    function test_ReturnsRulesetMintSplitAndHookSpecifications() external {
        // forge-lint: disable-next-line(unsafe-typecast)
        _setAccountingContext(_token, 18, uint32(uint160(_token)));

        _mockPreviewPayFrom();

        vm.prank(_payer);
        (
            JBRuleset memory previewRuleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory previewSpecs
        ) = JBMultiTerminal(address(_terminal)).previewPayFor(_projectId, _token, _amount, _beneficiary, "");

        assertEq(previewRuleset.id, 1);
        assertEq(beneficiaryTokenCount, 750);
        assertEq(reservedTokenCount, 250);
        assertEq(previewSpecs.length, 1);
        assertEq(previewSpecs[0].amount, 123);
        assertEq(previewSpecs[0].metadata, hex"1234");
    }

    function _mockPreviewPayFrom() internal {
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        specs[0] =
            JBPayHookSpecification({hook: IJBPayHook(makeAddr("hook")), noop: false, amount: 123, metadata: hex"1234"});

        JBTokenAmount memory tokenAmount =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBTokenAmount({token: _token, decimals: 18, currency: uint32(uint160(_token)), value: _amount});

        mockExpect(
            address(store),
            abi.encodeWithSelector(
                bytes4(0xdb6d7e03), address(_terminal), _payer, tokenAmount, _projectId, _beneficiary, bytes("")
            ),
            abi.encode(ruleset, 1000, specs)
        );

        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.controllerOf, (_projectId)),
            abi.encode(address(_controller))
        );

        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.previewMintOf, (_projectId, 1000, true)),
            abi.encode(750, 250)
        );
    }
}
