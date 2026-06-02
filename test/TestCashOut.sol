// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {JBCashOuts} from "../src/libraries/JBCashOuts.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {mul as UD60x18mul, unwrap as UD60x18unwrap, wrap as UD60x18wrap} from "@prb/math/src/UD60x18.sol";

// Projects can issue a token, be paid to receieve claimed tokens,  burn some of the claimed tokens, cash out the rest
// of
// tokens
contract TestCashOut_Local is TestBaseWorkflow {
    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    JBTokens private _tokens;
    uint112 private _weight;
    JBRulesetMetadata _metadata;
    uint256 private _projectId;
    address private _projectOwner;
    address private _beneficiary;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();
        _weight = 1000 * 10 ** 18;
        _metadata = JBRulesetMetadata({
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
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = _weight;
        _rulesetConfig[0].weightCutPercent = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _tokensToAccept});

        // Create a first project to collect fees.
        _controller.launchProjectFor({
            owner: address(420), // Random.
            projectUri: "whatever",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
            memo: ""
        });

        // Create the project to test.
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "myIPFSHash",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });
    }

    function testCashOut(uint256 _tokenAmountToCashOut) external {
        uint112 _nativePayAmount = 10 ether;

        // Issue the project's tokens.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "TestName", "TestSymbol", bytes32(0));

        // Pay the project.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary has a balance of project tokens.
        uint256 _beneficiaryTokenBalance =
            UD60x18unwrap(UD60x18mul(UD60x18wrap(_nativePayAmount), UD60x18wrap(_weight)));
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // Make sure the native token balance in terminal is up to date.
        uint256 _nativeTerminalBalance = _nativePayAmount;
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN),
            _nativeTerminalBalance
        );

        // Fuzz 1 to full balance cash out.
        _tokenAmountToCashOut = bound(_tokenAmountToCashOut, 1, _beneficiaryTokenBalance);

        // Get the expected gross per a different view.
        uint256 _grossPerReclaimable = jbTerminalStore()
            .currentReclaimableSurplusOf(
                _projectId,
                _tokenAmountToCashOut,
                new IJBTerminal[](0),
                new address[](0),
                18,
                uint32(uint160(JBConstants.NATIVE_TOKEN))
            );

        // Test: cash out.
        vm.prank(_beneficiary);
        uint256 _nativeReclaimAmt = _terminal.cashOutTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            cashOutCount: _tokenAmountToCashOut,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        // Keep a reference to the expected amount cashed out.
        uint256 _grossCashedOut = mulDiv(
            mulDiv(_nativeTerminalBalance, _tokenAmountToCashOut, _beneficiaryTokenBalance),
            _metadata.cashOutTaxRate
                + mulDiv(
                    _tokenAmountToCashOut,
                    JBConstants.MAX_CASH_OUT_TAX_RATE - _metadata.cashOutTaxRate,
                    _beneficiaryTokenBalance
                ),
            JBConstants.MAX_CASH_OUT_TAX_RATE
        );

        // Ensure currentReclaimable is correct.
        assertEq(_grossCashedOut, _grossPerReclaimable);

        // Compute the fee taken.
        uint256 _fee = mulDiv(_grossCashedOut, 25_000_000, 1_000_000_000); // 2.5% fee

        // Compute the net amount received, still in project.
        uint256 _netReceived = _grossCashedOut - _fee;

        // Make sure the correct amount was returned (2 wei precision).
        assertApproxEqAbs(_nativeReclaimAmt, _netReceived, 2, "incorrect amount returned");

        // Make sure the beneficiary received correct amount of native tokens.
        assertEq(payable(_beneficiary).balance, _nativeReclaimAmt);

        // Make sure the beneficiary has correct amount of tokens.
        assertEq(
            _tokens.totalBalanceOf(_beneficiary, _projectId),
            _beneficiaryTokenBalance - _tokenAmountToCashOut,
            "incorrect beneficiary balance"
        );

        // Make sure the native token balance in terminal should be up to date (with 1 wei precision).
        assertApproxEqAbs(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN),
            _nativeTerminalBalance - _grossCashedOut,
            1
        );
    }

    function testCashOutCountBoundaryTable() external {
        uint256 _nativePayAmount = 10 ether;

        // Issue an ERC-20 before paying so the setup matches the user-facing tokenized project path.
        vm.prank(_projectOwner);
        _controller.deployERC20For({projectId: _projectId, name: "TestName", symbol: "TestSymbol", salt: bytes32(0)});

        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        uint256 _totalSupply = _tokens.totalSupplyOf(_projectId);
        assertEq(_totalSupply, _tokens.totalBalanceOf(_beneficiary, _projectId));

        // These exact counts are easy for fuzzing to miss but define the terminal/store boundary behavior.
        _assertCashOutPreview({cashOutCount: 0, surplus: _nativePayAmount, totalSupply: _totalSupply});
        _assertCashOutPreview({cashOutCount: 1, surplus: _nativePayAmount, totalSupply: _totalSupply});
        _assertCashOutPreview({cashOutCount: _totalSupply / 2, surplus: _nativePayAmount, totalSupply: _totalSupply});
        _assertCashOutPreview({cashOutCount: _totalSupply - 1, surplus: _nativePayAmount, totalSupply: _totalSupply});
        _assertCashOutPreview({cashOutCount: _totalSupply, surplus: _nativePayAmount, totalSupply: _totalSupply});

        // Preview must reject counts above effective supply before any burn or token transfer is attempted.
        _expectCashOutPreviewInsufficientTokens({cashOutCount: _totalSupply + 1, totalSupply: _totalSupply});
        _expectCashOutPreviewInsufficientTokens({cashOutCount: type(uint256).max, totalSupply: _totalSupply});
    }

    function _assertCashOutPreview(uint256 cashOutCount, uint256 surplus, uint256 totalSupply) internal view {
        (, uint256 _previewReclaimAmount,,) = _terminal.previewCashOutFrom({
            holder: _beneficiary,
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        uint256 _expectedReclaimAmount = JBCashOuts.cashOutFrom({
            surplus: surplus,
            cashOutCount: cashOutCount,
            totalSupply: totalSupply,
            cashOutTaxRate: _metadata.cashOutTaxRate
        });

        assertEq(_previewReclaimAmount, _expectedReclaimAmount);
    }

    function _expectCashOutPreviewInsufficientTokens(uint256 cashOutCount, uint256 totalSupply) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                JBTerminalStore.JBTerminalStore_InsufficientTokens.selector, cashOutCount, totalSupply
            )
        );
        _terminal.previewCashOutFrom({
            holder: _beneficiary,
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });
    }
}
