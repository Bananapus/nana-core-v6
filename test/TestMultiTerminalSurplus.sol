// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTokens} from "../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Tests for multi-terminal surplus aggregation edge cases, including cross-terminal
/// surplus with useTotalSurplusForCashOuts, cash out balance limits, and price conversion.
contract TestMultiTerminalSurplus_Local is TestBaseWorkflow {
    IJBController private _controller;
    JBMultiTerminal private _terminal1;
    JBMultiTerminal private _terminal2;
    IJBTokens private _tokens;
    address private _projectOwner;
    address private _user;

    MockPriceFeed private _ethToUsdcFeed;
    MockERC20 private _usdc;

    uint32 private _nativeCurrency;
    uint32 private _usdcCurrency;

    uint256 private _projectId;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _user = beneficiary();
        _controller = jbController();
        _terminal1 = jbMultiTerminal();
        _terminal2 = jbMultiTerminal2();
        _tokens = jbTokens();
        _usdc = usdcToken();

        _nativeCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        _usdcCurrency = uint32(uint160(address(_usdc)));

        // Price feed: 1 ETH = 2000 USDC (6 decimals).
        _ethToUsdcFeed = new MockPriceFeed(2000e6, 6);

        // Metadata with useTotalSurplusForCashOuts = true.
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: _nativeCurrency,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = 1000 * 10 ** 18;
        _rulesetConfig[0].weightCutPercent = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Terminal 1 accepts ETH; Terminal 2 accepts USDC.
        JBAccountingContext[] memory _ethContext = new JBAccountingContext[](1);
        _ethContext[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});

        JBAccountingContext[] memory _usdcContext = new JBAccountingContext[](1);
        _usdcContext[0] = JBAccountingContext({token: address(_usdc), decimals: 6, currency: _usdcCurrency});

        JBTerminalConfig[] memory _terminalConfigs = new JBTerminalConfig[](2);
        _terminalConfigs[0] = JBTerminalConfig({terminal: _terminal1, accountingContextsToAccept: _ethContext});
        _terminalConfigs[1] = JBTerminalConfig({terminal: _terminal2, accountingContextsToAccept: _usdcContext});

        // Launch project with both terminals.
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "multi-terminal-surplus-test",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigs,
            memo: ""
        });

        // Add price feed: USDC priced in native token terms.
        vm.prank(_projectOwner);
        _controller.addPriceFeedFor({
            projectId: _projectId, pricingCurrency: _usdcCurrency, unitCurrency: _nativeCurrency, feed: _ethToUsdcFeed
        });

        // Deploy ERC-20 for the project.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "MultiTermToken", "MTT", bytes32(0));
    }

    /// @notice Helper: pay ETH into terminal 1.
    function _payEth(address payer, uint256 amount) internal returns (uint256 tokensReceived) {
        vm.deal(payer, amount);
        vm.prank(payer);
        tokensReceived = _terminal1.pay{value: amount}({
            projectId: _projectId,
            amount: amount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Helper: pay USDC into terminal 2.
    function _payUsdc(address payer, uint256 amount) internal returns (uint256 tokensReceived) {
        _usdc.mint(payer, amount);
        vm.prank(payer);
        _usdc.approve(address(permit2()), amount);
        vm.prank(payer);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2().approve(address(_usdc), address(_terminal2), uint160(amount), type(uint48).max);

        vm.prank(payer);
        tokensReceived = _terminal2.pay({
            projectId: _projectId,
            amount: amount,
            token: address(_usdc),
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Surplus aggregation across 2 terminals with different tokens.
    function test_surplusAcrossTwoTerminals() public {
        uint256 ethAmount = 2 ether;
        uint256 usdcAmount = 4000e6; // $4000 = 2 ETH

        _payEth(_user, ethAmount);
        _payUsdc(_user, usdcAmount);

        // Check ETH-only surplus from terminal 1.
        JBAccountingContext[] memory ethCtx = new JBAccountingContext[](1);
        ethCtx[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});
        uint256 ethSurplus = _terminal1.currentSurplusOf(_projectId, new address[](0), 18, _nativeCurrency);
        assertEq(ethSurplus, ethAmount, "terminal1 ETH surplus should match payment");

        // Check USDC-only surplus from terminal 2.
        JBAccountingContext[] memory usdcCtx = new JBAccountingContext[](1);
        usdcCtx[0] = JBAccountingContext({token: address(_usdc), decimals: 6, currency: _usdcCurrency});
        uint256 usdcSurplus = _terminal2.currentSurplusOf(_projectId, new address[](0), 6, _usdcCurrency);
        assertEq(usdcSurplus, usdcAmount, "terminal2 USDC surplus should match payment");

        // Check total surplus in ETH terms from the store.
        uint256 totalSurplusEth = jbTerminalStore().currentTotalSurplusOf(_projectId, 18, _nativeCurrency);
        // Should be ETH amount + USDC-converted-to-ETH.
        // The total should be greater than just the ETH amount.
        assertGt(totalSurplusEth, ethAmount, "total surplus should include converted USDC value");
    }

    /// @notice With useTotalSurplusForCashOuts enabled, cash out from terminal 1 uses combined surplus.
    function test_cashOutUsesTotalSurplusWhenEnabled() public {
        uint256 ethAmount = 1 ether;
        uint256 usdcAmount = 2000e6; // $2000 = 1 ETH

        uint256 userEthTokens = _payEth(_user, ethAmount);
        _payUsdc(_user, usdcAmount);

        // User cashes out from terminal 1 (ETH).
        // useTotalSurplusForCashOuts is enabled, so the bonding curve should consider
        // the total surplus across both terminals, not just terminal 1's ETH balance.
        uint256 userBalanceBefore = _user.balance;

        vm.prank(_user);
        uint256 reclaimed = _terminal1.cashOutTokensOf({
            holder: _user,
            projectId: _projectId,
            cashOutCount: userEthTokens / 4, // cash out 25% of tokens from ETH payment
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_user),
            metadata: new bytes(0)
        });

        // Reclaim amount should be > 0.
        assertGt(reclaimed, 0, "should reclaim some ETH");

        // Verify the user received ETH.
        assertGt(_user.balance, userBalanceBefore, "user balance should increase");
    }

    /// @notice Cash out from terminal 1 cannot extract more ETH than terminal 1 holds,
    /// even with useTotalSurplusForCashOuts enabled.
    function test_cashOutCannotExceedTerminalBalance() public {
        uint256 ethAmount = 1 ether;
        uint256 usdcAmount = 20_000e6; // $20,000 = 10 ETH -- much more value than in terminal 1

        uint256 userEthTokens = _payEth(_user, ethAmount);
        _payUsdc(_user, usdcAmount);

        // The total surplus in ETH terms is ~11 ETH, but terminal 1 only holds 1 ETH.
        // Cashing out all tokens from terminal 1 should be bounded by the terminal's ETH balance.
        // With cashOutTaxRate=0 and useTotalSurplusForCashOuts=true, the reclaim amount
        // = totalSurplus * cashOutCount / totalSupply.
        // The total token supply includes tokens from both payments.

        // Get total token balance.
        uint256 totalTokenBalance = _tokens.totalBalanceOf(_user, _projectId);
        assertGt(totalTokenBalance, userEthTokens, "total tokens should include USDC payment tokens");

        // Cash out a large fraction -- the reclaim may be limited by what terminal 1 actually holds.
        // If reclaimAmount + hookAmounts > terminal balance, the store should revert.
        // Let us try cashing out enough tokens that the calculated reclaim exceeds terminal 1's balance.
        // With 1 ETH in terminal 1 and ~11 ETH total surplus, cashing out all tokens
        // would try to reclaim ~11 ETH from a terminal that only has 1 ETH.

        vm.prank(_user);
        vm.expectRevert(); // Should revert with InadequateTerminalStoreBalance
        _terminal1.cashOutTokensOf({
            holder: _user,
            projectId: _projectId,
            cashOutCount: totalTokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_user),
            metadata: new bytes(0)
        });
    }

    /// @notice Surplus aggregation with price conversion rounding: small amounts.
    function test_surplusAggregationRounding() public {
        // Pay a very small amount of ETH.
        uint256 ethAmount = 1 wei;
        _payEth(_user, ethAmount);

        // Pay a very small amount of USDC.
        uint256 usdcAmount = 1; // 1e-6 USDC = $0.000001
        _payUsdc(_user, usdcAmount);

        // Total surplus should be >= the ETH amount (even if USDC rounds to 0 when converted).
        uint256 totalSurplus = jbTerminalStore().currentTotalSurplusOf(_projectId, 18, _nativeCurrency);
        assertGe(totalSurplus, ethAmount, "total surplus should be at least the ETH amount");
    }

    /// @notice Per-terminal balance tracking is independent across terminals.
    function test_perTerminalBalanceIndependence() public {
        uint256 ethAmount = 5 ether;
        uint256 usdcAmount = 3000e6;

        _payEth(_user, ethAmount);
        _payUsdc(_user, usdcAmount);

        // Terminal 1 balance (ETH) should be unaffected by terminal 2's USDC.
        uint256 t1EthBalance = jbTerminalStore().balanceOf(address(_terminal1), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(t1EthBalance, ethAmount, "terminal 1 ETH balance should match");

        // Terminal 2 balance (USDC) should be unaffected by terminal 1's ETH.
        uint256 t2UsdcBalance = jbTerminalStore().balanceOf(address(_terminal2), _projectId, address(_usdc));
        assertEq(t2UsdcBalance, usdcAmount, "terminal 2 USDC balance should match");

        // Terminal 1 should have no USDC balance.
        uint256 t1UsdcBalance = jbTerminalStore().balanceOf(address(_terminal1), _projectId, address(_usdc));
        assertEq(t1UsdcBalance, 0, "terminal 1 should have no USDC balance");

        // Terminal 2 should have no ETH balance.
        uint256 t2EthBalance = jbTerminalStore().balanceOf(address(_terminal2), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(t2EthBalance, 0, "terminal 2 should have no ETH balance");
    }

    /// @notice Small cash out from terminal with most funds -- verifiable amount.
    function test_smallCashOutFromTerminalWithFunds() public {
        uint256 ethAmount = 10 ether;
        uint256 usdcAmount = 2000e6; // = 1 ETH equivalent

        uint256 userTokens = _payEth(_user, ethAmount);
        _payUsdc(_user, usdcAmount);

        // Cash out a small fraction of tokens from the ETH terminal.
        uint256 cashOutCount = userTokens / 100; // 1% of ETH-minted tokens

        uint256 balanceBefore = _user.balance;
        vm.prank(_user);
        uint256 reclaimed = _terminal1.cashOutTokensOf({
            holder: _user,
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_user),
            metadata: new bytes(0)
        });

        assertGt(reclaimed, 0, "should reclaim something for 1% cash out");
        assertEq(_user.balance - balanceBefore, reclaimed, "user balance increase should match reclaimed amount");

        // After small cash out, terminal 1 should still have most of its ETH.
        uint256 remainingBalance =
            jbTerminalStore().balanceOf(address(_terminal1), _projectId, JBConstants.NATIVE_TOKEN);
        assertGt(remainingBalance, 9 ether, "most of the ETH should remain");
    }

    /// @notice Total surplus query from terminal store matches sum of individual terminal surpluses.
    function test_totalSurplusConsistency() public {
        uint256 ethAmount = 3 ether;
        uint256 usdcAmount = 6000e6; // $6000 = 3 ETH

        _payEth(_user, ethAmount);
        _payUsdc(_user, usdcAmount);

        // Get individual surpluses in ETH terms.
        JBAccountingContext[] memory ethCtx = new JBAccountingContext[](1);
        ethCtx[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});
        uint256 t1Surplus = _terminal1.currentSurplusOf(_projectId, new address[](0), 18, _nativeCurrency);

        JBAccountingContext[] memory usdcCtx = new JBAccountingContext[](1);
        usdcCtx[0] = JBAccountingContext({token: address(_usdc), decimals: 6, currency: _usdcCurrency});
        // Get terminal 2 surplus in ETH terms.
        uint256 t2SurplusInEth = _terminal2.currentSurplusOf(_projectId, new address[](0), 18, _nativeCurrency);

        // Get total surplus from the store.
        uint256 totalSurplus = jbTerminalStore().currentTotalSurplusOf(_projectId, 18, _nativeCurrency);

        // Total should equal sum of individual surpluses (both converted to ETH).
        assertEq(totalSurplus, t1Surplus + t2SurplusInEth, "total surplus should equal sum of terminal surpluses");
    }

    receive() external payable {}
}
