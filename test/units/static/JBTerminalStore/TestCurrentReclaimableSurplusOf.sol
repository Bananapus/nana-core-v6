// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "../../../../src/interfaces/IJBFundAccessLimits.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {IJBToken} from "../../../../src/interfaces/IJBToken.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../../../src/structs/JBCurrencyAmount.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBTerminalStoreSetup} from "./JBTerminalStoreSetup.sol";
import {JBCashOuts} from "../../../../src/libraries/JBCashOuts.sol";

contract TestCurrentReclaimableSurplusOf_Local is JBTerminalStoreSetup {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    uint256 _projectId = 1;
    uint256 _balance = 1e18;

    // Mocks
    IJBTerminal _terminal = IJBTerminal(makeAddr("terminal"));
    IJBToken _token = IJBToken(makeAddr("token"));
    IJBController _controller = IJBController(makeAddr("controller"));
    IJBFundAccessLimits _accessLimits = IJBFundAccessLimits(makeAddr("funds"));

    uint32 _currency = uint32(uint160(address(_token)));
    uint256 _tokenCount = 1e18;

    function setUp() public {
        super.terminalStoreSetup();
    }

    /// @notice Helper to register an accounting context with the store (pranks as the terminal).
    function _registerContext(JBAccountingContext memory ctx) internal {
        JBAccountingContext[] memory ctxs = new JBAccountingContext[](1);
        ctxs[0] = ctx;
        vm.prank(address(_terminal));
        _store.recordAccountingContextOf(_projectId, ctxs);
    }

    /// @notice Helper to set balance for the terminal/project/token via vm.store.
    function _setBalance(uint256 balance) internal {
        bytes32 balanceOfSlot = keccak256(abi.encode(address(_terminal), uint256(0)));
        bytes32 projectSlot = keccak256(abi.encode(_projectId, uint256(balanceOfSlot)));
        bytes32 slot = keccak256(abi.encode(address(_token), uint256(projectSlot)));
        vm.store(address(_store), slot, bytes32(balance));
    }

    /// @notice Helper to set up common mocks for surplus computation.
    /// @param packedMetadata The packed ruleset metadata.
    /// @param payoutLimits The payout limits to mock.
    function _mockSurplusInfra(uint256 packedMetadata, JBCurrencyAmount[] memory payoutLimits) internal {
        JBRuleset memory _returnedRuleset = JBRuleset({
            cycleNumber: uint48(block.timestamp),
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: uint32(block.timestamp + 1000),
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packedMetadata
        });

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));
        mockExpect(
            address(_controller), abi.encodeCall(IJBController.FUND_ACCESS_LIMITS, ()), abi.encode(_accessLimits)
        );
        mockExpect(
            address(_accessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.payoutLimitsOf, (_projectId, block.timestamp, address(_terminal), address(_token))
            ),
            abi.encode(payoutLimits)
        );
    }

    function test_GivenCurrentSurplusEqZero() external {
        // it will return zero

        // Register accounting context so the store can resolve it.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        // No balance set — surplus is 0.
        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(0, _emptyLimits);

        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;
        uint256 reclaimable =
            _store.currentReclaimableSurplusOf(_projectId, _tokenCount, _terminals, new address[](0), 18, _currency);
        assertEq(0, reclaimable);
    }

    function test_GivenCurrentSurplusGtZero() external {
        // it will get the number of outstanding tokens and return the reclaimable surplus

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2,
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        uint224 _payout = 1e17;
        uint256 _supply = 1e19;
        uint256 _cashoutAmount = 1e18;
        uint256 _surplus = _supply - _payout;

        // Set balance = surplus + payout limit to get the desired surplus after deducting limits.
        // balance - payoutLimit = surplus => balance = surplus + payoutLimit
        // But we want surplus = _supply - _payout = 9.9e18. So set balance = surplus (with zero limits).
        _setBalance(_surplus);

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        // mock JBController totalTokenSupplyWithReservedTokensOf
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_supply)
        );

        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;
        uint256 reclaimable =
            _store.currentReclaimableSurplusOf(_projectId, _cashoutAmount, _terminals, new address[](0), 18, _currency);

        // The above call should be calculating the reclaimable amount as we are here, so they will be congruent.
        uint256 assumed =
            JBCashOuts.cashOutFrom(_surplus, _cashoutAmount, _supply, JBConstants.MAX_CASH_OUT_TAX_RATE / 2);

        assertEq(assumed, reclaimable);
    }

    function test_GivenTokenCountIsEqToTotalSupply() external {
        // it will return the rest of the surplus

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        // Set balance = tokenCount so surplus = tokenCount (with zero payout limits).
        _setBalance(_tokenCount);

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        // mock JBController totalTokenSupplyWithReservedTokensOf
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_tokenCount)
        );

        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;
        uint256 reclaimable =
            _store.currentReclaimableSurplusOf(_projectId, _tokenCount, _terminals, new address[](0), 18, _currency);

        // The tokenCount is equal to the total supply, so the reclaimable amount will be the same as the supply. We
        // couldn't reclaim more.
        assertEq(_tokenCount, reclaimable);
    }

    function test_GivenCashOutTaxRateEqZero() external {
        // it will return zero (cashOutTaxRate = MAX means no surplus can be reclaimed)

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE, // no surplus can be reclaimed.
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        // Set balance = 1e18 so surplus = 1e18 (with zero payout limits).
        _setBalance(1e18);

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        // mock JBController totalTokenSupplyWithReservedTokensOf
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(1e18)
        );

        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;
        uint256 reclaimable =
            _store.currentReclaimableSurplusOf(_projectId, _tokenCount, _terminals, new address[](0), 18, _currency);

        // No surplus can be reclaimed.
        assertEq(0, reclaimable);
    }

    function test_GivenCashOutRateDneqMAX_CASH_OUT_RATE() external {
        // it will return the calculated proportion

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2,
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        // Set balance = 1e18 so surplus = 1e18 (with zero payout limits).
        _setBalance(1e18);

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        // mock JBController totalTokenSupplyWithReservedTokensOf
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(1e18)
        );

        uint256 reclaimable;
        {
            IJBTerminal[] memory _terminals = new IJBTerminal[](1);
            _terminals[0] = _terminal;
            reclaimable = _store.currentReclaimableSurplusOf(
                _projectId, _tokenCount, _terminals, new address[](0), 18, _currency
            );
        }

        uint256 assumed = mulDiv(
            1e18,
            5000 + mulDiv(_tokenCount, JBConstants.MAX_CASH_OUT_TAX_RATE - 5000, 1e18),
            JBConstants.MAX_CASH_OUT_TAX_RATE
        );

        assertEq(assumed, reclaimable);
    }

    function test_GivenNotOverloaded() external {
        // it will get the current ruleset and proceed to return reclaimable as above

        // This test uses the 4-param overload (projectId, cashOutCount, totalSupply, surplus)
        // which does not go through the store's currentSurplusOf — it takes surplus directly.
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2,
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
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

        uint256 reclaimable = _store.currentReclaimableSurplusOf(_projectId, _tokenCount, 1e18, 1e18);
        assertEq(1e18, reclaimable);
    }

    function test_GivenTotalReclaimableWithSurplus() external {
        // it will default to all terminals and all accounting contexts and return the reclaimable surplus

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2,
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        uint256 _supply = 1e19;
        uint256 _surplus = 1e18;
        uint256 _cashoutAmount = 1e18;

        // Set balance = surplus (with zero payout limits, surplus = balance).
        _setBalance(_surplus);

        // Mock terminalsOf to return our terminal (for currentTotalReclaimableSurplusOf which uses empty terminals).
        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        // mock JBController totalTokenSupplyWithReservedTokensOf
        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_supply)
        );

        // Call the new convenience function (no terminals, no accounting contexts).
        uint256 reclaimable = _store.currentTotalReclaimableSurplusOf(_projectId, _cashoutAmount, 18, _currency);

        // Should match the 6-param overload result.
        uint256 assumed =
            JBCashOuts.cashOutFrom(_surplus, _cashoutAmount, _supply, JBConstants.MAX_CASH_OUT_TAX_RATE / 2);

        assertEq(assumed, reclaimable);
    }

    function test_GivenTotalReclaimableWithZeroSurplus() external {
        // it will return zero when there is no surplus

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        // No balance set — surplus is 0.

        // Mock terminalsOf to return our terminal.
        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);
        _mockSurplusInfra(0, _emptyLimits);

        uint256 reclaimable = _store.currentTotalReclaimableSurplusOf(_projectId, _tokenCount, 18, _currency);
        assertEq(0, reclaimable);
    }

    function test_GivenTotalReclaimableMatchesSixParamOverload() external {
        // it will produce the same result as calling the 6-param overload with empty arrays

        // Register accounting context.
        _registerContext(JBAccountingContext({token: address(_token), decimals: 18, currency: _currency}));

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2,
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        uint256 _supply = 1e19;
        uint256 _surplus = 5e17;
        uint256 _cashoutAmount = 1e18;

        // Set balance = surplus (with zero payout limits).
        _setBalance(_surplus);

        IJBTerminal[] memory _terminals = new IJBTerminal[](1);
        _terminals[0] = _terminal;

        JBCurrencyAmount[] memory _emptyLimits = new JBCurrencyAmount[](0);

        // --- Call 1: currentTotalReclaimableSurplusOf (uses empty terminals -> resolves from directory) ---

        // Mock terminalsOf for the total reclaimable call.
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_supply)
        );

        uint256 reclaimableDefault = _store.currentTotalReclaimableSurplusOf(_projectId, _cashoutAmount, 18, _currency);

        // --- Call 2: 6-param overload with empty arrays ---

        // Re-mock for the 6-param call (mocks are consumed by the first call).
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (_projectId)), abi.encode(_terminals));

        _mockSurplusInfra(_packedMetadata, _emptyLimits);

        mockExpect(
            address(_controller),
            abi.encodeCall(IJBController.totalTokenSupplyWithReservedTokensOf, (_projectId)),
            abi.encode(_supply)
        );

        uint256 reclaimableExplicit = _store.currentReclaimableSurplusOf(
            _projectId, _cashoutAmount, new IJBTerminal[](0), new address[](0), 18, _currency
        );

        assertEq(reclaimableDefault, reclaimableExplicit);
    }
}
