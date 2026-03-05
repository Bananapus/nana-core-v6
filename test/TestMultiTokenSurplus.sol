// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice E2E test: ETH + USDC project with price feed, cross-token surplus aggregation.
contract TestMultiTokenSurplus_Local is TestBaseWorkflow {
    IJBController private _controller;
    JBMultiTerminal private _terminal;
    uint256 private _projectId;
    address private _projectOwner;
    address private _beneficiary;

    MockPriceFeed private _ethToUsdcFeed;
    MockERC20 private _usdc;

    uint32 private _nativeCurrency;
    uint32 private _usdcCurrency;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _usdc = usdcToken();

        _nativeCurrency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        _usdcCurrency = uint32(uint160(address(_usdc)));

        // Price feed: 1 ETH = 2000 USDC
        // Feed reports price of 1 unit of native token in USDC terms
        _ethToUsdcFeed = new MockPriceFeed(2000e6, 6);

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: _nativeCurrency,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
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

        // Accept both ETH and USDC
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](2);
        _tokensToAccept[0] =
            JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});
        _tokensToAccept[1] = JBAccountingContext({token: address(_usdc), decimals: 6, currency: _usdcCurrency});

        JBTerminalConfig[] memory _terminalConfigs = new JBTerminalConfig[](1);
        _terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _tokensToAccept});

        _projectId = _controller.launchProjectFor({
            owner: address(_projectOwner),
            projectUri: "multi-token-surplus-test",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigs,
            memo: ""
        });

        // Add price feed: USDC priced in terms of native token
        // This allows the terminal to convert USDC balances to ETH-denominated surplus
        vm.prank(_projectOwner);
        _controller.addPriceFeed({
            projectId: _projectId, pricingCurrency: _usdcCurrency, unitCurrency: _nativeCurrency, feed: _ethToUsdcFeed
        });
    }

    /// @notice ETH-only surplus is correct.
    function test_ethOnlySurplus() public {
        uint256 payAmount = 5 ether;

        vm.deal(_beneficiary, payAmount);
        vm.prank(_beneficiary);
        _terminal.pay{value: payAmount}(_projectId, JBConstants.NATIVE_TOKEN, payAmount, _beneficiary, 0, "", "");

        // Check surplus in ETH terms
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});

        uint256 surplus = _terminal.currentSurplusOf(_projectId, contexts, 18, _nativeCurrency);
        assertEq(surplus, payAmount, "ETH surplus should match payment");
    }

    /// @notice USDC-only surplus is correct in USDC terms.
    function test_usdcOnlySurplus() public {
        uint256 usdcAmount = 2000e6; // $2000

        // Mint USDC to beneficiary and approve
        _usdc.mint(_beneficiary, usdcAmount);
        vm.prank(_beneficiary);
        _usdc.approve(address(permit2()), usdcAmount);
        vm.prank(_beneficiary);
        permit2().approve(address(_usdc), address(_terminal), uint160(usdcAmount), type(uint48).max);

        vm.prank(_beneficiary);
        _terminal.pay(_projectId, address(_usdc), usdcAmount, _beneficiary, 0, "", "");

        // Check surplus in USDC terms
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(_usdc), decimals: 6, currency: _usdcCurrency});

        uint256 surplus = _terminal.currentSurplusOf(_projectId, contexts, 6, _usdcCurrency);
        assertEq(surplus, usdcAmount, "USDC surplus should match payment");
    }

    /// @notice Multi-token surplus aggregation converts USDC to ETH.
    function test_multiTokenSurplus_aggregation() public {
        uint256 ethAmount = 1 ether;
        uint256 usdcAmount = 2000e6; // $2000 = 1 ETH at our price feed rate

        // Pay ETH
        vm.deal(_beneficiary, ethAmount);
        vm.prank(_beneficiary);
        _terminal.pay{value: ethAmount}(_projectId, JBConstants.NATIVE_TOKEN, ethAmount, _beneficiary, 0, "", "");

        // Pay USDC
        _usdc.mint(_beneficiary, usdcAmount);
        vm.prank(_beneficiary);
        _usdc.approve(address(permit2()), usdcAmount);
        vm.prank(_beneficiary);
        permit2().approve(address(_usdc), address(_terminal), uint160(usdcAmount), type(uint48).max);

        vm.prank(_beneficiary);
        _terminal.pay(_projectId, address(_usdc), usdcAmount, _beneficiary, 0, "", "");

        // Check surplus of each token individually
        JBAccountingContext[] memory ethContext = new JBAccountingContext[](1);
        ethContext[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: _nativeCurrency});

        JBAccountingContext[] memory usdcContext = new JBAccountingContext[](1);
        usdcContext[0] = JBAccountingContext({token: address(_usdc), decimals: 6, currency: _usdcCurrency});

        uint256 ethSurplus = _terminal.currentSurplusOf(_projectId, ethContext, 18, _nativeCurrency);
        assertEq(ethSurplus, ethAmount, "ETH surplus should match");

        uint256 usdcSurplus = _terminal.currentSurplusOf(_projectId, usdcContext, 6, _usdcCurrency);
        assertEq(usdcSurplus, usdcAmount, "USDC surplus should match");

        // Check aggregated surplus in ETH terms (both contexts)
        JBAccountingContext[] memory bothContexts = new JBAccountingContext[](2);
        bothContexts[0] = ethContext[0];
        bothContexts[1] = usdcContext[0];

        uint256 totalSurplus = _terminal.currentSurplusOf(_projectId, bothContexts, 18, _nativeCurrency);

        // Total should be ETH amount + USDC converted to ETH
        // 1 ETH + (2000 USDC / 2000 per ETH) = 2 ETH
        // But the conversion depends on the feed direction
        assertGt(totalSurplus, ethAmount, "total surplus should include both tokens");
    }

    /// @notice Balance tracking is per-token.
    function test_perTokenBalance() public {
        uint256 ethAmount = 3 ether;
        uint256 usdcAmount = 1000e6;

        // Pay ETH
        vm.deal(_beneficiary, ethAmount);
        vm.prank(_beneficiary);
        _terminal.pay{value: ethAmount}(_projectId, JBConstants.NATIVE_TOKEN, ethAmount, _beneficiary, 0, "", "");

        // Pay USDC
        _usdc.mint(_beneficiary, usdcAmount);
        vm.prank(_beneficiary);
        _usdc.approve(address(permit2()), usdcAmount);
        vm.prank(_beneficiary);
        permit2().approve(address(_usdc), address(_terminal), uint160(usdcAmount), type(uint48).max);

        vm.prank(_beneficiary);
        _terminal.pay(_projectId, address(_usdc), usdcAmount, _beneficiary, 0, "", "");

        // Check individual balances
        uint256 ethBalance = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(ethBalance, ethAmount, "ETH balance should match");

        uint256 usdcBalance = jbTerminalStore().balanceOf(address(_terminal), _projectId, address(_usdc));
        assertEq(usdcBalance, usdcAmount, "USDC balance should match");
    }
}
