// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBFeelessAddresses} from "../src/JBFeelessAddresses.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {JBTerminalStore} from "../src/JBTerminalStore.sol";
import {JBTokens} from "../src/JBTokens.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBPayHook} from "../src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../src/interfaces/IJBRulesetDataHook.sol";
import {IJBSplitHook} from "../src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBFees} from "../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../src/structs/JBCashOutHookSpecification.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFee} from "../src/structs/JBFee.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {JBAfterPayRecordedContext} from "../src/structs/JBAfterPayRecordedContext.sol";

contract RecordingPayHook is IJBPayHook {
    uint256 public lastMsgValue;
    uint256 public lastForwardedAmount;

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        lastMsgValue = msg.value;
        lastForwardedAmount = context.forwardedAmount.value;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBPayHook).interfaceId;
    }
}

contract DustRouterTerminal is IJBTerminal {
    JBMultiTerminal private immutable _core;
    address payable private immutable _sink;
    uint256 private immutable _nativeRetainAmount;
    address private immutable _secondaryToken;
    uint256 private immutable _secondaryRetainAmount;
    uint256 private immutable _previewHookAmount;

    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) private _contextFor;
    mapping(uint256 projectId => JBAccountingContext[]) private _contextsOf;

    constructor(
        JBMultiTerminal core,
        address payable sink,
        uint256 nativeRetainAmount,
        address secondaryToken,
        uint256 secondaryRetainAmount,
        uint256 previewHookAmount
    ) {
        _core = core;
        _sink = sink;
        _nativeRetainAmount = nativeRetainAmount;
        _secondaryToken = secondaryToken;
        _secondaryRetainAmount = secondaryRetainAmount;
        _previewHookAmount = previewHookAmount;
    }

    receive() external payable {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId;
    }

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        return _contextFor[projectId][token];
    }

    function accountingContextsOf(uint256 projectId) external view override returns (JBAccountingContext[] memory) {
        return _contextsOf[projectId];
    }

    function addAccountingContextsFor(uint256 projectId, JBAccountingContext[] calldata contexts) external override {
        for (uint256 i; i < contexts.length;) {
            if (_contextFor[projectId][contexts[i].token].token == address(0)) {
                _contextsOf[projectId].push(contexts[i]);
            }
            _contextFor[projectId][contexts[i].token] = contexts[i];
            unchecked {
                ++i;
            }
        }
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint256)
    {
        _route(projectId, token, amount);
        return 0;
    }

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {
        _route(projectId, token, amount);
    }

    function _route(uint256 projectId, address token, uint256 amount) private {
        uint256 paid = msg.value == 0 ? amount : msg.value;
        uint256 retained = paid < _nativeRetainAmount ? paid : _nativeRetainAmount;
        if (retained != 0) {
            _core.addToBalanceOf{value: retained}(projectId, token, retained, false, "", "");
        }

        if (_secondaryToken != address(0) && _secondaryRetainAmount != 0) {
            IERC20(_secondaryToken).approve(address(_core), _secondaryRetainAmount);
            _core.addToBalanceOf(projectId, _secondaryToken, _secondaryRetainAmount, false, "", "");
        }

        uint256 leftover = address(this).balance;
        if (leftover != 0) {
            (bool ok,) = _sink.call{value: leftover}("");
            require(ok);
        }
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        view
        override
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](_previewHookAmount == 0 ? 0 : 1);
        if (_previewHookAmount != 0) {
            hookSpecs[0] = JBPayHookSpecification({
                hook: IJBPayHook(_sink), noop: false, amount: _previewHookAmount, metadata: new bytes(0)
            });
        }

        return (
            JBRuleset({
                cycleNumber: 0,
                id: 0,
                basedOnId: 0,
                start: 0,
                duration: 0,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            }),
            0,
            0,
            hookSpecs
        );
    }

    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        pure
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (
            JBRuleset({
                cycleNumber: 0,
                id: 0,
                basedOnId: 0,
                start: 0,
                duration: 0,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            }),
            0,
            0,
            new JBCashOutHookSpecification[](0)
        );
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }
}

