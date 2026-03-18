// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {JBTerminalStore} from "../../src/JBTerminalStore.sol";
import {JBTokens} from "../../src/JBTokens.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBCashOuts} from "../../src/libraries/JBCashOuts.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFee} from "../../src/structs/JBFee.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

/// @notice Regression test for the three-way interaction between holdFees, cashOutTaxRate, and reservedPercent.
/// Exercises the full lifecycle: pay -> sendPayouts (holding fees) -> cashOut (with tax + pending reserves) ->
/// distribute reserved tokens, then verifies all accounting invariants hold.
contract HoldFeesCashOutReserved_Local is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    JBTokens private _tokens;
    JBTerminalStore private _store;
    uint256 private _projectId;
    address private _projectOwner;
    address private _payer;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint112 private constant PAY_AMOUNT = 10 ether;
    uint224 private constant PAYOUT_LIMIT = 2 ether;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _payer = beneficiary();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();
        _store = jbTerminalStore();

        // Three-way config: holdFees + 50% reservedPercent + 50% cashOutTaxRate.
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 5000, // 50%
            cashOutTaxRate: 5000, // 50%
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: true,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        // Payout limit of 2 ETH.
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        {
            JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
            payoutLimits[0] =
                JBCurrencyAmount({amount: PAYOUT_LIMIT, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
            JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
            surplusAllowances[0] = JBCurrencyAmount({amount: 0, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
            fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: payoutLimits,
                surplusAllowances: surplusAllowances
            });
        }

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: tokensToAccept});

        // Fee project (#1) — needed so fees can be processed.
        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        feeRulesetConfig[0].duration = 0;
        feeRulesetConfig[0].weight = 0;
        feeRulesetConfig[0].weightCutPercent = 0;
        feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        feeRulesetConfig[0].metadata = JBRulesetMetadata({
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        _controller.launchProjectFor({
            owner: address(420),
            projectUri: "fee",
            rulesetConfigurations: feeRulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Test project (#2).
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "test",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Deploy ERC20 so we can track token balances precisely.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "Test", "TST", bytes32(0));
    }

    /// @notice Full lifecycle: pay -> payout (held fees) -> cashOut -> distribute reserves.
    /// Verifies that all three features interact correctly and accounting remains consistent.
    function test_holdFees_cashOut_reservedPercent_fullLifecycle() external {
        // ── Step 1: Pay into the project ──
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // After payment: store balance = 10 ETH, payer gets 50% of tokens (rest reserved).
        assertEq(
            _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN),
            PAY_AMOUNT,
            "Store balance should equal payment amount"
        );

        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);
        {
            // weight=1000e18 tokens per 1 ETH, pay=10 ETH => 10000e18 total. 50% reserved => payer gets 5000e18.
            uint256 expectedPayerTokens = uint256(WEIGHT) * uint256(PAY_AMOUNT)
                * (JBConstants.MAX_RESERVED_PERCENT - 5000) / JBConstants.MAX_RESERVED_PERCENT / 1 ether;
            assertEq(payerTokens, expectedPayerTokens, "Payer should have 50% of minted tokens");
        }

        assertEq(
            _controller.pendingReservedTokenBalanceOf(_projectId),
            payerTokens,
            "Pending reserves should equal payer tokens (50/50)"
        );
        assertEq(address(_terminal).balance, PAY_AMOUNT, "Terminal ETH should equal payment");

        // ── Step 2: Send payouts (triggers held fees) ──
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: PAYOUT_LIMIT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        {
            uint256 feeOnPayout = JBFees.feeAmountFrom({amountBeforeFee: PAYOUT_LIMIT, feePercent: _terminal.FEE()});

            assertEq(
                _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN),
                PAY_AMOUNT - PAYOUT_LIMIT,
                "Store balance should be reduced by payout limit"
            );
            assertEq(_projectOwner.balance, PAYOUT_LIMIT - feeOnPayout, "Owner should receive payout minus fee");
            assertEq(
                address(_terminal).balance,
                PAY_AMOUNT - (PAYOUT_LIMIT - feeOnPayout),
                "Terminal should hold remaining balance + held fee"
            );

            JBFee[] memory heldFees = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 10);
            assertEq(heldFees.length, 1, "Should have one held fee");
            assertEq(heldFees[0].amount, PAYOUT_LIMIT, "Held fee should record the full payout amount");
        }

        // ── Step 3: Cash out with tax + pending reserves ──
        {
            uint256 cashOutCount = payerTokens / 2;
            uint256 surplus = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
            uint256 totalSupply = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);

            uint256 grossReclaim = JBCashOuts.cashOutFrom({
                surplus: surplus, cashOutCount: cashOutCount, totalSupply: totalSupply, cashOutTaxRate: 5000
            });
            assertGt(grossReclaim, 0, "Gross reclaim should be positive");

            // Cashout fees are NOT held — processed immediately (shouldHoldFees: false in _cashOutTokensOf).
            uint256 expectedNetReclaim =
                grossReclaim - JBFees.feeAmountFrom({amountBeforeFee: grossReclaim, feePercent: _terminal.FEE()});
            uint256 payerBalanceBefore = _payer.balance;

            vm.prank(_payer);
            uint256 actualReclaim = _terminal.cashOutTokensOf({
                holder: _payer,
                projectId: _projectId,
                cashOutCount: cashOutCount,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(_payer),
                metadata: new bytes(0)
            });

            assertEq(actualReclaim, expectedNetReclaim, "Actual reclaim should match bonding curve minus fee");
            assertEq(
                _payer.balance - payerBalanceBefore,
                expectedNetReclaim,
                "Payer ETH balance increase should equal net reclaim"
            );
            assertEq(
                _tokens.totalBalanceOf(_payer, _projectId),
                payerTokens - cashOutCount,
                "Payer tokens should decrease by cashOut count"
            );
        }

        // ── Step 4: Distribute reserved tokens ──
        assertGt(
            _controller.pendingReservedTokenBalanceOf(_projectId), 0, "Should have pending reserves before distribution"
        );
        _controller.sendReservedTokensToSplitsOf(_projectId);
        assertEq(
            _controller.pendingReservedTokenBalanceOf(_projectId), 0, "Pending reserves should be 0 after distribution"
        );

        // ── Step 5: Verify accounting invariants ──
        {
            uint256 finalStoreBalance = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
            assertGe(
                address(_terminal).balance, finalStoreBalance, "Terminal ETH balance must be >= store recorded balance"
            );

            uint256 totalTokenSupply = _tokens.totalSupplyOf(_projectId);
            assertGt(totalTokenSupply, 0, "Total token supply should be positive");
            assertEq(
                _controller.totalTokenSupplyWithReservedTokensOf(_projectId),
                totalTokenSupply,
                "After distributing reserves, total supply with/without reserves should match"
            );

            // Conservation check: terminal balance >= project balance + held fee value.
            JBFee[] memory remainingHeldFees = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 100);
            uint256 totalHeldFeeValue;
            for (uint256 i; i < remainingHeldFees.length; i++) {
                totalHeldFeeValue += JBFees.feeAmountFrom({
                    amountBeforeFee: remainingHeldFees[i].amount, feePercent: _terminal.FEE()
                });
            }
            assertGe(
                address(_terminal).balance,
                finalStoreBalance + totalHeldFeeValue,
                "Terminal balance must cover project balance + held fee amounts"
            );
        }
    }

    /// @notice Verify that held fees don't distort the surplus used in cashout calculations.
    /// The store's recorded balance (not the terminal's ETH balance) determines surplus.
    function test_heldFees_dontInflateSurplus() external {
        // Pay into the project.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Send payouts to trigger held fees.
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: PAYOUT_LIMIT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        // The store balance (surplus base) should NOT include the held fee amount.
        uint256 storeBalance = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(storeBalance, PAY_AMOUNT - PAYOUT_LIMIT, "Store balance should not include held fees");

        // The terminal's actual ETH balance includes the held fee.
        assertGt(address(_terminal).balance, storeBalance, "Terminal ETH should exceed store balance due to held fees");

        // The difference should be accounted for by held fees + fee project balance.
        uint256 feeProjectBalance = _store.balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);
        JBFee[] memory heldFees = _terminal.heldFeesOf(_projectId, JBConstants.NATIVE_TOKEN, 10);
        uint256 heldFeeValue;
        for (uint256 i; i < heldFees.length; i++) {
            heldFeeValue += JBFees.feeAmountFrom({amountBeforeFee: heldFees[i].amount, feePercent: _terminal.FEE()});
        }

        assertEq(
            address(_terminal).balance,
            storeBalance + heldFeeValue + feeProjectBalance,
            "Terminal balance = project balance + held fee value + fee project balance"
        );
    }

    /// @notice Cash out with pending reserves and held fees — verify bonding curve uses correct supply.
    function test_cashOut_usesCorrectTotalSupply_withPendingReservesAndHeldFees() external {
        // Pay into the project.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Send payouts (creating held fees).
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: PAYOUT_LIMIT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);
        uint256 surplus = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);

        // Total supply WITH pending reserves (what the system uses for cashOut).
        uint256 totalWithReserves = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);
        // Total supply WITHOUT pending reserves.
        uint256 circulatingSupply = _tokens.totalSupplyOf(_projectId);

        // Pending reserves should inflate total supply.
        assertGt(totalWithReserves, circulatingSupply, "Total with reserves > circulating");

        // Compute expected cashout with the inflated supply (what the system does).
        uint256 reclaimWithReserves = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: totalWithReserves, cashOutTaxRate: 5000
        });

        // Compute hypothetical cashout without pending reserves.
        uint256 reclaimWithoutReserves = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: circulatingSupply, cashOutTaxRate: 5000
        });

        // With pending reserves, the cashout value is lower (known behavior, H-4).
        assertLt(reclaimWithReserves, reclaimWithoutReserves, "Pending reserves reduce cashout value (expected, H-4)");

        // Actually perform the cashout and confirm it matches the with-reserves calculation (net of fee).
        // cashOutTokensOf returns the NET reclaim after the 2.5% fee is deducted.
        uint256 feeOnReclaim = JBFees.feeAmountFrom({amountBeforeFee: reclaimWithReserves, feePercent: _terminal.FEE()});
        uint256 expectedNetReclaim = reclaimWithReserves - feeOnReclaim;

        vm.prank(_payer);
        uint256 actualReclaim = _terminal.cashOutTokensOf({
            holder: _payer,
            projectId: _projectId,
            cashOutCount: payerTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_payer),
            metadata: new bytes(0)
        });

        assertEq(
            actualReclaim,
            expectedNetReclaim,
            "Actual cashout should match bonding curve with pending reserves (net of fee)"
        );
    }
}
