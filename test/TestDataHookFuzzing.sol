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
import {JBAfterCashOutRecordedContext} from "../src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "../src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "../src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "../src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "../src/structs/JBCashOutHookSpecification.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Real data hook used to prove terminal-store pre-record context and terminal post-record hook callbacks line
/// up in one flow.
contract RecordingRulesetDataHook is IJBRulesetDataHook, IJBPayHook, IJBCashOutHook {
    error RecordingRulesetDataHook_AfterCashOutContextMismatch();
    error RecordingRulesetDataHook_AfterPayContextMismatch();
    error RecordingRulesetDataHook_BeforeCashOutContextMismatch();
    error RecordingRulesetDataHook_BeforePayContextMismatch();

    uint256 public cashOutHookCallCount;
    uint256 public lastCashOutHookForwardedValue;
    uint256 public lastCashOutHookMsgValue;
    uint256 public lastCashOutHookReclaimedValue;
    uint256 public lastPayHookForwardedValue;
    uint256 public lastPayHookMsgValue;
    uint256 public lastPayHookNewlyIssuedTokenCount;
    uint256 public payHookCallCount;

    address internal _beneficiary;
    uint256 internal _cashOutCount;
    uint256 internal _cashOutForwardAmount;
    bytes internal _cashOutHookMetadata;
    bytes internal _cashOutMetadata;
    uint256 internal _cashOutReclaimedAmount;
    uint256 internal _cashOutSurplusValue;
    uint256 internal _cashOutTotalSupply;
    address internal _holder;
    uint256 internal _payAmount;
    uint256 internal _payForwardAmount;
    bytes internal _payHookMetadata;
    bytes internal _payMetadata;
    uint256 internal _payTokenCount;
    uint256 internal _payWeight;
    uint256 internal _projectId;
    address internal _terminal;

    /// @notice Called by the terminal after a cash out has been recorded and hook funds have been forwarded.
    /// @dev This is intentionally strict: any context drift between `JBTerminalStore.recordCashOutFor(...)` and
    /// `JBMultiTerminal._fulfillCashOutHookSpecificationsFor(...)` should fail the test at the callback boundary.
    /// @param context The post-record cash out context passed by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        if (
            msg.sender != _terminal || msg.value != _cashOutForwardAmount || context.holder != _holder
                || context.projectId != _projectId || context.cashOutCount != _cashOutCount
                || context.reclaimedAmount.token != JBConstants.NATIVE_TOKEN
                || context.reclaimedAmount.value != _cashOutReclaimedAmount
                || context.forwardedAmount.token != JBConstants.NATIVE_TOKEN
                || context.forwardedAmount.value != _cashOutForwardAmount || context.beneficiary != _beneficiary
                || keccak256(context.hookMetadata) != keccak256(_cashOutHookMetadata)
                || keccak256(context.cashOutMetadata) != keccak256(_cashOutMetadata)
        ) revert RecordingRulesetDataHook_AfterCashOutContextMismatch();

        cashOutHookCallCount += 1;
        lastCashOutHookForwardedValue = context.forwardedAmount.value;
        lastCashOutHookMsgValue = msg.value;
        lastCashOutHookReclaimedValue = context.reclaimedAmount.value;
    }

    /// @notice Called by the terminal after a payment has been recorded and hook funds have been forwarded.
    /// @dev Validates both the ETH transfer and the context fields that the downstream hook would rely on.
    /// @param context The post-record pay context passed by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        if (
            msg.sender != _terminal || msg.value != _payForwardAmount || context.payer != _holder
                || context.projectId != _projectId || context.amount.token != JBConstants.NATIVE_TOKEN
                || context.amount.value != _payAmount || context.forwardedAmount.token != JBConstants.NATIVE_TOKEN
                || context.forwardedAmount.value != _payForwardAmount || context.weight != _payWeight
                || context.newlyIssuedTokenCount != _payTokenCount || context.beneficiary != _beneficiary
                || keccak256(context.hookMetadata) != keccak256(_payHookMetadata)
                || keccak256(context.payerMetadata) != keccak256(_payMetadata)
        ) revert RecordingRulesetDataHook_AfterPayContextMismatch();

        payHookCallCount += 1;
        lastPayHookForwardedValue = context.forwardedAmount.value;
        lastPayHookMsgValue = msg.value;
        lastPayHookNewlyIssuedTokenCount = context.newlyIssuedTokenCount;
    }

    /// @notice Returns cash out pricing and hook specifications after validating the pre-record terminal context.
    /// @dev Returning the incoming cash out count, total supply, and surplus keeps the bonding curve unchanged; the
    /// only mutation this hook requests is a concrete cashout-hook forward.
    /// @param context The pre-record cash out context from the terminal store.
    /// @return cashOutTaxRate The cash out tax rate to use.
    /// @return effectiveCashOutCount The cash out count to price against.
    /// @return effectiveTotalSupply The total supply to price against.
    /// @return effectiveSurplusValue The surplus value to price against.
    /// @return hookSpecifications The cashout-hook forward requested by this data hook.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        if (
            context.terminal != _terminal || context.holder != _holder || context.projectId != _projectId
                || context.cashOutCount != _cashOutCount || context.totalSupply != _cashOutTotalSupply
                || context.surplus.token != JBConstants.NATIVE_TOKEN || context.surplus.value != _cashOutSurplusValue
                || context.surplus.decimals != 18
                || context.surplus.currency != uint32(uint160(JBConstants.NATIVE_TOKEN))
                || context.scopeCashOutsToLocalBalances || context.cashOutTaxRate != 0 || context.beneficiaryIsFeeless
                || keccak256(context.metadata) != keccak256(_cashOutMetadata)
        ) revert RecordingRulesetDataHook_BeforeCashOutContextMismatch();

        cashOutTaxRate = 0;
        effectiveCashOutCount = context.cashOutCount;
        effectiveTotalSupply = context.totalSupply;
        effectiveSurplusValue = context.surplus.value;
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)),
            noop: false,
            amount: _cashOutForwardAmount,
            metadata: _cashOutHookMetadata
        });
    }

    /// @notice Returns a pay weight and hook specification after validating the pre-record terminal context.
    /// @dev This avoids `vm.mockCall` so the test proves an actual `IJBRulesetDataHook` implementation can drive an
    /// actual `IJBPayHook` callback with matching metadata and forwarded ETH.
    /// @param context The pre-record pay context from the terminal store.
    /// @return weight The weight to use for minting.
    /// @return hookSpecifications The pay-hook forward requested by this data hook.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        if (
            context.terminal != _terminal || context.payer != _holder || context.projectId != _projectId
                || context.beneficiary != _beneficiary || context.amount.token != JBConstants.NATIVE_TOKEN
                || context.amount.value != _payAmount || context.amount.decimals != 18
                || context.amount.currency != uint32(uint160(JBConstants.NATIVE_TOKEN)) || context.weight != _payWeight
                || context.reservedPercent != 0 || keccak256(context.metadata) != keccak256(_payMetadata)
        ) revert RecordingRulesetDataHook_BeforePayContextMismatch();

        weight = _payWeight;
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(address(this)), noop: false, amount: _payForwardAmount, metadata: _payHookMetadata
        });
    }

    /// @notice Configures the expected cash out context for the next cash out flow.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param cashOutForwardAmount The amount the data hook asks the terminal to forward to the cashout hook.
    /// @param cashOutHookMetadata The metadata the data hook sends to the cashout hook.
    /// @param cashOutMetadata The metadata supplied by the account cashing out.
    /// @param cashOutReclaimedAmount The net reclaim amount expected in the cashout hook callback.
    /// @param cashOutSurplusValue The surplus value expected in the pre-record cash out context.
    /// @param cashOutTotalSupply The total project token supply expected in the pre-record cash out context.
    /// @param beneficiary The beneficiary receiving the non-hook reclaim.
    function configureCashOut(
        uint256 cashOutCount,
        uint256 cashOutForwardAmount,
        bytes calldata cashOutHookMetadata,
        bytes calldata cashOutMetadata,
        uint256 cashOutReclaimedAmount,
        uint256 cashOutSurplusValue,
        uint256 cashOutTotalSupply,
        address beneficiary
    )
        external
    {
        _beneficiary = beneficiary;
        _cashOutCount = cashOutCount;
        _cashOutForwardAmount = cashOutForwardAmount;
        _cashOutHookMetadata = cashOutHookMetadata;
        _cashOutMetadata = cashOutMetadata;
        _cashOutReclaimedAmount = cashOutReclaimedAmount;
        _cashOutSurplusValue = cashOutSurplusValue;
        _cashOutTotalSupply = cashOutTotalSupply;
    }

    /// @notice Configures the expected pay context for the next pay flow.
    /// @param beneficiary The beneficiary receiving newly minted tokens.
    /// @param holder The payer, and later the holder cashing out.
    /// @param payAmount The amount paid into the project.
    /// @param payForwardAmount The amount the data hook asks the terminal to forward to the pay hook.
    /// @param payHookMetadata The metadata the data hook sends to the pay hook.
    /// @param payMetadata The metadata supplied by the payer.
    /// @param payTokenCount The beneficiary token count expected after minting.
    /// @param payWeight The weight the data hook returns to the terminal store.
    /// @param projectId The project using this data hook.
    /// @param terminal The terminal expected in the data hook context and hook callback.
    function configurePay(
        address beneficiary,
        address holder,
        uint256 payAmount,
        uint256 payForwardAmount,
        bytes calldata payHookMetadata,
        bytes calldata payMetadata,
        uint256 payTokenCount,
        uint256 payWeight,
        uint256 projectId,
        address terminal
    )
        external
    {
        _beneficiary = beneficiary;
        _holder = holder;
        _payAmount = payAmount;
        _payForwardAmount = payForwardAmount;
        _payHookMetadata = payHookMetadata;
        _payMetadata = payMetadata;
        _payTokenCount = payTokenCount;
        _payWeight = payWeight;
        _projectId = projectId;
        _terminal = terminal;
    }

    /// @notice This hook does not grant mint permissions.
    /// @return flag Always false.
    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool flag) {
        return false;
    }

    /// @notice Declares the hook interfaces used by the terminal.
    /// @param interfaceId The interface ID to check.
    /// @return flag Whether this contract supports the interface.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool flag) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IJBCashOutHook).interfaceId;
    }

    receive() external payable {}
}

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
            scopeCashOutsToLocalBalances: false,
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

    /// @notice A real data hook can return pay/cashout hooks while keeping terminal-store context and terminal
    /// callback context consistent.
    function test_dataHookCompositionForwardsRealPayAndCashOutHookContexts() public {
        RecordingRulesetDataHook hook = new RecordingRulesetDataHook();
        vm.label({account: address(hook), newLabel: "Recording Data Hook"});

        uint256 projectId = _launchProjectForDataHook({dataHook: IJBRulesetDataHook(address(hook))});

        (uint256 tokenCount, uint256 expectedSurplus, uint256 payForwardAmount) =
            _exerciseRealDataHookPay({hook: hook, projectId: projectId});

        _exerciseRealDataHookCashOut({
            hook: hook,
            projectId: projectId,
            tokenCount: tokenCount,
            expectedSurplus: expectedSurplus,
            payForwardAmount: payForwardAmount
        });
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
            noop: false,
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

        // Data hook returns: cashOutTaxRate=0, cashOutCount=half, custom totalSupply, local surplus, no hook specs.
        JBCashOutHookSpecification[] memory _emptyCashOutSpecs = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(0), cashOutCount, _hookTotalSupply, _payAmount, _emptyCashOutSpecs)
        );

        uint256 balanceBefore = address(this).balance;

        _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0),
            referralProjectId: 0
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
        _specs[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(_cashOutHook), noop: false, amount: _hookAmount, metadata: ""
        });

        // Override: cashOutTaxRate=0, half the tokens cashed out, original totalSupply.
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(0), cashOutCount, tokenBalance, _payAmount, _specs)
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
            metadata: new bytes(0),
            referralProjectId: 0
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
            scopeCashOutsToLocalBalances: false,
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
        _specs[0] =
            JBCashOutHookSpecification({hook: IJBCashOutHook(makeAddr("hook")), noop: false, amount: 1, metadata: ""});

        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(0), tokenBalance, tokenBalance, _payAmount, _specs)
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
            metadata: new bytes(0),
            referralProjectId: 0
        });
    }

    function _exerciseRealDataHookCashOut(
        RecordingRulesetDataHook hook,
        uint256 projectId,
        uint256 tokenCount,
        uint256 expectedSurplus,
        uint256 payForwardAmount
    )
        private
    {
        uint256 cashOutCount = tokenCount / 2;
        uint256 cashOutForwardAmount = 1 ether;
        bytes memory cashOutHookMetadata = hex"63617368486f6f6b";
        bytes memory cashOutMetadata = hex"636173686572";
        uint256 expectedReclaimAmount = expectedSurplus / 2;

        // Make the hook feeless so the test asserts exact cashout-hook forwarding. Without this, the terminal would
        // net the protocol fee out of the hook amount before the callback.
        vm.prank({msgSender: multisig()});
        jbFeelessAddresses().setFeelessAddress({addr: address(hook), flag: true});

        // The same real data hook now validates the cashout pricing context and asks the terminal to forward part of
        // the local surplus to a real cashout hook. The post-record callback checks the reclaim and forwarded amounts
        // after the terminal store has debited the project balance.
        hook.configureCashOut({
            cashOutCount: cashOutCount,
            cashOutForwardAmount: cashOutForwardAmount,
            cashOutHookMetadata: cashOutHookMetadata,
            cashOutMetadata: cashOutMetadata,
            cashOutReclaimedAmount: expectedReclaimAmount,
            cashOutSurplusValue: expectedSurplus,
            cashOutTotalSupply: tokenCount,
            beneficiary: address(this)
        });

        uint256 beneficiaryBalanceBefore = address(this).balance;
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: expectedReclaimAmount,
            beneficiary: payable(address(this)),
            metadata: cashOutMetadata,
            referralProjectId: 0
        });

        assertEq(reclaimAmount, expectedReclaimAmount, "cashout should use the data hook pricing values");
        assertEq(
            address(this).balance - beneficiaryBalanceBefore,
            expectedReclaimAmount,
            "beneficiary should receive the non-hook reclaim"
        );
        assertEq(hook.cashOutHookCallCount(), 1, "cashout hook should be called once");
        assertEq(
            hook.lastCashOutHookForwardedValue(),
            cashOutForwardAmount,
            "cashout hook context should carry forwarded value"
        );
        assertEq(hook.lastCashOutHookMsgValue(), cashOutForwardAmount, "cashout hook should receive forwarded ETH");
        assertEq(
            hook.lastCashOutHookReclaimedValue(),
            expectedReclaimAmount,
            "cashout hook context should carry beneficiary reclaim"
        );

        uint256 balanceAfterCashOut =
            jbTerminalStore().balanceOf(address(_terminal), projectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            balanceAfterCashOut,
            expectedSurplus - expectedReclaimAmount - cashOutForwardAmount,
            "cashout should debit both beneficiary reclaim and hook forward"
        );
        assertEq(
            address(hook).balance,
            payForwardAmount + cashOutForwardAmount,
            "hook should retain both forwarded native-token amounts"
        );
    }

    function _exerciseRealDataHookPay(
        RecordingRulesetDataHook hook,
        uint256 projectId
    )
        private
        returns (uint256 tokenCount, uint256 expectedSurplus, uint256 payForwardAmount)
    {
        // 10 ETH at weight 1000e18 mints 10,000 project tokens with 18 decimals.
        uint256 expectedTokenCount = 10_000 ether;

        // The data hook verifies the pre-record pay context, then asks the terminal to forward part of the payment
        // to itself as a real pay hook. This proves hook amount subtraction and callback metadata are exercised
        // through the production terminal/store path, not through a `vm.mockCall` shortcut.
        hook.configurePay({
            beneficiary: address(this),
            holder: address(this),
            payAmount: 10 ether,
            payForwardAmount: 2 ether,
            payHookMetadata: hex"706179486f6f6b",
            payMetadata: hex"7061796572",
            payTokenCount: expectedTokenCount,
            payWeight: _WEIGHT,
            projectId: projectId,
            terminal: address(_terminal)
        });

        vm.deal({account: address(this), newBalance: 10 ether});
        tokenCount = _terminal.pay{value: 10 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: address(this),
            minReturnedTokens: expectedTokenCount,
            memo: "real data hook pay",
            metadata: hex"7061796572"
        });

        assertEq(tokenCount, expectedTokenCount, "pay should mint using the data hook weight");
        assertEq(hook.payHookCallCount(), 1, "pay hook should be called once");
        assertEq(hook.lastPayHookForwardedValue(), 2 ether, "pay hook context should carry forwarded value");
        assertEq(hook.lastPayHookMsgValue(), 2 ether, "pay hook should receive forwarded ETH");
        assertEq(
            hook.lastPayHookNewlyIssuedTokenCount(),
            expectedTokenCount,
            "pay hook context should carry minted token count"
        );

        expectedSurplus = 8 ether;
        uint256 balanceAfterPay = jbTerminalStore().balanceOf(address(_terminal), projectId, JBConstants.NATIVE_TOKEN);
        assertEq(balanceAfterPay, expectedSurplus, "only the non-forwarded pay amount should reach project balance");
        assertEq(address(hook).balance, 2 ether, "pay hook should retain forwarded native token");

        payForwardAmount = 2 ether;
    }

    function _launchProjectForDataHook(IJBRulesetDataHook dataHook) private returns (uint256 projectId) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: true,
            useDataHookForCashOut: true,
            dataHook: address(dataHook),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = _WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: accountingContexts});

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "realDataHookProject",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        vm.prank({msgSender: _projectOwner});
        _controller.deployERC20For({projectId: projectId, name: "RealHookToken", symbol: "RHT", salt: bytes32(0)});
    }

    receive() external payable {}
    fallback() external payable {}
}
