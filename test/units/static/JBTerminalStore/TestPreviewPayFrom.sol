// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBTerminalStore} from "../../../../src/JBTerminalStore.sol";
import {IJBPayHook} from "../../../../src/interfaces/IJBPayHook.sol";
import {IJBPrices} from "../../../../src/interfaces/IJBPrices.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../../../../src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBToken} from "../../../../src/interfaces/IJBToken.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBBeforePayRecordedContext} from "../../../../src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBTerminalStoreSetup} from "./JBTerminalStoreSetup.sol";

contract TestPreviewPayFrom_Local is JBTerminalStoreSetup {
    using JBRulesetMetadataResolver for JBRuleset;

    uint64 _projectId = 1;
    uint256 _defaultValue = 1e18;
    uint8 _defaultDecimals = 18;

    // Mocks
    IJBToken _token = IJBToken(makeAddr("token"));
    IJBRulesetDataHook _dataHook = IJBRulesetDataHook(makeAddr("dataHook"));
    IJBPayHook _payHook = IJBPayHook(makeAddr("payHook"));
    address _terminal = makeAddr("terminal");

    uint32 _currency = uint32(uint160(address(_token)));
    uint32 _nativeCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));

    function setUp() public {
        super.terminalStoreSetup();
    }

    function test_WhenCurrentRulesetCycleNumberIsZero() external {
        // it will revert INVALID_RULESET

        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: 0,
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

        vm.expectRevert(abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_RulesetNotFound.selector, _projectId));
        _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });
    }

    function test_WhenCurrentRulesetPausePayEqTrue() external {
        // it will revert RULESET_PAYMENT_PAUSED

        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: true,
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
            scopeCashOutsToLocalBalances: false,
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

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        vm.expectPartialRevert(JBTerminalStore.JBTerminalStore_RulesetPaymentPaused.selector);
        _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });
    }

    function test_MatchesRecordPaymentFrom_NoDataHook() external {
        // it returns the same tokenCount as recordPaymentFrom for a simple payment without a data hook

        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(address(_token))),
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
            scopeCashOutsToLocalBalances: false,
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

        // Mock for preview call
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        (, uint256 previewTokenCount, JBPayHookSpecification[] memory previewSpecs) = _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });

        // Mock for record call
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        (, uint256 recordTokenCount, JBPayHookSpecification[] memory recordSpecs) = _store.recordPaymentFrom({
            payer: address(this), amount: _tokenAmount, projectId: _projectId, beneficiary: address(this), metadata: ""
        });

        assertEq(previewTokenCount, recordTokenCount);
        assertEq(previewSpecs.length, recordSpecs.length);
    }

    function test_MatchesRecordPaymentFrom_WithDataHook() external {
        // it returns the same tokenCount and hook specs as recordPaymentFrom with a data hook

        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(address(_token))),
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
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

        JBPayHookSpecification[] memory _spec = new JBPayHookSpecification[](1);
        _spec[0] = JBPayHookSpecification({hook: _payHook, noop: false, amount: _defaultValue / 2, metadata: ""});

        // The data hook context uses the explicit terminal parameter for preview / msg.sender for record.
        JBBeforePayRecordedContext memory _context = JBBeforePayRecordedContext({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            rulesetId: uint48(block.timestamp),
            beneficiary: address(this),
            weight: _returnedRuleset.weight,
            reservedPercent: _returnedRuleset.reservedPercent(),
            metadata: ""
        });

        // Mock for preview call
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(
            address(_dataHook),
            abi.encodeCall(IJBRulesetDataHook.beforePayRecordedWith, (_context)),
            abi.encode(1e18 / 2, _spec)
        );

        (, uint256 previewTokenCount, JBPayHookSpecification[] memory previewSpecs) = _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });

        // Mock for record call — recordPaymentFrom uses msg.sender as terminal, so prank _terminal.
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(
            address(_dataHook),
            abi.encodeCall(IJBRulesetDataHook.beforePayRecordedWith, (_context)),
            abi.encode(1e18 / 2, _spec)
        );

        vm.prank(_terminal);
        (, uint256 recordTokenCount, JBPayHookSpecification[] memory recordSpecs) = _store.recordPaymentFrom({
            payer: address(this), amount: _tokenAmount, projectId: _projectId, beneficiary: address(this), metadata: ""
        });

        assertEq(previewTokenCount, recordTokenCount);
        assertEq(previewSpecs.length, recordSpecs.length);
        assertEq(previewSpecs[0].amount, recordSpecs[0].amount);
    }

    function test_DoesNotModifyState() external {
        // it does not change balanceOf

        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(address(_token))),
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
            scopeCashOutsToLocalBalances: false,
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

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        uint256 balanceBefore = _store.balanceOf(_terminal, _projectId, address(_token));

        _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });

        uint256 balanceAfter = _store.balanceOf(_terminal, _projectId, address(_token));

        assertEq(balanceBefore, balanceAfter);
    }

    function test_WithDifferentBaseCurrency() external {
        // it returns the correct tokenCount when baseCurrency differs from payment currency

        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: _nativeCurrency,
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
            scopeCashOutsToLocalBalances: false,
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

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        // mock call to JBPrices pricePerUnitOf
        mockExpect(
            address(prices),
            abi.encodeCall(IJBPrices.pricePerUnitOf, (_projectId, _currency, _nativeCurrency, 18)),
            abi.encode(2e18)
        );

        uint256 expectedCount = mulDiv(_defaultValue, 1e18, 2e18);

        (, uint256 tokenCount,) = _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });

        assertEq(tokenCount, expectedCount);
    }

    function test_WithDataHookAndZeroAmountNoopSpec() external {
        JBTokenAmount memory _tokenAmount = JBTokenAmount({
            token: address(_token), value: _defaultValue, decimals: _defaultDecimals, currency: _currency
        });

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(address(_token))),
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
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

        JBPayHookSpecification[] memory _spec = new JBPayHookSpecification[](1);
        _spec[0] = JBPayHookSpecification({hook: _payHook, noop: true, amount: 0, metadata: "info"});

        JBBeforePayRecordedContext memory _context = JBBeforePayRecordedContext({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            rulesetId: uint48(block.timestamp),
            beneficiary: address(this),
            weight: _returnedRuleset.weight,
            reservedPercent: _returnedRuleset.reservedPercent(),
            metadata: ""
        });

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(
            address(_dataHook),
            abi.encodeCall(IJBRulesetDataHook.beforePayRecordedWith, (_context)),
            abi.encode(1e18 / 2, _spec)
        );

        (, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications) = _store.previewPayFrom({
            terminal: _terminal,
            payer: address(this),
            amount: _tokenAmount,
            projectId: _projectId,
            beneficiary: address(this),
            metadata: ""
        });

        assertEq(tokenCount, 1e18 / 2);
        assertEq(hookSpecifications.length, 1);
        assertEq(hookSpecifications[0].amount, 0);
        assertTrue(hookSpecifications[0].noop);
        assertEq(hookSpecifications[0].metadata, bytes("info"));
    }
}
