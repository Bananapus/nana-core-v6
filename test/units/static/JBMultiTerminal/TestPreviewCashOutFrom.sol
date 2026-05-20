// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBCashOutHook} from "../../../../src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../../../../src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

contract TestPreviewCashOutFrom_Local is JBMultiTerminalSetup {
    uint256 _projectId = 1;
    uint256 _cashOutCount = 1e18;
    address _holder = makeAddr("holder");
    address payable _beneficiary = payable(makeAddr("beneficiary"));
    address _token = JBConstants.NATIVE_TOKEN;

    function setUp() public {
        super.multiTerminalSetup();
    }

    function _acceptToken(address token, uint8 decimals, uint32 currency) internal {
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(0)));
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(this))
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: token, decimals: decimals, currency: currency});

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, contexts)), ""
        );

        vm.prank(address(this));
        _terminal.addAccountingContextsFor(_projectId, contexts);

        // Mock accountingContextOf for subsequent reads (not all code paths call it, so use mockCall only)
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, token)),
            abi.encode(contexts[0])
        );
    }

    function test_RevertsWhenTokenIsNotAccepted() external {
        // previewCashOutFrom now delegates directly to the store without a token acceptance check,
        // so it reverts during store computation (e.g. unmocked external call) rather than with TokenNotAccepted.
        vm.expectRevert();
        JBMultiTerminal(address(_terminal))
            .previewCashOutFrom(_holder, _projectId, _cashOutCount, _token, _beneficiary, "");
    }

    function test_ReturnsRulesetAndCashOutPreviewValues() external {
        // forge-lint: disable-next-line(unsafe-typecast)
        _acceptToken(_token, 18, uint32(uint160(_token)));

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

        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](1);
        specs[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(makeAddr("hook")), noop: false, amount: 321, metadata: hex"5678"
        });

        JBAccountingContext memory accountingContext =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: _token, decimals: 18, currency: uint32(uint160(_token))});
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = accountingContext;

        mockExpect(
            address(feelessAddresses),
            feelessCalldata(_beneficiary, _projectId, address(this)),
            abi.encode(true)
        );

        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.previewCashOutFrom,
                (address(_terminal), _holder, _projectId, _cashOutCount, accountingContext.token, true, bytes(""))
            ),
            abi.encode(ruleset, 999, 1234, specs)
        );

        (
            JBRuleset memory previewRuleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory previewSpecs
        ) = JBMultiTerminal(address(_terminal))
            .previewCashOutFrom(_holder, _projectId, _cashOutCount, _token, _beneficiary, "");

        assertEq(previewRuleset.id, ruleset.id);
        assertEq(reclaimAmount, 999);
        assertEq(cashOutTaxRate, 1234);
        assertEq(previewSpecs.length, 1);
        assertEq(address(previewSpecs[0].hook), address(specs[0].hook));
        assertEq(previewSpecs[0].amount, specs[0].amount);
        assertEq(previewSpecs[0].metadata, specs[0].metadata);
    }
}