/// @notice Regression suite for the internal-pay fee-bypass fix.
///
/// Before the fix, the same-terminal cross-project funding paths (`executePayout` pay-split, and the
/// `cashOutAndPay` cashout-routing leg) skipped the source-side fee because funds were presumed to stay
/// inside the protocol. But the destination project's data hook can divert a subset of the inbound
/// payment to pay hooks (`JBPayHookSpecification`), which IS protocol egress — and that subset previously
/// left without paying a source fee.
///
/// Fix strategy: same-terminal internal funding paths pass the source project through the destination pay
/// hook fulfillment. Each non-feeless pay hook receives `spec.amount - fee`, the source project is charged
/// on that hook gross, and only the actual retained destination balance delta is credited fee-free.
///
/// Invariants asserted across this suite:
///   - same-terminal pay-split into a data-hooked project charges source fee on hook-forwarded gross
///   - retained portion on destination credited fee-free (capped at actual recorded balance)
///   - `holdFees()` on source ruleset honored for the new pay-split fee (held vs immediate)
///   - `preferAddToBalance == true` keeps existing fee-free behavior (no hook route possible)
///   - `cashOutAndPay(...)` charges the new fee immediately (parity with direct cashout)
///   - external/router `cashOutAndPay(...)` routes only skip fees when no hooks are previewed, all
///     beneficiary contexts are source-token contexts, and the full source-token reclaim is retained here
///   - non-data-hook destinations stay fee-free (the existing same-terminal fast path is preserved)
contract TestInternalPayFeeBypass is TestBaseWorkflow {
    IJBController private _controller;
    JBMultiTerminal private _terminal;
    JBMultiTerminal private _terminal2;
    JBTerminalStore private _store;
    JBTokens private _tokens;
    JBFeelessAddresses private _feeless;
    address private _projectOwner;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;

    // Storage slot of `_feeFreeSurplusOf` in `JBMultiTerminal` (first state variable).
    uint256 private constant FEE_FREE_SURPLUS_SLOT = 0;

    function setUp() public override {
        super.setUp();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _terminal2 = jbMultiTerminal2();
        _store = jbTerminalStore();
        _tokens = jbTokens();
        _feeless = jbFeelessAddresses();
        _projectOwner = multisig();
    }

    // ==========================================
    // 1. Same-terminal payout split with hook forwarding 90%, source.holdFees=false
    // ==========================================

    function test_payoutSplitToDataHookedProject_holdFeesFalse_chargesImmediateFee() external {
        _launchFeeProject();

        RecordingPayHook payHook = new RecordingPayHook();
        address dataHook = makeAddr("data-hook-1");
        uint224 payoutAmount = 10 ether;
        uint256 hookSpecAmount = 9 ether;

        // Project B: zero tax, data hook routes 9 ETH of every payment to `payHook`.
        uint256 projectIdB = _launchProjectWithDataHookForPay(dataHook, address(payHook), hookSpecAmount);

        // Project A: 100% payout split to B (preferAddToBalance=false), source ruleset holdFees=false.
        uint256 projectIdA = _launchProjectWithPayoutSplitToProject(
            projectIdB,
            payoutAmount,
            /* holdFees */
            false
        );

        _payTerminal(projectIdA, payoutAmount);

        uint256 feeProjectBalanceBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        _sendPayouts(projectIdA, payoutAmount);

        uint256 expectedSourceFee = JBFees.standardFeeAmountFrom(hookSpecAmount); // 0.225 ETH
        uint256 expectedHookNet = hookSpecAmount - expectedSourceFee; // 8.775 ETH
        uint256 expectedBalanceB = payoutAmount - hookSpecAmount; // 1 ETH retained

        assertEq(
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            expectedBalanceB,
            "B balance == payAmount - hookSpec"
        );

        // Fee-free credit on B is capped at actual recorded balance.
        assertEq(
            _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN),
            expectedBalanceB,
            "feeFreeSurplus[B] == retained portion (cap)"
        );

        // holdFees=false → source fee processed immediately. Fee project's recorded balance grew by the fee.
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN)
                - feeProjectBalanceBefore,
            expectedSourceFee,
            "fee project recorded the source fee (immediate processing)"
        );
        assertEq(payHook.lastMsgValue(), expectedHookNet, "pay hook received net after source fee");
        assertEq(payHook.lastForwardedAmount(), expectedHookNet, "pay hook context uses net forwarded amount");

        // No held fees against A (fee was processed immediately, not held).
        assertEq(_terminal.heldFeesOf(projectIdA, JBConstants.NATIVE_TOKEN, 10).length, 0, "no held fee on A");
    }

    // ==========================================
    // 2. Same setup with source.holdFees=true -> fee held, not processed
    // ==========================================

    function test_payoutSplitToDataHookedProject_holdFeesTrue_holdsFeeOnSource() external {
        _launchFeeProject();

        RecordingPayHook payHook = new RecordingPayHook();
        address dataHook = makeAddr("data-hook-2");
        uint224 payoutAmount = 10 ether;
        uint256 hookSpecAmount = 9 ether;

        uint256 projectIdB = _launchProjectWithDataHookForPay(dataHook, address(payHook), hookSpecAmount);
        uint256 projectIdA = _launchProjectWithPayoutSplitToProject(
            projectIdB,
            payoutAmount,
            /* holdFees */
            true
        );

        _payTerminal(projectIdA, payoutAmount);

        uint256 feeProjectBalanceBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        _sendPayouts(projectIdA, payoutAmount);

        // Fee project balance must NOT change — the fee is held against A, not processed yet.
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBalanceBefore,
            "fee project balance unchanged when holdFees=true"
        );

        uint256 expectedSourceFee = JBFees.standardFeeAmountFrom(hookSpecAmount);
        uint256 expectedHookNet = hookSpecAmount - expectedSourceFee;

        // A's held-fee queue should have one entry; gross == the hook amount that was fee-eligible.
        JBFee[] memory held = _terminal.heldFeesOf(projectIdA, JBConstants.NATIVE_TOKEN, 10);
        assertEq(held.length, 1, "exactly one held fee entry queued");
        assertEq(held[0].amount, hookSpecAmount, "held fee gross == hook-forwarded amount");
        assertEq(payHook.lastMsgValue(), expectedHookNet, "pay hook received net after held source fee");
        assertEq(payHook.lastForwardedAmount(), expectedHookNet, "pay hook context uses net forwarded amount");
    }

    // ==========================================
    // 3. preferAddToBalance=true -> no source fee, full retention
    // ==========================================

    function test_payoutSplitPreferAddToBalance_noSourceFee_evenWithDataHook() external {
        _launchFeeProject();

        // Even if B has useDataHookForPay=true, `addToBalanceOf` does NOT invoke the data hook. So the
        // existing fee-free same-terminal fast path is preserved for `preferAddToBalance=true`.
        address dataHook = makeAddr("data-hook-3");
        address payHook = makeAddr("pay-hook-3");
        uint224 payoutAmount = 10 ether;
        uint256 projectIdB = _launchProjectWithDataHookForPay(
            dataHook,
            payHook,
            /* hookSpecAmount */
            5 ether
        );

        uint256 projectIdA = _launchProjectWithAddToBalanceSplit(projectIdB, payoutAmount);

        _payTerminal(projectIdA, payoutAmount);

        uint256 feeProjectBalanceBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        _sendPayouts(projectIdA, payoutAmount);

        // B got the full payout retained as fee-free surplus; no fee charged anywhere.
        assertEq(
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            payoutAmount,
            "B got full payout via addToBalance"
        );
        assertEq(
            _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN), payoutAmount, "fee-free surplus == full payout"
        );
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBalanceBefore,
            "no source fee for addToBalance path"
        );
        assertEq(
            _terminal.heldFeesOf(projectIdA, JBConstants.NATIVE_TOKEN, 10).length,
            0,
            "no held fee for addToBalance path"
        );
    }

    // ==========================================
    // 4. Cross-terminal project pay split preserves gross fee eligibility
    // ==========================================

    function test_crossTerminalProjectPaySplit_preservesFeeEligibility() external {
        _launchFeeProject();

        uint224 payoutAmount = 10 ether;
        uint256 projectIdB = _launchProjectNoDataHookOn(_terminal2);
        uint256 projectIdA = _launchProjectWithPayoutSplitToProject(
            projectIdB,
            payoutAmount,
            /* holdFees */
            false
        );

        _payTerminal(projectIdA, payoutAmount);

        uint256 feeProjectBalanceBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        _sendPayouts(projectIdA, payoutAmount);

        uint256 expectedFee = JBFees.standardFeeAmountFrom(payoutAmount);
        uint256 expectedNetToB = payoutAmount - expectedFee;

        assertEq(
            _store.balanceOf(address(_terminal2), projectIdB, JBConstants.NATIVE_TOKEN),
            expectedNetToB,
            "B received cross-terminal net payout"
        );
        assertEq(
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            0,
            "core terminal did not credit B for cross-terminal pay"
        );
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN)
                - feeProjectBalanceBefore,
            expectedFee,
            "source fee was processed on cross-terminal gross"
        );
        assertEq(_terminal.heldFeesOf(projectIdA, JBConstants.NATIVE_TOKEN, 10).length, 0, "no held fee on A");
    }

    // ==========================================
    // 5. cashOutAndPay -> immediate source fee on data-hooked destination
    // ==========================================

    function test_cashOutAndPay_intoDataHookedProject_chargesImmediateSourceFee() external {
        _launchFeeProject();

        RecordingPayHook payHook = new RecordingPayHook();
        uint256 projectIdB = _launchProjectWithDataHookForPay(makeAddr("data-hook-4"), address(payHook), 5 ether);
        (uint256 projectIdA, address holder) = _seedSourceProjectAndHolder(10 ether);

        _doCashOutAndPayAndAssert(projectIdA, projectIdB, holder, payHook, 10 ether, 5 ether);
    }

    function _seedSourceProjectAndHolder(uint256 payIn) internal returns (uint256 projectIdA, address holder) {
        projectIdA = _launchProjectNoDataHook();
        vm.prank(_projectOwner);
        _controller.deployERC20For(projectIdA, "ProjectA", "PA", bytes32(0));
        holder = makeAddr("holder-4");
        vm.deal(holder, payIn);
        vm.prank(holder);
        _terminal.pay{value: payIn}({
            projectId: projectIdA,
            amount: payIn,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: holder,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    function _doCashOutAndPayAndAssert(
        uint256 projectIdA,
        uint256 projectIdB,
        address holder,
        RecordingPayHook payHook,
        uint256 payIn,
        uint256 hookSpecAmount
    )
        internal
    {
        uint256 feeProjectBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 tokens = _tokens.totalBalanceOf(holder, projectIdA);

        vm.prank(holder);
        (uint256 reclaim,) = _terminal.cashOutAndPay({
            holder: holder,
            projectId: projectIdA,
            cashOutCount: tokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiaryProjectId: projectIdB,
            beneficiary: holder,
            minTokensOut: 0,
            cashOutMetadata: new bytes(0),
            payMetadata: new bytes(0)
        });
        assertEq(reclaim, payIn, "reclaim == full A surplus");

        uint256 expectedSourceFee = JBFees.standardFeeAmountFrom(hookSpecAmount);
        uint256 expectedHookNet = hookSpecAmount - expectedSourceFee;
        uint256 expectedBalanceB = reclaim - hookSpecAmount;

        // Source fee processed immediately (cashout-style, no holding).
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN)
                - feeProjectBefore,
            expectedSourceFee,
            "fee project recorded the cashout-routing source fee"
        );
        assertEq(
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            expectedBalanceB,
            "B retained == reclaim - hookSpec"
        );
        assertEq(
            _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN), expectedBalanceB, "feeFreeSurplus[B] == retained"
        );
        assertEq(payHook.lastMsgValue(), expectedHookNet, "pay hook received net after source fee");
        assertEq(payHook.lastForwardedAmount(), expectedHookNet, "pay hook context uses net forwarded amount");
    }

    // ==========================================
    // 6. cashOutAndPay with 100% hook forwarding succeeds when fully fee-bound
    // ==========================================

    function test_cashOutAndPay_withFullHookForwarding_chargesFullImmediateFee() external {
        _launchFeeProject();

        RecordingPayHook payHook = new RecordingPayHook();
        uint256 projectIdB = _launchProjectWithDataHookForPay(makeAddr("data-hook-full"), address(payHook), 10 ether);
        (uint256 projectIdA, address holder) = _seedSourceProjectAndHolder(10 ether);

        _doCashOutAndPayAndAssert(projectIdA, projectIdB, holder, payHook, 10 ether, 10 ether);
    }

    // ==========================================
    // 7. Feeless full hook forwarding is bound/exempt, not charged
    // ==========================================

    function test_cashOutAndPay_feelessHookForwarding_isBoundWithoutSourceFee() external {
        _launchFeeProject();

        RecordingPayHook payHook = new RecordingPayHook();
        uint256 projectIdB =
            _launchProjectWithDataHookForPay(makeAddr("data-hook-feeless-full"), address(payHook), 10 ether);
        (uint256 projectIdA, address holder) = _seedSourceProjectAndHolder(10 ether);

        vm.prank(_projectOwner);
        _feeless.setFeelessAddressFor({projectId: projectIdA, addr: address(payHook), flag: true});

        uint256 feeProjectBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 tokens = _tokens.totalBalanceOf(holder, projectIdA);

        vm.prank(holder);
        (uint256 reclaim,) = _terminal.cashOutAndPay({
            holder: holder,
            projectId: projectIdA,
            cashOutCount: tokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiaryProjectId: projectIdB,
            beneficiary: holder,
            minTokensOut: 0,
            cashOutMetadata: new bytes(0),
            payMetadata: new bytes(0)
        });

        assertEq(reclaim, 10 ether, "reclaim == full A surplus");
        assertEq(payHook.lastMsgValue(), 10 ether, "feeless hook received full forwarded amount");
        assertEq(payHook.lastForwardedAmount(), 10 ether, "feeless hook context uses full forwarded amount");
        assertEq(_store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN), 0, "B retained zero");
        assertEq(_readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN), 0, "B got no fee-free surplus");
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBefore,
            "feeless hook egress is not source-fee charged"
        );
        assertEq(_terminal.heldFeesOf(projectIdA, JBConstants.NATIVE_TOKEN, 10).length, 0, "cashout fee not held");
    }

    // ==========================================
    // 8. External/router route with no previewed hook forwarding can retain source tokens fee-free
    // ==========================================

    function test_cashOutAndPay_externalRouterSourceToken_withoutHookForwarding_creditsRetainedOutputFeeFree()
        external
    {
        _launchFeeProject();

        address payable sink = payable(makeAddr("router-sink-source-token"));
        DustRouterTerminal router = new DustRouterTerminal({
            core: _terminal,
            sink: sink,
            nativeRetainAmount: 10 ether,
            secondaryToken: address(0),
            secondaryRetainAmount: 0,
            previewHookAmount: 0
        });

        uint256 projectIdB = _launchProjectNoDataHookWithTerminalConfig(_makeNativeOnlyRouterTerminalConfig(router));
        (uint256 projectIdA, address holder) = _seedSourceProjectAndHolder(10 ether);
        uint256 tokens = _tokens.totalBalanceOf(holder, projectIdA);
        uint256 feeProjectBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        vm.prank(holder);
        _terminal.cashOutAndPay({
            holder: holder,
            projectId: projectIdA,
            cashOutCount: tokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiaryProjectId: projectIdB,
            beneficiary: holder,
            minTokensOut: 0,
            cashOutMetadata: new bytes(0),
            payMetadata: new bytes(0)
        });

        assertEq(sink.balance, 0, "source-token reclaim was retained");
        assertEq(_store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN), 10 ether, "B retained");
        assertEq(_readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN), 10 ether, "retained source token credited");
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBefore,
            "no source fee when retained source token binds the reclaim"
        );
    }

    // ==========================================
    // 9. External/router no-hook cross-token route pays source fee up front
    // ==========================================

    function test_cashOutAndPay_externalRouterCrossToken_withoutHookForwarding_chargesSourceFeeAndRoutesNet() external {
        _launchFeeProject();

        address payable sink = payable(makeAddr("router-sink-cross-token"));
        MockERC20 usdc = usdcToken();
        uint256 usdcRetainAmount = 100_000_000;
        DustRouterTerminal router = new DustRouterTerminal({
            core: _terminal,
            sink: sink,
            nativeRetainAmount: 0,
            secondaryToken: address(usdc),
            secondaryRetainAmount: usdcRetainAmount,
            previewHookAmount: 0
        });
        usdc.mint(address(router), usdcRetainAmount);

        uint256 projectIdB = _launchProjectNoDataHookWithRouter(router, address(usdc));
        (uint256 projectIdA, address holder) = _seedSourceProjectAndHolder(10 ether);
        uint256 tokens = _tokens.totalBalanceOf(holder, projectIdA);
        uint256 expectedSourceFee = JBFees.standardFeeAmountFrom(10 ether);
        uint256 feeProjectBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        vm.prank(holder);
        _terminal.cashOutAndPay({
            holder: holder,
            projectId: projectIdA,
            cashOutCount: tokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiaryProjectId: projectIdB,
            beneficiary: holder,
            minTokensOut: 0,
            cashOutMetadata: new bytes(0),
            payMetadata: new bytes(0)
        });

        assertEq(sink.balance, 10 ether - expectedSourceFee, "router received net reclaim");
        assertEq(_store.balanceOf(address(_terminal), projectIdB, address(usdc)), usdcRetainAmount, "USDC retained");
        assertEq(_readFeeFreeSurplus(projectIdB, address(usdc)), 0, "cross-token output not credited fee-free");
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBefore + expectedSourceFee,
            "source fee processed immediately"
        );
    }

    // ==========================================
    // 10. External/router route with previewed hook forwarding pays source fee up front
    // ==========================================

    function test_cashOutAndPay_externalRouterCrossToken_withHookForwarding_chargesSourceFeeAndRoutesNet() external {
        _launchFeeProject();

        address payable sink = payable(makeAddr("router-sink-hooked"));
        MockERC20 usdc = usdcToken();
        uint256 usdcRetainAmount = 1_000_000;
        DustRouterTerminal router = new DustRouterTerminal({
            core: _terminal,
            sink: sink,
            nativeRetainAmount: 0,
            secondaryToken: address(usdc),
            secondaryRetainAmount: usdcRetainAmount,
            previewHookAmount: 5 ether
        });
        usdc.mint(address(router), usdcRetainAmount);

        uint256 projectIdB = _launchProjectNoDataHookWithRouter(router, address(usdc));
        (uint256 projectIdA, address holder) = _seedSourceProjectAndHolder(10 ether);
        uint256 tokens = _tokens.totalBalanceOf(holder, projectIdA);
        uint256 expectedSourceFee = JBFees.standardFeeAmountFrom(10 ether);
        uint256 feeProjectBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        vm.prank(holder);
        _terminal.cashOutAndPay({
            holder: holder,
            projectId: projectIdA,
            cashOutCount: tokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            beneficiaryProjectId: projectIdB,
            beneficiary: holder,
            minTokensOut: 0,
            cashOutMetadata: new bytes(0),
            payMetadata: new bytes(0)
        });

        assertEq(sink.balance, 10 ether - expectedSourceFee, "router received only net reclaim");
        assertEq(_store.balanceOf(address(_terminal), projectIdB, address(usdc)), usdcRetainAmount, "USDC retained");
        assertEq(
            _readFeeFreeSurplus(projectIdB, address(usdc)), 0, "hook-forwarding external route is not fee-free credited"
        );
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBefore + expectedSourceFee,
            "source fee processed immediately"
        );
    }

    // ==========================================
    // 11. Non-data-hook destination -> existing fee-free same-terminal pay preserved
    // ==========================================

    function test_payoutSplitToNonDataHookedProject_staysFeeFree() external {
        _launchFeeProject();

        uint224 payoutAmount = 10 ether;
        uint256 projectIdB = _launchProjectNoDataHook();
        uint256 projectIdA = _launchProjectWithPayoutSplitToProject(
            projectIdB,
            payoutAmount,
            /* holdFees */
            false
        );

        _payTerminal(projectIdA, payoutAmount);

        uint256 feeProjectBefore =
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        _sendPayouts(projectIdA, payoutAmount);

        // No data hook on B → existing fast path: no source fee, full fee-free credit.
        assertEq(
            _store.balanceOf(address(_terminal), projectIdB, JBConstants.NATIVE_TOKEN),
            payoutAmount,
            "B got full payout (no hook route)"
        );
        assertEq(
            _readFeeFreeSurplus(projectIdB, JBConstants.NATIVE_TOKEN),
            payoutAmount,
            "fee-free surplus == full payout (non-data-hook destination)"
        );
        assertEq(
            _store.balanceOf(address(_terminal), JBConstants.FEE_BENEFICIARY_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            feeProjectBefore,
            "no source fee for non-data-hook destination"
        );
    }

    // ==========================================
    // Helpers
    // ==========================================

    function _readFeeFreeSurplus(uint256 projectId, address token) internal view returns (uint256) {
        bytes32 innerSlot = keccak256(abi.encode(projectId, FEE_FREE_SURPLUS_SLOT));
        bytes32 finalSlot = keccak256(abi.encode(token, innerSlot));
        return uint256(vm.load(address(_terminal), finalSlot));
    }

    function _launchProjectWithDataHookForPay(
        address dataHook,
        address payHook,
        uint256 hookSpecAmount
    )
        internal
        returns (uint256 projectId)
    {
        vm.mockCall(dataHook, abi.encodeWithSelector(bytes4(keccak256("supportsInterface(bytes4)"))), abi.encode(true));
        vm.mockCall(
            dataHook, abi.encodeWithSelector(IJBRulesetDataHook.hasMintPermissionFor.selector), abi.encode(false)
        );

        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({
            hook: IJBPayHook(payHook), noop: false, amount: hookSpecAmount, metadata: new bytes(0)
        });

        vm.mockCall(
            dataHook,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(WEIGHT, hookSpecs)
        );
        if (payHook.code.length == 0) {
            vm.mockCall(payHook, abi.encodeWithSelector(IJBPayHook.afterPayRecordedWith.selector), abi.encode());
        }

        JBRulesetMetadata memory metadata = _defaultMetadata();
        metadata.useDataHookForPay = true;
        metadata.dataHook = dataHook;

        JBRulesetConfig[] memory cfg = new JBRulesetConfig[](1);
        cfg[0] = _makeRulesetConfig({
            duration: 0,
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "B",
            rulesetConfigurations: cfg,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    function _launchProjectNoDataHook() internal returns (uint256 projectId) {
        return _launchProjectNoDataHookOn(_terminal);
    }

    function _launchProjectNoDataHookOn(JBMultiTerminal terminal) internal returns (uint256 projectId) {
        return _launchProjectNoDataHookWithTerminalConfig(_makeTerminalConfigFor(terminal));
    }

    function _launchProjectNoDataHookWithRouter(
        DustRouterTerminal router,
        address secondaryToken
    )
        internal
        returns (uint256 projectId)
    {
        return _launchProjectNoDataHookWithTerminalConfig(_makeRouterTerminalConfig(router, secondaryToken));
    }

    function _launchProjectNoDataHookWithTerminalConfig(JBTerminalConfig[] memory terminalConfig)
        internal
        returns (uint256 projectId)
    {
        return _launchProjectNoDataHookWithTerminalConfigAndMetadata({
            terminalConfig: terminalConfig, metadata: _defaultMetadata(), projectUri: "B-plain"
        });
    }

    function _launchProjectNoDataHookWithTerminalConfigAndMetadata(
        JBTerminalConfig[] memory terminalConfig,
        JBRulesetMetadata memory metadata,
        string memory projectUri
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetConfig[] memory cfg = new JBRulesetConfig[](1);
        cfg[0] = _makeRulesetConfig({
            duration: 0,
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: projectUri,
            rulesetConfigurations: cfg,
            terminalConfigurations: terminalConfig,
            memo: ""
        });
    }

    function _launchProjectWithPayoutSplitToProject(
        uint256 destProjectId,
        uint224 payoutLimit,
        bool holdFees
    )
        internal
        returns (uint256 projectId)
    {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(destProjectId),
            beneficiary: payable(makeAddr("dest-beneficiary")),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBRulesetMetadata memory metadata = _defaultMetadata();
        metadata.holdFees = holdFees;

        JBRulesetConfig[] memory cfg = new JBRulesetConfig[](1);
        cfg[0] = _makeRulesetConfig({
            duration: 0,
            metadata: metadata,
            splitGroups: groups,
            fundAccessLimitGroups: _makeFundAccessLimitGroup(payoutLimit)
        });

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "A",
            rulesetConfigurations: cfg,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    function _launchProjectWithAddToBalanceSplit(
        uint256 destProjectId,
        uint224 payoutLimit
    )
        internal
        returns (uint256 projectId)
    {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: true,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(destProjectId),
            beneficiary: payable(address(0)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory groups = new JBSplitGroup[](1);
        groups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBRulesetConfig[] memory cfg = new JBRulesetConfig[](1);
        cfg[0] = _makeRulesetConfig({
            duration: 0,
            metadata: _defaultMetadata(),
            splitGroups: groups,
            fundAccessLimitGroups: _makeFundAccessLimitGroup(payoutLimit)
        });

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "A-addToBalance",
            rulesetConfigurations: cfg,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    function _launchFeeProject() internal returns (uint256) {
        JBRulesetConfig[] memory cfg = new JBRulesetConfig[](1);
        cfg[0] = _makeRulesetConfig({
            duration: 0,
            metadata: _defaultMetadata(),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        return _controller.launchProjectFor({
            owner: makeAddr("fee-owner"),
            projectUri: "fee",
            rulesetConfigurations: cfg,
            terminalConfigurations: _makeTerminalConfig(),
            memo: ""
        });
    }

    function _payTerminal(uint256 projectId, uint256 amount) internal {
        address payer = makeAddr(string.concat("payer-", _toString(projectId)));
        vm.deal(payer, amount);
        vm.prank(payer);
        _terminal.pay{value: amount}({
            projectId: projectId,
            amount: amount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    function _sendPayouts(uint256 projectId, uint256 amount) internal {
        _terminal.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });
    }

    function _defaultMetadata() internal pure returns (JBRulesetMetadata memory) {
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            pauseCrossProjectFeeFreeInflows: false
        });
    }

    function _makeTerminalConfig() internal view returns (JBTerminalConfig[] memory termConfigs) {
        return _makeTerminalConfigFor(_terminal);
    }

    function _makeTerminalConfigFor(JBMultiTerminal terminal)
        internal
        pure
        returns (JBTerminalConfig[] memory termConfigs)
    {
        JBAccountingContext[] memory ctxs = new JBAccountingContext[](1);
        ctxs[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        termConfigs = new JBTerminalConfig[](1);
        termConfigs[0] = JBTerminalConfig({terminal: terminal, accountingContextsToAccept: ctxs});
    }

    function _makeRouterTerminalConfig(
        DustRouterTerminal router,
        address secondaryToken
    )
        internal
        view
        returns (JBTerminalConfig[] memory termConfigs)
    {
        return _makeRouterTerminalConfigWithSecondaryCurrency({
            router: router, secondaryToken: secondaryToken, secondaryCurrency: uint32(uint160(secondaryToken))
        });
    }

    function _makeNativeOnlyRouterTerminalConfig(DustRouterTerminal router)
        internal
        view
        returns (JBTerminalConfig[] memory termConfigs)
    {
        JBAccountingContext[] memory nativeCtxs = new JBAccountingContext[](1);
        nativeCtxs[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        termConfigs = new JBTerminalConfig[](2);
        termConfigs[0] = JBTerminalConfig({terminal: router, accountingContextsToAccept: nativeCtxs});
        termConfigs[1] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: nativeCtxs});
    }

    function _makeRouterTerminalConfigWithSecondaryCurrency(
        DustRouterTerminal router,
        address secondaryToken,
        uint32 secondaryCurrency
    )
        internal
        view
        returns (JBTerminalConfig[] memory termConfigs)
    {
        JBAccountingContext[] memory routerCtxs = new JBAccountingContext[](1);
        routerCtxs[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBAccountingContext[] memory coreCtxs = new JBAccountingContext[](2);
        coreCtxs[0] = routerCtxs[0];
        coreCtxs[1] = JBAccountingContext({token: secondaryToken, decimals: 6, currency: secondaryCurrency});

        termConfigs = new JBTerminalConfig[](2);
        termConfigs[0] = JBTerminalConfig({terminal: router, accountingContextsToAccept: routerCtxs});
        termConfigs[1] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: coreCtxs});
    }

    function _makeFundAccessLimitGroup(uint224 payoutLimitAmount)
        internal
        view
        returns (JBFundAccessLimitGroup[] memory groups)
    {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: payoutLimitAmount, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        groups = new JBFundAccessLimitGroup[](1);
        groups[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
    }

    function _makeRulesetConfig(
        uint32 duration,
        JBRulesetMetadata memory metadata,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        pure
        returns (JBRulesetConfig memory cfg)
    {
        cfg.mustStartAtOrAfter = 0;
        cfg.duration = duration;
        cfg.weight = WEIGHT;
        cfg.weightCutPercent = 0;
        cfg.approvalHook = IJBRulesetApprovalHook(address(0));
        cfg.metadata = metadata;
        cfg.splitGroups = splitGroups;
        cfg.fundAccessLimitGroups = fundAccessLimitGroups;
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 tmp = v;
        while (tmp != 0) {
            digits++;
            tmp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buffer);
    }
}
