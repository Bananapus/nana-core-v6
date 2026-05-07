// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBPayHook} from "../src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../src/interfaces/IJBRulesetDataHook.sol";
import {IJBSplitHook} from "../src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Tests for three regression fixes: and .
/// Saturating subtraction in _tokenSurplusFrom prevents underflow when usedPayoutLimit > payoutLimit.amount.
/// _capFeeFreeSurplus after _efficientPay in executePayout caps fee-free surplus at STORE.balanceOf.
/// _capFeeFreeSurplus after hook fulfillment in _cashOutTokensOf caps fee-free surplus at remaining balance.
contract RegressionFixesTest is TestBaseWorkflow {
    // --- Core protocol references ---
    IJBController private _controller;
    JBMultiTerminal private _terminal;
    JBTerminalStore private _store;
    JBTokens private _tokens;
    address private _projectOwner;

    // Token issuance weight: 1000 tokens per ETH.
    uint112 private constant WEIGHT = 1000 * 10 ** 18;

    // Storage slot index for _feeFreeSurplusOf in JBMultiTerminal.
    // This is the first state variable in the contract (slot 0).
    uint256 private constant FEE_FREE_SURPLUS_SLOT = 0;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _terminal = jbMultiTerminal();
        _store = jbTerminalStore();
        _tokens = jbTokens();
        _projectOwner = multisig();
    }

    // ==========================================
    // Saturating subtraction in _tokenSurplusFrom
    // ==========================================

    /// @notice When a new ruleset activates with a lower payout limit than what was already used under a previous
    /// ruleset (same cycle number), `currentSurplusOf` must not revert. The saturating subtraction clamps
    /// (used - limit) to zero instead of underflowing.
    /// @dev Setup:
    ///   1. Launch a project with duration=1 day and a high payout limit (10 ETH).
    ///   2. Pay in and use some of the payout limit (5 ETH).
    ///   3. Queue a new ruleset with a much lower payout limit (1 ETH) and no approval hook (takes effect immediately
    ///      as the replacement for the next cycle derived from the queued config).
    ///   4. Warp forward to the next cycle so the new ruleset activates. The usedPayoutLimitOf from the previous cycle
    ///      is keyed by cycleNumber, so the new cycle starts fresh. However, if the new ruleset had duration=0 and
    ///      replaced mid-cycle, the used amount could exceed the new limit.
    ///
    ///   NOTE: In practice, triggering usedPayoutLimit > payoutLimit.amount is difficult because:
    ///   - For cycling rulesets (duration > 0), usedPayoutLimitOf resets each cycle.
    ///   - For duration=0 rulesets, queueing a replacement takes effect immediately with cycleNumber=1.
    ///   The saturating subtraction is defensive coding that prevents edge cases from DOS-ing the view function.
    ///   This test verifies the view function works correctly under normal conditions and does not revert.
    function test_F5_currentSurplusOfDoesNotRevertWithLowerPayoutLimit() external {
        // --- Fee project (project #1) ---
        _launchFeeProject();

        // --- Main project: duration=1 day, high payout limit ---
        uint224 highPayoutLimit = 10 ether;
        uint32 cycleDuration = 1 days;

        JBFundAccessLimitGroup[] memory fundAccess = _makeFundAccessLimitGroup(highPayoutLimit);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0] = _makeRulesetConfig({
            duration: cycleDuration,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: fundAccess
        });

        JBTerminalConfig[] memory termConfigs = _makeTerminalConfig();

        uint256 projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "f5-project",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: termConfigs,
            memo: ""
        });

        // Pay 20 ETH into the project.
        address payer = makeAddr("f5-payer");
        vm.deal(payer, 20 ether);
        vm.prank(payer);
        _terminal.pay{value: 20 ether}({
            projectId: projectId,
            amount: 20 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Use 5 ETH of the 10 ETH payout limit.
        _terminal.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Queue a new ruleset with a much lower payout limit (1 ETH).
        JBFundAccessLimitGroup[] memory lowFundAccess = _makeFundAccessLimitGroup(1 ether);
        JBRulesetConfig[] memory newRulesetConfig = new JBRulesetConfig[](1);
        newRulesetConfig[0] = _makeRulesetConfig({
            duration: cycleDuration,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: lowFundAccess
        });

        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: projectId, rulesetConfigurations: newRulesetConfig, memo: ""});

        // Warp to next cycle so the new ruleset activates.
        vm.warp(block.timestamp + cycleDuration);

        // KEY ASSERTION: currentSurplusOf must NOT revert.
        // If the saturating subtraction were missing and somehow used > limit, this would underflow.
        // Even though in this specific setup the cycle resets used to 0, this test verifies the view
        // function works correctly after a payout limit reduction.
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(_terminal));
        address[] memory tokensToCheck = new address[](1);
        tokensToCheck[0] = JBConstants.NATIVE_TOKEN;

        uint256 surplus = _store.currentSurplusOf({
            projectId: projectId,
            terminals: terminals,
            tokens: tokensToCheck,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // After paying out 5 ETH from 20 ETH, balance is 15 ETH. New payout limit is 1 ETH.
        // Surplus = balance - payoutLimitRemaining = 15 ETH - 1 ETH = 14 ETH.
        assertEq(surplus, 14 ether, "Surplus should be balance minus new (lower) payout limit");
    }

    /// @notice Verify that currentSurplusOf does not revert when the project has zero payout limits in the new ruleset
    /// (meaning all balance is surplus). This is a simpler version of the scenario.
    function test_F5_currentSurplusOfWithZeroPayoutLimit() external {
        // Fee project.
        _launchFeeProject();

        // Launch project with payout limit, use it, then queue ruleset with no limits.
        uint224 payoutLimit = 5 ether;
        JBFundAccessLimitGroup[] memory fundAccess = _makeFundAccessLimitGroup(payoutLimit);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0] = _makeRulesetConfig({
            duration: 1 days,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: fundAccess
        });

        uint256 projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "f5-zero-limit",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });

        // Pay in and use the full payout limit.
        address payer = makeAddr("f5-payer2");
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        _terminal.pay{value: 10 ether}({
            projectId: projectId,
            amount: 10 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        _terminal.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payoutLimit,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Queue a new ruleset with zero payout limits (all balance is surplus).
        JBRulesetConfig[] memory newRulesetConfig = new JBRulesetConfig[](1);
        newRulesetConfig[0] = _makeRulesetConfig({
            duration: 1 days,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: projectId, rulesetConfigurations: newRulesetConfig, memo: ""});

        // Warp to next cycle.
        vm.warp(block.timestamp + 1 days);

        // currentSurplusOf must not revert. With zero limits, surplus = entire balance.
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(_terminal));
        address[] memory tokensToCheck = new address[](1);
        tokensToCheck[0] = JBConstants.NATIVE_TOKEN;

        uint256 surplus = _store.currentSurplusOf({
            projectId: projectId,
            terminals: terminals,
            tokens: tokensToCheck,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Balance after paying out 5 ETH from 10 ETH is 5 ETH. No payout limits = all surplus.
        assertEq(surplus, 5 ether, "Surplus should equal full remaining balance with zero payout limits");
    }

    // ==========================================
    // _capFeeFreeSurplus after _efficientPay in executePayout
    // ==========================================

    /// @notice When project A pays out to project B via a same-terminal split (not addToBalance), and project B has
    /// a data hook that diverts some of the payment to pay hooks, the store only records a partial balance increase.
    /// The fix ensures _feeFreeSurplusOf[B] is capped at STORE.balanceOf[B] after the pay.
    /// @dev Setup:
    ///   1. Project B: has a data hook that returns a pay hook specification diverting 50% of the payment.
    ///   2. Project A: has 100% split paying project B (same terminal, preferAddToBalance=false).
    ///   3. After sendPayoutsOf, verify _feeFreeSurplusOf[B] <= STORE.balanceOf[B].
    ///   4. Verify a subsequent zero-tax cashout from B charges correct fees (not overcharged).
    function test_feeFreeSurplusCappedWhenDataHookDivertsFunds() external {
        // --- Fee project ---
        _launchFeeProject();

        // --- Setup data hook and pay hook mocks ---
        address dataHook = makeAddr("data-hook-f3");
        address payHook = makeAddr("pay-hook-f3");

        // --- Project B: zero tax, data hook enabled for pay ---
        JBRulesetMetadata memory metadataB = _defaultMetadata();
        metadataB.useDataHookForPay = true;
        metadataB.dataHook = dataHook;

        JBRulesetConfig[] memory rulesetConfigB = new JBRulesetConfig[](1);
        rulesetConfigB[0] = _makeRulesetConfig({
            duration: 0,
            metadata: metadataB,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 projectIdB = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-b-f3",
            rulesetConfigurations: rulesetConfigB,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });

        // Deploy ERC-20 for project B so we can cash out.
        vm.prank(_projectOwner);
        _controller.deployERC20For(projectIdB, "ProjectB", "PB", bytes32(0));

        // --- Project A: 100% split to project B, preferAddToBalance=false ---
        uint224 payoutLimit = 10 ether;

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(projectIdB),
            beneficiary: payable(makeAddr("split-beneficiary")),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBFundAccessLimitGroup[] memory fundAccess = _makeFundAccessLimitGroup(payoutLimit);

        JBRulesetConfig[] memory rulesetConfigA = new JBRulesetConfig[](1);
        rulesetConfigA[0] = _makeRulesetConfig({
            duration: 0, metadata: _defaultMetadata(), splitGroups: splitGroups, fundAccessLimitGroups: fundAccess
        });

        uint256 projectIdA = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "project-a-f3",
            rulesetConfigurations: rulesetConfigA,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });

        // --- Mock the data hook to divert 50% of payments to a pay hook ---
        // The data hook returns a pay hook specification that takes 50% of the payment amount.
        // This means the store only records 50% as project B's balance.
        // We need to mock the data hook's beforePayRecordedWith and the pay hook's afterPayRecordedWith.
        // The data hook must also support ERC-165.

        // Mock ERC-165 support for IJBRulesetDataHook.
        vm.mockCall(dataHook, abi.encodeWithSelector(bytes4(keccak256("supportsInterface(bytes4)"))), abi.encode(true));

        // Mock hasMintPermissionFor to return false (not needed for this test).
        vm.mockCall(
            dataHook, abi.encodeWithSelector(IJBRulesetDataHook.hasMintPermissionFor.selector), abi.encode(false)
        );

        // The data hook will be called when project B receives the payment via _efficientPay.
        // We need to return a weight and pay hook specifications.
        // The pay hook spec diverts 50% of the payment to the pay hook.
        // We use a wildcard mock: any call to beforePayRecordedWith returns our response.
        //
        // NOTE: We can't predict the exact calldata because the `amount.value` depends on payout calculations.
        // So we use a broad mock that always returns the same response for any beforePayRecordedWith call.
        // The diversion amount will be calculated as 50% of whatever is sent.

        // We'll use a helper approach: mock the data hook to return weight=WEIGHT and a pay hook spec
        // that takes 5 ETH (half of the 10 ETH payout).
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({
            hook: IJBPayHook(payHook),
            noop: false,
            amount: 5 ether, // Divert 50% (5 ETH of the 10 ETH payout)
            metadata: new bytes(0)
        });

        vm.mockCall(
            dataHook,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(WEIGHT, hookSpecs)
        );

        // Mock the pay hook to accept the call without reverting.
        vm.mockCall(payHook, abi.encodeWithSelector(IJBPayHook.afterPayRecordedWith.selector), abi.encode());

        // --- Fund project A and send payouts ---
        address payer = makeAddr("f3-payer");
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        _terminal.pay{value: 10 ether}({
            projectId: projectIdA,
            amount: 10 ether,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Send payouts from project A: 10 ETH goes to project B via the split.
        // The data hook diverts 5 ETH to the pay hook, so STORE.balanceOf[B] only increases by 5 ETH.
        // But _feeFreeSurplusOf[B] was incremented by the full 10 ETH before the pay.
        // After the fix (), _capFeeFreeSurplus caps it at 5 ETH.
        _terminal.sendPayoutsOf({
            projectId: projectIdA,
            token: JBConstants.NATIVE_TOKEN,
            amount: payoutLimit,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // --- Verify invariant: _feeFreeSurplusOf[B] <= STORE.balanceOf[B] ---
        uint256 feeFreeSurplus = _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN);
        uint256 storeBalance = _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN);

        assertLe(
            feeFreeSurplus,
            storeBalance,
            "_feeFreeSurplusOf must not exceed STORE.balanceOf after data hook diverts funds"
        );

        // The store should have recorded only the portion not diverted to the pay hook.
        // With 10 ETH payout and 5 ETH diverted: store balance = 5 ETH.
        assertEq(storeBalance, 5 ether, "Store balance should be payment minus pay hook diversion");
        assertEq(feeFreeSurplus, 5 ether, "Fee-free surplus should be capped at store balance");

        // Verify zero-tax cashout charges correct fees via helper (avoids stack-too-deep).
        _verifyCashOutFees(projectIdB);
    }

    /// @dev Helper to verify cashout fees for (extracted to reduce stack depth).
    function _verifyCashOutFees(uint256 projectIdB) private {
        address splitBeneficiary = makeAddr("split-beneficiary");
        uint256 beneficiaryTokens = _tokens.totalBalanceOf(splitBeneficiary, projectIdB);

        if (beneficiaryTokens > 0) {
            vm.prank(splitBeneficiary);
            uint256 reclaimAmount = _terminal.cashOutTokensOf({
                holder: splitBeneficiary,
                projectId: projectIdB,
                cashOutCount: beneficiaryTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(splitBeneficiary),
                metadata: new bytes(0)
            });

            // With cashOutTaxRate = 0, the fee is charged on the feeFreeSurplus portion (5 ETH).
            // Fee = 2.5% of 5 ETH = 0.125 ETH. Net = 5 - 0.125 = 4.875 ETH.
            uint256 expectedFee = mulDiv(5 ether, 25, 1000);
            uint256 expectedNet = 5 ether - expectedFee;
            assertApproxEqAbs(
                reclaimAmount, expectedNet, 2, "Cashout should charge correct fee (2.5% of capped fee-free surplus)"
            );

            // Crucially, the fee should NOT be calculated on the full 10 ETH payout amount.
            // Without the fix, feeFreeSurplus would be 10 ETH but balance only 5 ETH,
            // causing an overcharge.
            assertLt(reclaimAmount, 5 ether, "Fee must be deducted from cashout");
        }
    }

    // ==========================================
    // _capFeeFreeSurplus after hook fulfillment in _cashOutTokensOf
    // ==========================================

    /// @notice After a cashout, _feeFreeSurplusOf is capped at the remaining STORE.balanceOf.
    /// This prevents stale _feeFreeSurplusOf from overcharging fees on subsequent zero-tax cashouts.
    /// @dev Setup:
    ///   1. Project A pays out to project B (same terminal) to build up _feeFreeSurplusOf[B].
    ///   2. Some users pay B directly (increasing balance but not fee-free surplus).
    ///   3. Cash out from B. After the cashout, _feeFreeSurplusOf[B] should be capped at remaining balance.
    ///   4. Subsequent direct-pay cashout should be fee-free (no remaining fee-free surplus).
    function test_F4_feeFreeSurplusCappedAfterCashOut() external {
        // --- Fee project ---
        _launchFeeProject();

        // Launch project B and project A with payout split to B.
        (uint256 projectIdA, uint256 projectIdB) = _launchPayoutPairForF4("f4-cap");

        // Step 1: Pay into project A and trigger payout to B.
        _payAndSendPayouts(projectIdA, 10 ether, 10 ether);

        // B now has: balance = 10 ETH, _feeFreeSurplusOf = 10 ETH.
        assertEq(
            _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN),
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            "Initial: fee-free surplus should equal balance"
        );

        // Step 2: Pay project B directly (increases balance but NOT fee-free surplus).
        _payProject(projectIdB, makeAddr("f4-direct-payer"), 10 ether);

        // B now has: balance = 20 ETH, _feeFreeSurplusOf = 10 ETH.
        assertEq(
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            20 ether,
            "Balance should be 20 ETH after direct payment"
        );

        // Step 3: Cash out half of the direct payer's tokens and verify the invariant.
        _cashOutHalfAndVerifyInvariant(projectIdB, makeAddr("f4-direct-payer"));

        // Step 4: Cash out remaining tokens and verify again.
        _cashOutRemainingAndVerifyInvariant(projectIdB, makeAddr("f4-direct-payer"));
    }

    /// @dev Cash out half of a holder's tokens and assert the fee-free surplus invariant.
    function _cashOutHalfAndVerifyInvariant(uint256 projectId, address holder) private {
        uint256 holderTokens = _tokens.totalBalanceOf(holder, projectId);
        uint256 halfTokens = holderTokens / 2;

        vm.prank(holder);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: halfTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: new bytes(0)
        });

        assertLe(
            _readFeeFreeSurplus(projectId, JBConstants.NATIVE_TOKEN),
            _store.balanceOf(address(_terminal), projectId, JBConstants.NATIVE_TOKEN),
            "_feeFreeSurplusOf must be <= STORE.balanceOf after partial cashout"
        );
        assertGt(reclaim, 0, "Partial cashout should reclaim something");
    }

    /// @dev Cash out remaining tokens for a holder and assert the fee-free surplus invariant.
    function _cashOutRemainingAndVerifyInvariant(uint256 projectId, address holder) private {
        uint256 remaining = _tokens.totalBalanceOf(holder, projectId);
        if (remaining == 0) return;

        vm.prank(holder);
        uint256 reclaim = _terminal.cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: remaining,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: new bytes(0)
        });

        assertLe(
            _readFeeFreeSurplus(projectId, JBConstants.NATIVE_TOKEN),
            _store.balanceOf(address(_terminal), projectId, JBConstants.NATIVE_TOKEN),
            "_feeFreeSurplusOf must be <= STORE.balanceOf after second cashout"
        );
        assertGt(reclaim, 0, "Second cashout should reclaim something");
    }

    /// @notice After a cashout that fully drains a project's balance, _feeFreeSurplusOf should be zero.
    /// This prevents overcharging fees on subsequent direct payments.
    function test_F4_feeFreeSurplusZeroAfterFullDrain() external {
        // Fee project.
        _launchFeeProject();

        // Launch project B and project A with payout split to B.
        (uint256 projectIdA, uint256 projectIdB) = _launchPayoutPairForF4("f4-drain");

        // Pay project A, send payouts to B.
        _payAndSendPayouts(projectIdA, 10 ether, 10 ether);

        // B: balance = 10 ETH, feeFreeSurplus = 10 ETH. No token holders in B (addToBalance doesn't mint).
        // To cash out, we need someone to pay B directly first so they get tokens.
        _payProject(projectIdB, makeAddr("f4-casher"), 10 ether);

        // B: balance = 20 ETH, feeFreeSurplus = 10 ETH.
        // Cash out ALL tokens (this is the only holder, so they get the full balance).
        _cashOutAll(projectIdB, makeAddr("f4-casher"));

        // After full drain, fee-free surplus should be capped at 0 (or whatever balance remains after fees).
        uint256 feeFreeSurplusAfterDrain = _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN);
        uint256 balanceAfterDrain = _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN);

        assertLe(feeFreeSurplusAfterDrain, balanceAfterDrain, "fee-free surplus must be <= balance after full drain");

        // Now pay B again directly. This should be fee-free since fee-free surplus was cleared.
        _payProject(projectIdB, makeAddr("f4-fresh-user"), 5 ether);

        // Cash out and verify it's fee-free.
        _verifyFeeFreeCashOut(projectIdB, makeAddr("f4-fresh-user"), 5 ether);
    }

    // ==========================================
    // Helper functions
    // ==========================================

    /// @dev Launch a pair of projects for the drain test: project B (zero tax) and project A (100% split to B).
    function _launchPayoutPairForF4(string memory label) private returns (uint256 projectIdA, uint256 projectIdB) {
        // Project B: zero tax.
        JBRulesetConfig[] memory rulesetConfigB = new JBRulesetConfig[](1);
        rulesetConfigB[0] = _makeRulesetConfig({
            duration: 0,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        projectIdB = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: string.concat("project-b-", label),
            rulesetConfigurations: rulesetConfigB,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });

        vm.prank(_projectOwner);
        _controller.deployERC20For(projectIdB, "PBDrain", "PBD", bytes32(0));

        // Project A: 100% split to B (addToBalance).
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: true,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(projectIdB),
            beneficiary: payable(address(0)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBFundAccessLimitGroup[] memory fundAccess = _makeFundAccessLimitGroup(10 ether);

        JBRulesetConfig[] memory rulesetConfigA = new JBRulesetConfig[](1);
        rulesetConfigA[0] = _makeRulesetConfig({
            duration: 0, metadata: _defaultMetadata(), splitGroups: splitGroups, fundAccessLimitGroups: fundAccess
        });

        projectIdA = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: string.concat("project-a-", label),
            rulesetConfigurations: rulesetConfigA,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    /// @dev Pay a project and then send payouts for the given amount.
    function _payAndSendPayouts(uint256 projectId, uint256 payAmount, uint224 payoutAmount) private {
        address payer = makeAddr("pay-and-send-payer");
        vm.deal(payer, payAmount);
        vm.prank(payer);
        _terminal.pay{value: payAmount}({
            projectId: projectId,
            amount: payAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        _terminal.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payoutAmount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });
    }

    /// @dev Pay ETH directly into a project as the given user.
    function _payProject(uint256 projectId, address user, uint256 amount) private {
        vm.deal(user, amount);
        vm.prank(user);
        _terminal.pay{value: amount}({
            projectId: projectId,
            amount: amount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    /// @dev Cash out all tokens for a holder from a project.
    function _cashOutAll(uint256 projectId, address holder) private {
        uint256 tokenBalance = _tokens.totalBalanceOf(holder, projectId);
        if (tokenBalance == 0) return;

        vm.prank(holder);
        _terminal.cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: tokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: new bytes(0)
        });
    }

    /// @dev Verify that cashing out all tokens returns the exact expected amount (fee-free).
    function _verifyFeeFreeCashOut(uint256 projectId, address holder, uint256 expectedAmount) private {
        uint256 tokenBalance = _tokens.totalBalanceOf(holder, projectId);
        assertGt(tokenBalance, 0, "Holder should have tokens");

        vm.prank(holder);
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: holder,
            projectId: projectId,
            cashOutCount: tokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(holder),
            metadata: new bytes(0)
        });

        assertEq(reclaimAmount, expectedAmount, "Direct payment cashout should be fee-free");
    }

    /// @notice Read `_feeFreeSurplusOf[projectId][token]` from JBMultiTerminal storage via vm.load.
    function _readFeeFreeSurplus(uint256 projectId, address token) private view returns (uint256) {
        bytes32 innerSlot = keccak256(abi.encode(projectId, FEE_FREE_SURPLUS_SLOT));
        bytes32 finalSlot = keccak256(abi.encode(token, innerSlot));
        return uint256(vm.load(address(_terminal), finalSlot));
    }

    /// @notice Launch the fee project (project #1) required by the protocol for fee collection.
    function _launchFeeProject() private returns (uint256) {
        JBRulesetConfig[] memory rc = new JBRulesetConfig[](1);
        rc[0] = _makeRulesetConfig({
            duration: 0,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        return _controller.launchProjectFor({
            owner: makeAddr("fee-owner"),
            projectUri: "fee-project",
            rulesetConfigurations: rc,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    /// @notice Build default ruleset metadata with zero tax rate and no data hook.
    function _defaultMetadata() private pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
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
    }

    /// @notice Build a standard terminal configuration accepting native ETH.
    function _makeTerminalConfig() private view returns (JBTerminalConfig[] memory termConfigs) {
        JBAccountingContext[] memory ctxs = new JBAccountingContext[](1);
        ctxs[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        termConfigs = new JBTerminalConfig[](1);
        termConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: ctxs});
    }

    /// @notice Build a fund access limit group with a single payout limit in native token.
    function _makeFundAccessLimitGroup(uint224 payoutLimitAmount)
        private
        view
        returns (JBFundAccessLimitGroup[] memory)
    {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: payoutLimitAmount, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        return groups;
    }

    /// @notice Build a ruleset config with the given parameters.
    function _makeRulesetConfig(
        uint32 duration,
        JBRulesetMetadata memory metadata,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        private
        pure
        returns (JBRulesetConfig memory config)
    {
        config.mustStartAtOrAfter = 0;
        config.duration = duration;
        config.weight = WEIGHT;
        config.weightCutPercent = 0;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
        config.metadata = metadata;
        config.splitGroups = splitGroups;
        config.fundAccessLimitGroups = fundAccessLimitGroups;
    }
}
