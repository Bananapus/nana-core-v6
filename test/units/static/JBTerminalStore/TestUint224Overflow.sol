// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBTerminalStoreSetup} from "./JBTerminalStoreSetup.sol";

contract TestUint224Overflow_Local is JBTerminalStoreSetup {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    uint256 _projectId = 1;

    // Mocks
    IJBTerminal _terminal = IJBTerminal(makeAddr("terminal"));
    IJBToken _token = IJBToken(makeAddr("token"));
    IJBController _controller = IJBController(makeAddr("controller"));
    IJBFundAccessLimits _accessLimits = IJBFundAccessLimits(makeAddr("funds"));

    uint32 _currency = uint32(uint160(address(_token)));

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

    /// @notice Helper to create a standard ruleset with packed metadata.
    function _mockRulesetAndControllerCalls() internal {
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: _currency,
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
            useTotalSurplusForCashOuts: false,
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

        // Mock rulesets.currentOf
        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(_returnedRuleset));

        // Mock directory.controllerOf
        mockExpect(address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(_controller));

        // Mock controller.FUND_ACCESS_LIMITS
        mockExpect(
            address(_controller), abi.encodeCall(IJBController.FUND_ACCESS_LIMITS, ()), abi.encode(_accessLimits)
        );
    }

    /// @notice Verifies that decimal adjustment overflow reverts with Uint224Overflow.
    /// A payout limit that fits in uint224 but overflows when adjusted from 6 to 18 decimals.
    function test_RevertWhen_DecimalAdjustmentOverflowsUint224() external {
        // Balance must be large enough (after decimal adjustment) to exceed the payout limit,
        // but not so large that the balance itself overflows during adjustment.
        // Balance in 6-decimal terms: 1e62 → adjusted to 18 decimals = 1e74 (fits uint256).
        _setBalance(address(_terminal), _projectId, address(_token), 1e62);

        _mockRulesetAndControllerCalls();

        // Amount that fits in uint224 but when multiplied by 10^12 (6→18 decimal adjustment) exceeds uint224.
        // type(uint224).max / 1e6 ≈ 2.7e61. Multiplied by 1e12 → ≈ 2.7e73, exceeds uint224 but fits uint256.
        uint224 amount = type(uint224).max / 1e6;
        JBCurrencyAmount[] memory _limits = new JBCurrencyAmount[](1);
        _limits[0] = JBCurrencyAmount({amount: amount, currency: _currency});

        // Mock payoutLimitsOf to return the large limit.
        mockExpect(
            address(_accessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.payoutLimitsOf, (_projectId, block.timestamp, address(_terminal), address(_token))
            ),
            abi.encode(_limits)
        );

        // Accounting context: token has 6 decimals.
        JBAccountingContext[] memory _contexts = new JBAccountingContext[](1);
        _contexts[0] = JBAccountingContext({token: address(_token), decimals: 6, currency: _currency});

        // Query surplus with 18 target decimals — triggers decimal adjustment overflow.
        uint256 adjusted = uint256(amount) * 1e12;
        vm.expectRevert(abi.encodeWithSelector(JBTerminalStore.JBTerminalStore_Uint224Overflow.selector, adjusted));
        _store.currentSurplusOf(address(_terminal), _projectId, _contexts, 18, _currency);
    }

    /// @notice Verifies that currency conversion overflow reverts with Uint224Overflow.
    /// A payout limit near type(uint224).max in currency A, converted to currency B at a very low price,
    /// would overflow uint224.
    function test_RevertWhen_CurrencyConversionOverflowsUint224() external {
        // Set up a large balance.
        _setBalance(address(_terminal), _projectId, address(_token), type(uint256).max);

        _mockRulesetAndControllerCalls();

        // Payout limit near uint224 max, in a DIFFERENT currency than the target.
        uint32 _otherCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        JBCurrencyAmount[] memory _limits = new JBCurrencyAmount[](1);
        _limits[0] = JBCurrencyAmount({amount: type(uint224).max, currency: _otherCurrency});

        // Mock payoutLimitsOf.
        mockExpect(
            address(_accessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.payoutLimitsOf, (_projectId, block.timestamp, address(_terminal), address(_token))
            ),
            abi.encode(_limits)
        );

        // Mock price: very low price means large converted amount.
        // pricePerUnitOf returns price with _MAX_FIXED_POINT_FIDELITY (18) decimals.
        // A price of 1 (1 wei) means 1 unit of pricingCurrency = 10^18 units of unitCurrency.
        mockExpect(
            address(prices),
            abi.encodeCall(IJBPrices.pricePerUnitOf, (_projectId, _otherCurrency, _currency, 18)),
            abi.encode(uint256(1)) // extremely low price → huge conversion result
        );

        // Same decimals so no decimal adjustment.
        JBAccountingContext[] memory _contexts = new JBAccountingContext[](1);
        _contexts[0] = JBAccountingContext({token: address(_token), decimals: 18, currency: _currency});

        // The conversion: mulDiv(type(uint224).max, 10^18, 1) = type(uint224).max * 10^18 → overflows uint224.
        vm.expectRevert();
        _store.currentSurplusOf(address(_terminal), _projectId, _contexts, 18, _currency);
    }

    /// @notice Verifies that normal amounts below uint224.max pass through without reverting.
    function test_NormalAmountsDoNotRevert() external {
        // Balance in 6-decimal terms: 100e6 = 100 units. Adjusted to 18 decimals = 100e18.
        uint256 _balance = 100e6;
        _setBalance(address(_terminal), _projectId, address(_token), _balance);

        _mockRulesetAndControllerCalls();

        // Normal payout limit: 50 units in 6-decimal token. Adjusted to 18 decimals = 50e18.
        JBCurrencyAmount[] memory _limits = new JBCurrencyAmount[](1);
        _limits[0] = JBCurrencyAmount({amount: 50e6, currency: _currency});

        // Mock payoutLimitsOf.
        mockExpect(
            address(_accessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.payoutLimitsOf, (_projectId, block.timestamp, address(_terminal), address(_token))
            ),
            abi.encode(_limits)
        );

        // 6-decimal token queried as 18-decimal target.
        // Balance: 100e6 → 100e18. Payout limit: 50e6 → 50e18. Surplus = 50e18.
        JBAccountingContext[] memory _contexts = new JBAccountingContext[](1);
        _contexts[0] = JBAccountingContext({token: address(_token), decimals: 6, currency: _currency});

        uint256 surplus = _store.currentSurplusOf(address(_terminal), _projectId, _contexts, 18, _currency);
        assertEq(surplus, 50e18);
    }
}
