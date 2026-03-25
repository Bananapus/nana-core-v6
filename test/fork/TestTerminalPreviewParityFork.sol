// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestTerminalPreviewParity_Local} from "../TestTerminalPreviewParity.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {IJBCashOutTerminal} from "../../src/interfaces/IJBCashOutTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBCashOutHookSpecification} from "../../src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";

contract TestTerminalPreviewParityFork is TestTerminalPreviewParity_Local {
    uint256 internal constant FORK_BLOCK = 22_000_000;

    function setUp() public override {
        vm.createSelectFork("ethereum", FORK_BLOCK);
        super.setUp();
    }

    function testForkPreviewPayForMatchesPay() external {
        _launchFeeProject();
        uint256 projectId = _launchProject(2500, 10_000);

        (
            JBRuleset memory ruleset,
            uint256 previewBeneficiaryTokenCount,
            uint256 previewReservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        ) = _terminal.previewPayFor(projectId, JBConstants.NATIVE_TOKEN, 1 ether, _beneficiary, "");

        assertEq(hookSpecifications.length, 0);

        uint256 balanceBefore = jbTokens().totalBalanceOf(_beneficiary, projectId);
        uint256 reservedBefore = _controller.pendingReservedTokenBalanceOf(projectId);

        address payer = makeAddr("forkPayer");
        vm.deal(payer, 1 ether);

        vm.expectEmit();
        emit IJBTerminal.Pay(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            payer,
            _beneficiary,
            1 ether,
            previewBeneficiaryTokenCount,
            "",
            "",
            payer
        );

        vm.prank(payer);
        uint256 beneficiaryTokenCount =
            _terminal.pay{value: 1 ether}(projectId, JBConstants.NATIVE_TOKEN, 1 ether, _beneficiary, 0, "", "");

        assertEq(beneficiaryTokenCount, previewBeneficiaryTokenCount);
        assertEq(jbTokens().totalBalanceOf(_beneficiary, projectId) - balanceBefore, previewBeneficiaryTokenCount);
        assertEq(_controller.pendingReservedTokenBalanceOf(projectId) - reservedBefore, previewReservedTokenCount);
    }

    function testForkPreviewCashOutFromMatchesCashOut() external {
        _launchFeeProject();
        uint256 projectId = _launchProject(0, 5000);

        vm.prank(_projectOwner);
        jbFeelessAddresses().setFeelessAddress(_beneficiary, true);

        vm.deal(_beneficiary, 1 ether);
        vm.prank(_beneficiary);
        uint256 minted =
            _terminal.pay{value: 1 ether}(projectId, JBConstants.NATIVE_TOKEN, 1 ether, _beneficiary, 0, "", "");

        uint256 cashOutCount = minted / 2;

        (
            JBRuleset memory ruleset,
            uint256 previewReclaimAmount,
            uint256 previewCashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) = _terminal.previewCashOutFrom(
            _beneficiary, projectId, cashOutCount, JBConstants.NATIVE_TOKEN, payable(_beneficiary), ""
        );

        assertEq(hookSpecifications.length, 0);

        vm.expectEmit();
        emit IJBCashOutTerminal.CashOutTokens(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            _beneficiary,
            _beneficiary,
            cashOutCount,
            previewCashOutTaxRate,
            previewReclaimAmount,
            "",
            _beneficiary
        );

        vm.prank(_beneficiary);
        uint256 reclaimAmount = _terminal.cashOutTokensOf(
            _beneficiary, projectId, cashOutCount, JBConstants.NATIVE_TOKEN, 0, payable(_beneficiary), ""
        );

        assertEq(reclaimAmount, previewReclaimAmount);
    }
}
