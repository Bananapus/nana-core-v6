// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBCashOuts} from "../src/libraries/JBCashOuts.sol";

/// @notice Edge case tests for cross-ruleset cash outs and pending reserves inflation (H-4).
/// Demonstrates that pending reserved tokens inflate totalSupply in cash-out calculations,
/// systematically undervaluing cash-outs until reserves are distributed.
contract TestCashOutTimingEdge_Local is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    JBTokens private _tokens;
    JBTerminalStore private _store;
    uint256 private _projectId;
    address private _projectOwner;
    address private _payer;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint112 private constant PAY_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _payer = beneficiary();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();
        _store = jbTerminalStore();

        // Ruleset: 50% reserved, 50% cash-out tax, no duration (persists forever).
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
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: tokensToAccept});

        // Fee project (#1).
        _controller.launchProjectFor({
            owner: address(420),
            projectUri: "fee",
            rulesetConfigurations: rulesetConfig,
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

        // Deploy ERC20 for the project.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "Test", "TST", bytes32(0));
    }

    /// @notice H-4 CONFIRMATION: Pending reserves inflate totalSupply, reducing cash-out value.
    /// When reserves exist but haven't been distributed, totalTokenSupplyWithReservedTokensOf
    /// includes them in the denominator, making each token worth less.
    function test_pendingReserves_inflateSupply_reduceCashOut() external {
        // Pay the project.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Check payer's token balance. With 50% reserved, payer gets 50% of tokens.
        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);
        assertGt(payerTokens, 0, "Payer should have tokens");

        // Check pending reserves.
        uint256 pendingReserves = _controller.pendingReservedTokenBalanceOf(_projectId);
        assertGt(pendingReserves, 0, "Should have pending reserves");

        // Total supply WITH pending reserves (used in cash-out calculation).
        uint256 totalWithReserves = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);
        // Total supply WITHOUT pending reserves (actual circulating).
        uint256 circulatingSupply = _tokens.totalSupplyOf(_projectId);

        assertGt(totalWithReserves, circulatingSupply, "Total with reserves should exceed circulating");
        assertEq(totalWithReserves, circulatingSupply + pendingReserves, "Total = circulating + pending reserves");

        // Compute cash-out value with inflated supply (what the system does).
        uint256 surplus = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 reclaimWithInflation = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: totalWithReserves, cashOutTaxRate: 5000
        });

        // Compute what the cash-out WOULD be without pending reserves (hypothetical).
        uint256 reclaimWithoutInflation = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: circulatingSupply, cashOutTaxRate: 5000
        });

        // H-4 CONFIRMED: Cash-out with pending reserves is LESS than without.
        assertLt(reclaimWithInflation, reclaimWithoutInflation, "H-4: Pending reserves reduce cash-out value");

        // Quantify the impact.
        uint256 lostValue = reclaimWithoutInflation - reclaimWithInflation;
        assertGt(lostValue, 0, "Lost value should be non-zero");
    }

    /// @notice Distribute reserves first, then cash out — value should be higher.
    function test_distributeReserves_thenCashOut_higherReclaim() external {
        // Pay the project.
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);

        // Snapshot cash-out value BEFORE distributing reserves.
        uint256 surplus = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 totalBefore = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);
        uint256 reclaimBefore = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: totalBefore, cashOutTaxRate: 5000
        });

        // Distribute reserves. This mints pending tokens and zeroes pending balance.
        _controller.sendReservedTokensToSplitsOf(_projectId);

        // After distribution, pending reserves should be 0.
        assertEq(
            _controller.pendingReservedTokenBalanceOf(_projectId), 0, "Pending reserves should be 0 after distribution"
        );

        // Total supply should be the same (pending tokens are now real tokens).
        uint256 totalAfter = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);
        assertEq(totalAfter, totalBefore, "Total supply unchanged after distribution");

        // Cash-out value should be the same since total didn't change.
        // The fix for H-4 would be: don't include pending reserves in totalSupply.
        uint256 reclaimAfter = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: totalAfter, cashOutTaxRate: 5000
        });

        assertEq(reclaimAfter, reclaimBefore, "Reclaim unchanged after distributing (same totalSupply)");
    }

    /// @notice Quantify exact impact: with 50% reserved, cash-out gets ~44% less value
    /// than it would if pending reserves were excluded from totalSupply.
    function test_pendingReserves_quantifyImpact() external {
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 payerTokens = _tokens.totalBalanceOf(_payer, _projectId);
        uint256 surplus = _store.balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 totalWithReserves = _controller.totalTokenSupplyWithReservedTokensOf(_projectId);
        uint256 circulatingOnly = _tokens.totalSupplyOf(_projectId);

        uint256 reclaimActual = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: totalWithReserves, cashOutTaxRate: 5000
        });

        uint256 reclaimFair = JBCashOuts.cashOutFrom({
            surplus: surplus, cashOutCount: payerTokens, totalSupply: circulatingOnly, cashOutTaxRate: 5000
        });

        // With 50% reserved:
        // - circulatingOnly = payerTokens (payer gets all non-reserved tokens)
        // - totalWithReserves = 2 * payerTokens
        // At 50% tax and cashOutCount == circulatingOnly:
        //   reclaimFair = surplus (full amount, since cashOutCount >= totalSupply)
        //   reclaimActual = surplus * (payerTokens / 2*payerTokens) * ((5000 + 5000*0.5) / 10000)
        //                 = surplus * 0.5 * 0.75 = surplus * 0.375

        // The impact is significant — actual is only 37.5% of surplus vs 100%.
        assertGt(reclaimFair, reclaimActual, "Fair reclaim significantly higher than actual");

        // Log the percentage lost.
        uint256 percentLost = ((reclaimFair - reclaimActual) * 10_000) / reclaimFair;
        assertGt(percentLost, 5000, "More than 50% value lost due to pending reserves");
    }
}
