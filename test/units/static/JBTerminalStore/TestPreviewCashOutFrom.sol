// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBTerminalStore} from "../../../../src/JBTerminalStore.sol";
import {IJBCashOutHook} from "../../../../src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "../../../../src/interfaces/IJBFundAccessLimits.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../../../../src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {IJBToken} from "../../../../src/interfaces/IJBToken.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBBeforeCashOutRecordedContext} from "../../../../src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../../../../src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBTerminalStoreSetup} from "./JBTerminalStoreSetup.sol";

contract TestPreviewCashOutFor_Local is JBTerminalStoreSetup {
    uint64 _projectId = 1;
    uint256 _decimals = 18;
    uint256 _balance = 10e18;
    uint256 _totalSupply = 20e18;

    // Mocks
    IJBTerminal _terminal1 = IJBTerminal(makeAddr("terminal1"));
    IJBTerminal _terminal2 = IJBTerminal(makeAddr("terminal2"));
    IJBToken _token = IJBToken(makeAddr("token"));
    IJBController _controller = IJBController(makeAddr("controller"));
    IJBFundAccessLimits _accessLimits = IJBFundAccessLimits(makeAddr("funds"));
    IJBRulesetDataHook _dataHook = IJBRulesetDataHook(makeAddr("dataHook"));
    IJBCashOutHook _cashOutHook = IJBCashOutHook(makeAddr("cashOutHook"));

    uint32 _currency = uint32(uint160(address(_token)));

    function setUp() public {
        super.terminalStoreSetup();

        // Register accounting context so the store can look up decimals/currency for the token.
        // address(this) acts as the terminal for both preview and record calls.
        JBAccountingContext[] memory _ctxs = new JBAccountingContext[](1);
        _ctxs[0] = JBAccountingContext({token: address(_token), decimals: 18, currency: _currency});
        _store.recordAccountingContextOf(_projectId, _ctxs);
    }

    function _setBalance(address terminal, uint256 balance) internal {
        bytes32 balanceOfSlot = keccak256(abi.encode(terminal, uint256(0)));
        bytes32 projectSlot = keccak256(abi.encode(_projectId, uint256(balanceOfSlot)));
        bytes32 slot = keccak256(abi.encode(address(_token), uint256(projectSlot)));
        vm.store(address(_store), slot, bytes32(balance));
    }

    function _mockUseTotalSurplus() internal {
        IJBTerminal[] memory _terminals = new IJBTerminal[](2);
        _terminals[0] = _terminal1;
        _terminals[1] = _terminal2;

        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        mockExpect(
            address(_terminal1),
            abi.encodeCall(IJBTerminal.currentSurplusOf, (_projectId, new address[](0), _decimals, _currency)),
            abi.encode(1e18)
        );
        mockExpect(
            address(_terminal2),
            abi.encodeCall(IJBTerminal.currentSurplusOf, (_projectId, new address[](0), _decimals, _currency)),
            abi.encode(2e18)
        );
    }

    function test_MatchesRecordCashOutFor() external {
        // Setup: set balance for address(this) (acting as terminal for both preview and record)
        _setBalance(address(this), _balance);

        _mockUseTotalSurplus();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        uint256 _cashOutCount = 10e18;

        JBAccountingContext memory _accountingContext =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(_token), decimals: uint8(_decimals), currency: _currency});

        // Mock for preview call
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_totalSupply)
        );

        (, uint256 previewReclaimAmount, uint256 previewTaxRate, JBCashOutHookSpecification[] memory previewSpecs) = _store.previewCashOutFrom({
            terminal: address(this),
            holder: address(this),
            projectId: _projectId,
            cashOutCount: _cashOutCount,
            tokenToReclaim: _accountingContext.token,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        // Re-mock for record call (same mocks, fresh expectations)
        _mockUseTotalSurplus();
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_totalSupply)
        );

        (, uint256 recordReclaimAmount, uint256 recordTaxRate, JBCashOutHookSpecification[] memory recordSpecs) = _store.recordCashOutFor({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: _cashOutCount,
            tokenToReclaim: _accountingContext.token,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        assertEq(previewReclaimAmount, recordReclaimAmount);
        assertEq(previewTaxRate, recordTaxRate);
        assertEq(previewSpecs.length, recordSpecs.length);
    }

    function test_DoesNotModifyState() external {
        _setBalance(address(this), _balance);
        _mockUseTotalSurplus();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        JBAccountingContext memory _accountingContext =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(_token), decimals: uint8(_decimals), currency: _currency});

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_totalSupply)
        );

        uint256 balanceBefore = _store.balanceOf(address(this), _projectId, address(_token));

        _store.previewCashOutFrom({
            terminal: address(this),
            holder: address(this),
            projectId: _projectId,
            cashOutCount: 5e18,
            tokenToReclaim: _accountingContext.token,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        uint256 balanceAfter = _store.balanceOf(address(this), _projectId, address(_token));
        assertEq(balanceBefore, balanceAfter);
    }

    function test_RevertsWhenCashOutCountExceedsTotalSupply() external {
        _setBalance(address(this), _balance);
        _mockUseTotalSurplus();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        JBAccountingContext memory _accountingContext =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(_token), decimals: uint8(_decimals), currency: _currency});

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_totalSupply)
        );

        uint256 _excessiveCashOutCount = _totalSupply + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBTerminalStore.JBTerminalStore_InsufficientTokens.selector, _excessiveCashOutCount, _totalSupply
            )
        );
        _store.previewCashOutFrom({
            terminal: address(this),
            holder: address(this),
            projectId: _projectId,
            cashOutCount: _excessiveCashOutCount,
            tokenToReclaim: _accountingContext.token,
            beneficiaryIsFeeless: false,
            metadata: ""
        });
    }

    function test_ReturnsZeroWhenSurplusIsZero() external {
        // No balance set, no surplus

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        JBAccountingContext memory _accountingContext =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(_token), decimals: uint8(_decimals), currency: _currency});

        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal1;

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));
        mockExpect(
            address(_terminal1),
            abi.encodeCall(IJBTerminal.currentSurplusOf, (_projectId, new address[](0), _decimals, _currency)),
            abi.encode(0)
        );
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_totalSupply)
        );

        (, uint256 reclaimAmount,,) = _store.previewCashOutFrom({
            terminal: address(this),
            holder: address(this),
            projectId: _projectId,
            cashOutCount: 5e18,
            tokenToReclaim: _accountingContext.token,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        assertEq(reclaimAmount, 0);
    }

    function test_WithDataHookAndZeroAmountNoopSpec() external {
        _setBalance(address(this), _balance);
        _mockUseTotalSurplus();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: true,
            dataHook: address(_dataHook),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        JBAccountingContext memory _accountingContext =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(_token), decimals: uint8(_decimals), currency: _currency});

        JBBeforeCashOutRecordedContext memory _context = JBBeforeCashOutRecordedContext({
            terminal: address(this),
            holder: address(this),
            projectId: _projectId,
            rulesetId: uint48(block.timestamp),
            cashOutCount: 10e18,
            totalSupply: _totalSupply,
            surplus: JBTokenAmount({
                token: _accountingContext.token,
                value: 3e18,
                decimals: _accountingContext.decimals,
                currency: _accountingContext.currency
            }),
            useTotalSurplus: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        JBCashOutHookSpecification[] memory _spec = new JBCashOutHookSpecification[](1);
        _spec[0] = JBCashOutHookSpecification({hook: _cashOutHook, noop: true, amount: 0, metadata: "info"});

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_totalSupply)
        );
        mockExpect(
            address(_dataHook),
            abi.encodeCall(IJBRulesetDataHook.beforeCashOutRecordedWith, (_context)),
            abi.encode(0, 10e18, _totalSupply, _spec)
        );

        (, uint256 reclaimAmount, uint256 cashOutTaxRate, JBCashOutHookSpecification[] memory hookSpecifications) = _store.previewCashOutFrom({
            terminal: address(this),
            holder: address(this),
            projectId: _projectId,
            cashOutCount: 10e18,
            tokenToReclaim: _accountingContext.token,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        assertEq(reclaimAmount, mulDiv(3e18, 10e18, _totalSupply));
        assertEq(cashOutTaxRate, 0);
        assertEq(hookSpecifications.length, 1);
        assertEq(hookSpecifications[0].amount, 0);
        assertEq(hookSpecifications[0].noop, true);
        assertEq(hookSpecifications[0].metadata, bytes("info"));
    }
}
