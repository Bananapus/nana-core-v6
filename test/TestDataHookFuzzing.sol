// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBPayHook} from "../src/interfaces/IJBPayHook.sol";
import {IJBCashOutHook} from "../src/interfaces/IJBCashOutHook.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../src/interfaces/IJBRulesetDataHook.sol";
import {IJBTokens} from "../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../src/libraries/JBRulesetMetadataResolver.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../src/structs/JBCashOutHookSpecification.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Fuzzing tests for data hook composition edge cases in pay and cash out flows.
contract TestDataHookFuzzing_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint112 private constant _WEIGHT = 1000 * 10 ** 18;
    address private constant _DATA_HOOK = address(bytes20(keccak256("datahook")));

    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    IJBTokens private _tokens;
    address private _projectOwner;

    uint64 private _projectId;

    function setUp() public override {
        super.setUp();

        vm.label(_DATA_HOOK, "Data Hook");

        _controller = jbController();
        _projectOwner = multisig();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: true,
            useDataHookForCashOut: true,
            dataHook: _DATA_HOOK,
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = _WEIGHT;
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

        // Create fee project (project ID 1).
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "feeProject",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        // Create test project (project ID 2).
        _projectId = uint64(
            _controller.launchProjectFor({
                owner: _projectOwner,
                projectUri: "testProject",
                rulesetConfigurations: _rulesetConfig,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            })
        );

        // Deploy an ERC-20 token for the project.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "TestToken", "TT", bytes32(0));
    }

    /// @notice Fuzz: data hook returns weight=0 for pay, resulting in zero tokens minted.
    function testFuzz_payDataHookWeightZero(uint256 _payAmount) public {
        _payAmount = bound(_payAmount, 1, 100 ether);

        // Data hook returns weight = 0, no hook specifications.
        JBPayHookSpecification[] memory _emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), _emptySpecs)
        );

        vm.deal(address(this), _payAmount);
        uint256 tokensReceived = _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // With weight=0, no tokens should be minted.
        assertEq(tokensReceived, 0, "weight=0 should mint zero tokens");

        // But the balance should still increase (funds are still received).
        uint256 balance = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balance, _payAmount, "terminal balance should still increase");
    }

    /// @notice Fuzz: data hook returns a large weight for pay.
    function testFuzz_payDataHookLargeWeight(uint256 _payAmount, uint256 _hookWeight) public {
        _payAmount = bound(_payAmount, 1, 10 ether);
        // Bound weight so that _payAmount * weight / 10^18 does not overflow.
        _hookWeight = bound(_hookWeight, 1, type(uint256).max / _payAmount);

        JBPayHookSpecification[] memory _emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(_hookWeight, _emptySpecs)
        );

        vm.deal(address(this), _payAmount);
        uint256 tokensReceived = _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Token count = payAmount * weight / 10^18
        uint256 expectedTokens = mulDiv(_payAmount, _hookWeight, 10 ** 18);
        assertEq(tokensReceived, expectedTokens, "tokens should match weight calculation");
    }

    /// @notice Data hook returns empty hook specifications for pay -- funds go entirely to project balance.
    function testFuzz_payDataHookEmptySpecs(uint256 _payAmount) public {
        _payAmount = bound(_payAmount, 1, 50 ether);

        JBPayHookSpecification[] memory _emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(_WEIGHT), _emptySpecs)
        );

        vm.deal(address(this), _payAmount);
        _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 balance = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balance, _payAmount, "full amount should go to project balance with empty specs");
    }

    /// @notice Data hook returns pay hook specification amount exceeding payment value -- should revert.
    function testFuzz_payDataHookSpecExceedsPayment(uint256 _payAmount) public {
        _payAmount = bound(_payAmount, 1 ether, 10 ether);

        address _payHook = makeAddr("payHook");
        JBPayHookSpecification[] memory _specs = new JBPayHookSpecification[](1);
        _specs[0] = JBPayHookSpecification({
            hook: IJBPayHook(_payHook),
            amount: _payAmount + 1, // exceeds the paid amount
            metadata: ""
        });

        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(_WEIGHT), _specs)
        );

        vm.deal(address(this), _payAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBTerminalStore.JBTerminalStore_InvalidAmountToForwardHook.selector, _payAmount + 1, _payAmount
            )
        );
        _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Data hook overrides totalSupply for cash out to a smaller value, increasing per-token reclaim.
    function testFuzz_cashOutDataHookOverridesTotalSupply(uint256 _hookTotalSupply) public {
        uint256 _payAmount = 10 ether;

        // First, pay without data hook weight override (use the normal weight for minting).
        JBPayHookSpecification[] memory _emptyPaySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(_WEIGHT), _emptyPaySpecs)
        );

        vm.deal(address(this), _payAmount);
        uint256 tokenBalance = _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Bound totalSupply override: must be >= cashOutCount (we cash out half).
        uint256 cashOutCount = tokenBalance / 2;
        _hookTotalSupply = bound(_hookTotalSupply, cashOutCount, tokenBalance * 10);

        // Data hook returns: cashOutTaxRate=0, cashOutCount=half, custom totalSupply, no hook specs.
        JBCashOutHookSpecification[] memory _emptyCashOutSpecs = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(0), cashOutCount, _hookTotalSupply, _emptyCashOutSpecs)
        );

        uint256 balanceBefore = address(this).balance;

        _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0)
        });

        uint256 reclaimed = address(this).balance - balanceBefore;

        // With cashOutTaxRate=0, reclaim = surplus * cashOutCount / totalSupply.
        // Since there are no fees when cashOutTaxRate is 0, the full reclaimed amount should match.
        uint256 expectedReclaim = mulDiv(_payAmount, cashOutCount, _hookTotalSupply);
        assertEq(reclaimed, expectedReclaim, "reclaim should use overridden totalSupply");
    }

    /// @notice Data hook returns non-empty cash out hook specifications with valid amounts.
    function testFuzz_cashOutDataHookWithHookSpecs(uint256 _hookAmount) public {
        uint256 _payAmount = 10 ether;

        // Pay first.
        JBPayHookSpecification[] memory _emptyPaySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(_WEIGHT), _emptyPaySpecs)
        );

        vm.deal(address(this), _payAmount);
        uint256 tokenBalance = _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Cash out half the tokens so the reclaim is half the surplus.
        // With cashOutTaxRate=0: reclaim = surplus * cashOutCount / totalSupply = _payAmount / 2.
        // This leaves room for hook amounts within the remaining balance.
        uint256 cashOutCount = tokenBalance / 2;
        uint256 expectedReclaim = _payAmount / 2;

        // Hook amount + reclaim must not exceed the terminal balance (_payAmount).
        _hookAmount = bound(_hookAmount, 0, _payAmount - expectedReclaim);

        address _cashOutHook = makeAddr("cashOutHook");

        // Make the cash out hook feeless so we can predict exact amounts.
        vm.prank(multisig());
        jbFeelessAddresses().setFeelessAddress(_cashOutHook, true);

        JBCashOutHookSpecification[] memory _specs = new JBCashOutHookSpecification[](1);
        _specs[0] = JBCashOutHookSpecification({hook: IJBCashOutHook(_cashOutHook), amount: _hookAmount, metadata: ""});

        // Override: cashOutTaxRate=0, half the tokens cashed out, original totalSupply.
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(0), cashOutCount, tokenBalance, _specs)
        );

        // Mock the cash out hook call.
        vm.mockCall(_cashOutHook, abi.encodeWithSelector(IJBCashOutHook.afterCashOutRecordedWith.selector), "");

        _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0)
        });

        // After half cash out, balance should be reduced by reclaim + hookAmount.
        uint256 balanceAfter = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            balanceAfter,
            _payAmount - expectedReclaim - _hookAmount,
            "balance should be reduced by reclaim and hook amount"
        );
    }

    /// @notice Fuzz: interaction between data hook weight override and reserved percent.
    function testFuzz_payDataHookWeightWithReservedPercent(
        uint256 _payAmount,
        uint256 _hookWeight,
        uint256 _reservedPercent
    )
        public
    {
        _payAmount = bound(_payAmount, 1, 10 ether);
        _hookWeight = bound(_hookWeight, 1, type(uint256).max / _payAmount);

        // Create a separate project with a non-zero reserved percent.
        _reservedPercent = bound(_reservedPercent, 1, JBConstants.MAX_RESERVED_PERCENT);

        JBRulesetMetadata memory _metadata2 = JBRulesetMetadata({
            // forge-lint: disable-next-line(unsafe-typecast)
            reservedPercent: uint16(_reservedPercent),
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: _DATA_HOOK,
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig2 = new JBRulesetConfig[](1);
        _rulesetConfig2[0].mustStartAtOrAfter = 0;
        _rulesetConfig2[0].duration = 0;
        _rulesetConfig2[0].weight = _WEIGHT;
        _rulesetConfig2[0].weightCutPercent = 0;
        _rulesetConfig2[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig2[0].metadata = _metadata2;
        _rulesetConfig2[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig2[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _termCfg2 = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tok2 = new JBAccountingContext[](1);
        _tok2[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        _termCfg2[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _tok2});

        uint64 _project2 = uint64(
            _controller.launchProjectFor({
                owner: _projectOwner,
                projectUri: "reservedProject",
                rulesetConfigurations: _rulesetConfig2,
                terminalConfigurations: _termCfg2,
                memo: ""
            })
        );

        vm.prank(_projectOwner);
        _controller.deployERC20For(_project2, "Reserved", "RES", bytes32(0));

        // Mock data hook to return the fuzzed weight.
        JBPayHookSpecification[] memory _emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(_hookWeight, _emptySpecs)
        );

        vm.deal(address(this), _payAmount);
        uint256 tokensReceived = _terminal.pay{value: _payAmount}({
            projectId: _project2,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Total tokens minted = payAmount * weight / 10^18
        uint256 totalMinted = mulDiv(_payAmount, _hookWeight, 10 ** 18);
        // Beneficiary receives: totalMinted - reserved portion.
        uint256 reservedPortion = mulDiv(totalMinted, _reservedPercent, JBConstants.MAX_RESERVED_PERCENT);
        uint256 expectedBeneficiaryTokens = totalMinted - reservedPortion;

        // Allow 1 wei rounding tolerance from mulDiv arithmetic.
        assertApproxEqAbs(
            tokensReceived,
            expectedBeneficiaryTokens,
            1,
            "beneficiary tokens should reflect weight override minus reserved percent"
        );

        // Verify pending reserved tokens accumulated (also allow 1 wei rounding).
        uint256 pendingReserved = _controller.pendingReservedTokenBalanceOf(_project2);
        assertApproxEqAbs(
            pendingReserved, reservedPortion, 1, "reserved tokens should accumulate from data hook weight"
        );
    }

    /// @notice Cash out hook spec amount that, combined with reclaim, exceeds terminal balance should revert.
    function test_cashOutDataHookSpecExceedsBalance() public {
        uint256 _payAmount = 5 ether;

        // Pay first.
        JBPayHookSpecification[] memory _emptyPaySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(_WEIGHT), _emptyPaySpecs)
        );

        vm.deal(address(this), _payAmount);
        uint256 tokenBalance = _terminal.pay{value: _payAmount}({
            projectId: _projectId,
            amount: _payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Cash out all tokens. With cashOutTaxRate=0, reclaim = full surplus = _payAmount.
        // Set hook spec amount to 1 wei -- total = _payAmount + 1 which exceeds balance.
        JBCashOutHookSpecification[] memory _specs = new JBCashOutHookSpecification[](1);
        _specs[0] = JBCashOutHookSpecification({hook: IJBCashOutHook(makeAddr("hook")), amount: 1, metadata: ""});

        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(0), tokenBalance, tokenBalance, _specs)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBTerminalStore.JBTerminalStore_InadequateTerminalStoreBalance.selector, _payAmount + 1, _payAmount
            )
        );
        _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: tokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0)
        });
    }

    receive() external payable {}
    fallback() external payable {}
}
