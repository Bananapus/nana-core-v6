// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "../../../mock/MockERC20.sol";
import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {JBPermissioned} from "../../../../src/abstract/JBPermissioned.sol";
import {IJBCashOutHook} from "../../../../src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBFees} from "../../../../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBAfterCashOutRecordedContext} from "../../../../src/structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../../../../src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice Unit tests for `JBMultiTerminal.cashOutAndPay(...)`. The flow burns source-project
/// tokens and pays the reclaim into a destination project via that project's primary terminal for the reclaim token.
/// Same-terminal retained balances are credited to `_feeFreeSurplusOf[B][token]`; external/router routes pay the
/// source fee up front and route only the net amount.
/// @dev Heavy mocking — same convention as `TestCashOutTokensOf` and `TestPay`. `mockExpectSubsequent` is used
/// to simulate `STORE.balanceOf` before/after pattern with sequenced return values. Storage of internal
/// `_feeFreeSurplusOf` is read/written via `vm.load`/`vm.store` (slot 0 — confirmed via `forge inspect`) so
/// tests can directly verify the fee-free credit lands on the right (project, token) bucket and accumulates
/// additively rather than overwriting.
contract TestCashOutAndPay_Local is JBMultiTerminalSetup {
    // -- Source project (A) --
    uint64 _sourceProjectId = 1;
    uint256 _defaultCashOutCount = 1e18;

    // -- Destination project (B) --
    uint64 _destProjectId = 2;

    // -- Actors --
    address _holder = makeAddr("holder");
    address payable _bene = payable(makeAddr("beneficiary"));
    address _operator = makeAddr("operator");

    // -- Tokens --
    address _mockToken = makeAddr("mockToken");
    address _otherTokenAddr = makeAddr("otherToken");
    MockERC20 _erc20;

    // -- Mocks --
    IJBCashOutHook _mockHook = IJBCashOutHook(makeAddr("cashOutHook"));
    IJBTerminal _otherTerminal = IJBTerminal(makeAddr("otherTerminal"));

    // -- Defaults --
    uint256 _defaultReclaim = 1e9;
    uint256 _defaultMintCount = 5e8;

    function setUp() public {
        super.multiTerminalSetup();
        _erc20 = new MockERC20("Token", "TKN");
    }

    //*********************************************************************//
    // ---------------------------- helpers ------------------------------ //
    //*********************************************************************//

    function _stubPermission(bool granted) internal {
        _stubPermissionFor({sender: _bene, account: _holder, granted: granted});
    }

    function _stubPermissionFor(address sender, address account, bool granted) internal {
        mockExpect(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (sender, account, _sourceProjectId, JBPermissionIds.CASH_OUT_TOKENS, true, true)
            ),
            abi.encode(granted)
        );
    }

    function _emptyRuleset() internal pure returns (JBRuleset memory) {
        return JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
    }

    /// @notice Stub B's controller + current-ruleset. The bool expresses the test's intent ("is B accepting
    /// fee-free inflows?") and gets inverted into the underlying `pauseCrossProjectFeeFreeInflows` flag so
    /// call sites read naturally.
    function _stubBController(bool allowFeeFreeInflows) internal {
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_destProjectId)), abi.encode(address(this))
        );

        JBRulesetMetadata memory md = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: 0,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            pauseCrossProjectFeeFreeInflows: !allowFeeFreeInflows,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        mockExpect(
            address(this),
            abi.encodeCall(IJBController.currentRulesetOf, (_destProjectId)),
            abi.encode(_emptyRuleset(), md)
        );
    }

    /// @notice Stub the cashout + burn side. Returns the gross reclaim amount and an empty hook spec array.
    function _stubCashoutSide(address token, uint256 cashOutCount, uint256 reclaimAmount) internal {
        _stubCashoutSideWithSpecs({
            token: token,
            cashOutCount: cashOutCount,
            reclaimAmount: reclaimAmount,
            specs: new JBCashOutHookSpecification[](0)
        });
    }

    /// @notice Stub the cashout + burn side, returning `specs` as the hook specifications array.
    function _stubCashoutSideWithSpecs(
        address token,
        uint256 cashOutCount,
        uint256 reclaimAmount,
        JBCashOutHookSpecification[] memory specs
    )
        internal
    {
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordCashOutFor, (_holder, _sourceProjectId, cashOutCount, token, true, "")
            ),
            abi.encode(_emptyRuleset(), reclaimAmount, JBConstants.MAX_CASH_OUT_TAX_RATE, specs)
        );

        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_sourceProjectId)), abi.encode(address(this))
        );

        // burnTokensOf is only called when cashOutCount > 0.
        if (cashOutCount > 0) {
            mockExpect(
                address(this),
                abi.encodeCall(IJBController.burnTokensOf, (_holder, _sourceProjectId, cashOutCount, "")),
                ""
            );
        }
    }

    /// @notice Stub source A's `_capFeeFreeSurplus` balance read. Mocked loosely so the cap path can be
    /// hit selectively (cap is a no-op when source's `_feeFreeSurplusOf == 0`, so unused mocks are harmless).
    function _stubABalanceRead(address token, uint256 value) internal {
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _sourceProjectId, token)),
            abi.encode(value)
        );
    }

    /// @notice Stub B's accounting contexts on this terminal.
    function _stubBAccountingContexts(JBAccountingContext[] memory contexts) internal {
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextsOf, (address(_terminal), _destProjectId)),
            abi.encode(contexts)
        );
    }

    function _singleTokenContext(address token) internal pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function _twoTokenContext(
        address tokenA,
        address tokenB
    )
        internal
        pure
        returns (JBAccountingContext[] memory contexts)
    {
        contexts = new JBAccountingContext[](2);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: tokenA, decimals: 18, currency: uint32(uint160(tokenA))});
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[1] = JBAccountingContext({token: tokenB, decimals: 18, currency: uint32(uint160(tokenB))});
    }

    /// @notice Stub a single-context balance sequence: pre-routing snapshot, post-routing read, and (if a
    /// delivery delta lands) the additional read consumed by `_capFeeFreeSurplus` after the credit.
    function _stubBBalanceSequence(address token, uint256 balanceBefore, uint256 balanceAfter) internal {
        bool capFires = balanceAfter > balanceBefore;
        bytes[] memory returns_ = new bytes[](capFires ? 3 : 2);
        returns_[0] = abi.encode(balanceBefore);
        returns_[1] = abi.encode(balanceAfter);
        if (capFires) returns_[2] = abi.encode(balanceAfter);
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, token)),
            returns_
        );
    }

    /// @notice Stub two-context balance reads. Pre-routing and post-routing reads happen for both contexts
    /// in array order. Each context that grows also gets the extra `_capFeeFreeSurplus` balance read.
    /// @param tokenA First context token.
    /// @param tokenB Second context token.
    /// @param beforeA Pre-routing balance for tokenA.
    /// @param beforeB Pre-routing balance for tokenB.
    /// @param afterA Post-routing balance for tokenA.
    /// @param afterB Post-routing balance for tokenB.
    function _stubBTwoContextBalanceSequence(
        address tokenA,
        address tokenB,
        uint256 beforeA,
        uint256 beforeB,
        uint256 afterA,
        uint256 afterB
    )
        internal
    {
        // tokenA reads: pre-routing, post-routing, cap-after-credit (only if A grew).
        bool aGrew = afterA > beforeA;
        bytes[] memory aReturns = new bytes[](aGrew ? 3 : 2);
        aReturns[0] = abi.encode(beforeA);
        aReturns[1] = abi.encode(afterA);
        if (aGrew) aReturns[2] = abi.encode(afterA);
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, tokenA)),
            aReturns
        );

        // tokenB reads: pre-routing, post-routing, cap-after-credit (only if B grew).
        bool bGrew = afterB > beforeB;
        uint256 bReadCount = bGrew ? 3 : 2;
        bytes[] memory bReturns = new bytes[](bReadCount);
        bReturns[0] = abi.encode(beforeB);
        bReturns[1] = abi.encode(afterB);
        if (bReadCount == 3) bReturns[2] = abi.encode(afterB);
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, tokenB)),
            bReturns
        );
    }

    /// @notice Stub the same-terminal `_pay` flow for routing into B.
    /// @dev Default: payer == sender == `_bene` under `vm.prank(_bene)`.
    function _stubSameTerminalPay(address token, uint256 reclaimAmount, uint256 mintCount) internal {
        _stubSameTerminalPayWithPayer({payer: _bene, token: token, reclaimAmount: reclaimAmount, mintCount: mintCount});
    }

    function _stubSameTerminalPayWithPayer(
        address payer,
        address token,
        uint256 reclaimAmount,
        uint256 mintCount
    )
        internal
    {
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, token)),
            abi.encode(address(_terminal))
        );

        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext memory ctx =
            JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _destProjectId, token)),
            abi.encode(ctx)
        );

        JBTokenAmount memory tokenAmount = JBTokenAmount({
            token: token,
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(token)),
            value: reclaimAmount
        });

        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPaymentFrom, (payer, tokenAmount, _destProjectId, _bene, "")),
            abi.encode(_emptyRuleset(), mintCount, new bytes(0))
        );

        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_destProjectId)), abi.encode(address(this))
        );
        if (mintCount > 0) {
            mockExpect(
                address(this),
                abi.encodeCall(IJBController.mintTokensOf, (_destProjectId, mintCount, _bene, "", true)),
                abi.encode(mintCount)
            );
        }
    }

    /// @notice Stub the cross-terminal external `pay()` path. The destination terminal is a different address
    /// (`_otherTerminal`) than this terminal. For ERC20 tokens, `forceApprove` runs against the real ERC20 and
    /// `_afterTransferTo` reads the post-call allowance. For NATIVE_TOKEN, the value is forwarded as `msg.value`.
    function _stubCrossTerminalPay(address token, uint256 reclaimAmount, uint256 mintCount) internal {
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, token)),
            abi.encode(address(_otherTerminal))
        );

        uint256 ethValue = token == JBConstants.NATIVE_TOKEN ? reclaimAmount : 0;

        // External pay call. mintCount is what the destination terminal returns to the caller.
        vm.mockCall(
            address(_otherTerminal),
            ethValue,
            abi.encodeCall(IJBTerminal.pay, (_destProjectId, token, reclaimAmount, _bene, 0, "", "")),
            abi.encode(mintCount)
        );
        vm.expectCall(
            address(_otherTerminal),
            ethValue,
            abi.encodeCall(IJBTerminal.pay, (_destProjectId, token, reclaimAmount, _bene, 0, "", ""))
        );
    }

    function _stubImmediateSourceFeeForgiven(address token, uint256 grossAmount) internal returns (uint256 feeAmount) {
        feeAmount = JBFees.standardFeeAmountFrom(grossAmount);
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (JBConstants.FEE_BENEFICIARY_PROJECT_ID, token)),
            abi.encode(address(0))
        );
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_sourceProjectId, token, feeAmount)),
            ""
        );
    }

    /// @notice Stub source project's accounting context lookup, used by `_tokenAmountOf` when hook
    /// specifications are present (the hook context needs the source token's decimals/currency).
    function _stubSourceAccountingContext(address token) internal {
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _sourceProjectId, token)),
            // forge-lint: disable-next-line(unsafe-typecast)
            abi.encode(JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))}))
        );
    }

    /// @notice Stub a SINGLE pre-routing balanceOf read. Used by tests that revert mid-routing so the
    /// post-routing reads never happen.
    function _stubBSingleBalanceRead(address token, uint256 value) internal {
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, token)),
            abi.encode(value)
        );
    }

    /// @notice Storage slot for `_feeFreeSurplusOf[projectId][token]`. The mapping lives at slot 0 — confirmed
    /// via `forge inspect JBMultiTerminal storage`.
    function _feeFreeSurplusSlot(uint256 projectId, address token) internal pure returns (bytes32) {
        bytes32 outerSlot = keccak256(abi.encode(projectId, uint256(0)));
        return keccak256(abi.encode(token, outerSlot));
    }

    function _readFeeFreeSurplus(uint256 projectId, address token) internal view returns (uint256) {
        return uint256(vm.load(address(_terminal), _feeFreeSurplusSlot(projectId, token)));
    }

    function _seedFeeFreeSurplus(uint256 projectId, address token, uint256 value) internal {
        vm.store(address(_terminal), _feeFreeSurplusSlot(projectId, token), bytes32(value));
    }

    //*********************************************************************//
    // -------------------------- revert paths --------------------------- //
    //*********************************************************************//

    function test_RevertWhen_CallerLacksPermission() external {
        _stubPermission(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                _holder,
                _bene,
                _sourceProjectId,
                JBPermissionIds.CASH_OUT_TOKENS
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryProjectFeeFreeInflowsPaused() external {
        _stubPermission(true);
        _stubBController(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectFeeFreeInflowsPaused.selector, _destProjectId
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_DestinationTerminalNotFound() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);

        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, _mockToken)),
            abi.encode(address(0))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_RecipientProjectTerminalNotFound.selector, _destProjectId, _mockToken
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryProjectHasNoAccountingContexts() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);

        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, _mockToken)),
            abi.encode(address(_terminal))
        );
        _stubBAccountingContexts(new JBAccountingContext[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectHasNoAccountingContexts.selector, _destProjectId
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryProjectNotPaid() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: 0});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectNotPaid.selector, _destProjectId)
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryTokenCountLTMinTokensOut() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        uint256 unrealisticMin = _defaultMintCount * 10;

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, _defaultMintCount, unrealisticMin)
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, unrealisticMin, "", ""
        );
    }

    /// @notice Cross-terminal ERC20 path: destination terminal is OBLIGATED to consume the temporary
    /// approval. If it returns without pulling, `_afterTransferTo` reverts. This is the safety check
    /// that keeps an ill-behaved router from leaving a dangling allowance.
    function test_RevertWhen_CrossTerminal_AllowanceNotConsumed() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: address(_erc20), cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(address(_erc20), type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(address(_erc20), _defaultReclaim);
        uint256 routedAmount = _defaultReclaim - sourceFee;
        _stubCrossTerminalPay({token: address(_erc20), reclaimAmount: routedAmount, mintCount: _defaultMintCount});

        // The destination terminal "forgets" to pull, so the allowance survives the call.
        // _afterTransferTo reads the live allowance — which equals routedAmount because forceApprove
        // ran but the destination never spent it. Revert with the surviving allowance value.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_TemporaryAllowanceNotConsumed.selector,
                address(_erc20),
                address(_otherTerminal),
                routedAmount
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, address(_erc20), _destProjectId, _bene, 0, "", ""
        );
    }

    //*********************************************************************//
    // ---------------------------- happy paths -------------------------- //
    //*********************************************************************//

    function test_HappyPath_SameTerminalSameToken() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        vm.prank(_bene);
        (uint256 reclaimAmount, uint256 beneficiaryTokenCount) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(reclaimAmount, _defaultReclaim, "reclaim should match the store's returned amount");
        assertEq(beneficiaryTokenCount, _defaultMintCount, "beneficiary should receive minted B tokens");
    }

    function test_HappyPath_ReclaimAmountZeroShortCircuits() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: 0});
        _stubABalanceRead(_mockToken, 0);

        vm.prank(_bene);
        (uint256 reclaim, uint256 mintCount) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(reclaim, 0, "no reclaim");
        assertEq(mintCount, 0, "no mint");
    }

    /// @notice Cash-out count of zero MUST still allow data-hook-driven reclaim to flow. The burn step
    /// is skipped (no controller burn call expected), but the rest of the routing is identical.
    function test_HappyPath_CashOutCountZero_WithReclaimFromDataHook() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: 0, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        // Note: _stubCashoutSide skips burnTokensOf when cashOutCount == 0 — calling burn would revert
        // with "expected call but not made" if asserted. The test passing proves no burn was attempted.
        vm.prank(_bene);
        (uint256 r, uint256 m) =
            _terminal.cashOutAndPay(_holder, _sourceProjectId, 0, _mockToken, _destProjectId, _bene, 0, "", "");

        assertEq(r, _defaultReclaim, "reclaim flowed despite zero burn");
        assertEq(m, _defaultMintCount, "mint count passes through");
    }

    /// @notice Operator (sender != holder) with permission should succeed. The pay flow's `payer` in
    /// the recordPaymentFrom call is `_msgSender()` — which is the operator, not the holder.
    function test_HappyPath_OperatorWithPermission() external {
        _stubPermissionFor({sender: _operator, account: _holder, granted: true});
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPayWithPayer({
            payer: _operator, token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount
        });

        vm.prank(_operator);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, _defaultReclaim);
        assertEq(m, _defaultMintCount);
    }

    //*********************************************************************//
    // ----------------- fee-free surplus credit accounting -------------- //
    //*********************************************************************//

    /// @notice Direct verification: `_feeFreeSurplusOf[B][token]` is incremented by exactly the delivery
    /// delta after the routing. This is the load-bearing economic property — the deferred fee that was
    /// skipped on the source side is bound on the destination side via this credit.
    function test_HappyPath_FeeFreeSurplusCreditLandsOnDestination() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 100, balanceAfter: 100 + _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), 0, "starts empty");

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(
            _readFeeFreeSurplus(_destProjectId, _mockToken),
            _defaultReclaim,
            "credit equals the delivery delta on B's bucket"
        );
    }

    /// @notice The credit is ADDITIVE on top of any pre-existing fee-free surplus B already had — not
    /// an overwrite. A B that already accumulated fee-free credits from intra-terminal payouts must
    /// keep them when receiving a cross-project inflow.
    function test_HappyPath_FeeFreeSurplusCreditAccumulates() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 1000, balanceAfter: 1000 + _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        uint256 preExisting = 777;
        _seedFeeFreeSurplus(_destProjectId, _mockToken, preExisting);

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(
            _readFeeFreeSurplus(_destProjectId, _mockToken),
            preExisting + _defaultReclaim,
            "additive on top of pre-existing balance"
        );
    }

    /// @notice After the credit, `_capFeeFreeSurplus` runs on the destination bucket. If the new total
    /// (pre-existing + credit) exceeds the post-routing balance, the surplus must be capped down to the
    /// remaining balance. Without this cap, B's later zero-tax cashouts would over-fee phantom amounts.
    function test_HappyPath_DestFeeFreeSurplusCappedToBalance() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        // Post-routing balance fully covers the skipped reclaim, but is LOWER than (preExisting + credit).
        // The cap should bite, clamping _feeFreeSurplusOf to the post-routing balance.
        uint256 postBalance = _defaultReclaim;
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: postBalance});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        // Seed a high pre-existing fee-free that the new credit pushes well above the actual balance.
        uint256 preExisting = 10_000;
        _seedFeeFreeSurplus(_destProjectId, _mockToken, preExisting);

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), postBalance, "capped to remaining balance");
    }

    /// @notice Mirror invariant: when A's remaining balance still covers its fee-free surplus, the cap
    /// is a no-op and the surplus survives untouched. Without this guarantee, a cashout would
    /// inadvertently destroy fee-free accounting for projects that haven't run out of balance.
    function test_HappyPath_SourceFeeFreeSurplus_NotCapped_WhenBalanceCovers() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        // Source remaining balance is HIGHER than its existing fee-free surplus — cap must be a no-op.
        _stubABalanceRead(_mockToken, 10_000);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        uint256 sourceFeeFree = 100;
        _seedFeeFreeSurplus(_sourceProjectId, _mockToken, sourceFeeFree);

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(
            _readFeeFreeSurplus(_sourceProjectId, _mockToken),
            sourceFeeFree,
            "source fee-free preserved when balance still covers it"
        );
    }

    /// @notice Source-side `_capFeeFreeSurplus` runs BEFORE the routing. If A had a pre-existing fee-free
    /// surplus and the post-burn balance is now below it, the cap must reduce A's fee-free counter to
    /// the remaining balance. This preserves the invariant that `_feeFreeSurplusOf[A]` never exceeds A's
    /// actual balance — without it, A's next zero-tax cashout would over-fee.
    function test_HappyPath_SourceFeeFreeSurplusCappedAfterOutflow() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        // Source's remaining balance after the cashout is LOWER than its existing fee-free surplus.
        uint256 sourceRemaining = 100;
        _stubABalanceRead(_mockToken, sourceRemaining);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        // Seed source's fee-free surplus high so cap MUST fire.
        uint256 sourceFeeFree = 5000;
        _seedFeeFreeSurplus(_sourceProjectId, _mockToken, sourceFeeFree);

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(
            _readFeeFreeSurplus(_sourceProjectId, _mockToken),
            sourceRemaining,
            "source fee-free capped to its remaining balance after outflow"
        );
    }

    //*********************************************************************//
    // ------------------ multi-context routing invariants --------------- //
    //*********************************************************************//

    /// @notice Cross-token-only growth no longer proves that the source-token reclaim was retained in the
    /// same value basis. The route reverts unless enough `tokenToReclaim` was also retained or fee-bound.
    function test_RevertWhen_MultiContext_OnlySwapTargetTokenGrows() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);

        // B has two contexts: _mockToken (input) and _otherTokenAddr (the swap target).
        _stubBAccountingContexts(_twoTokenContext(_mockToken, _otherTokenAddr));

        // tokenA (_mockToken) DOES NOT grow; tokenB (_otherTokenAddr) grows by reclaim.
        _stubBTwoContextBalanceSequence({
            tokenA: _mockToken,
            tokenB: _otherTokenAddr,
            beforeA: 0,
            beforeB: 50,
            afterA: 0,
            afterB: 50 + _defaultReclaim
        });
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectNotPaid.selector, _destProjectId)
        );
        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), 0, "no credit on input-token bucket");
        assertEq(_readFeeFreeSurplus(_destProjectId, _otherTokenAddr), 0, "revert rolls back swap-token credit");
    }

    /// @notice Every destination context that grows is credited, provided the source-token growth fully
    /// fee-binds the skipped reclaim.
    function test_HappyPath_MultiContext_AllGrowingContextsCredited() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);

        // B has [_mockToken (first), _otherTokenAddr (second)].
        _stubBAccountingContexts(_twoTokenContext(_mockToken, _otherTokenAddr));

        // Both contexts grow. tokenA covers the source-token reclaim; tokenB also gets its own credit.
        _stubBTwoContextBalanceSequence({
            tokenA: _mockToken, tokenB: _otherTokenAddr, beforeA: 0, beforeB: 0, afterA: _defaultReclaim, afterB: 999
        });
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), _defaultReclaim, "source-token context gets credited");
        assertEq(_readFeeFreeSurplus(_destProjectId, _otherTokenAddr), 999, "second grown context is credited");
    }

    //*********************************************************************//
    // -------------------- cross-terminal routing path ------------------ //
    //*********************************************************************//

    /// @notice Cross-terminal ERC20 happy path: destination terminal is a different address. The flow
    /// uses `_beforeTransferTo` (forceApprove on the real ERC20), then `destinationTerminal.pay()`,
    /// then `_afterTransferTo` (asserts the live allowance went back to zero). Coverage was missing —
    /// every prior test routed through the same terminal.
    function test_HappyPath_CrossTerminal_ERC20() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: address(_erc20), cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(address(_erc20), type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(address(_erc20), _defaultReclaim);
        _stubCrossTerminalPay({
            token: address(_erc20), reclaimAmount: _defaultReclaim - sourceFee, mintCount: _defaultMintCount
        });

        // forceApprove runs against the real ERC20 (sets allowance = net reclaim). The mocked external
        // pay() doesn't actually consume the allowance, so for the post-call `_afterTransferTo` invariant
        // check to pass, we mock the live allowance() read to return 0 (simulating a well-behaved router
        // that pulled all the approved tokens during its pay implementation).
        vm.mockCall(
            address(_erc20),
            abi.encodeCall(IERC20.allowance, (address(_terminal), address(_otherTerminal))),
            abi.encode(0)
        );

        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, address(_erc20), _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, _defaultReclaim);
        assertEq(m, _defaultMintCount);
        assertEq(_readFeeFreeSurplus(_destProjectId, address(_erc20)), 0, "external route is fee-paid");
    }

    /// @notice Cross-terminal NATIVE_TOKEN happy path: destination terminal is a different address and
    /// the reclaim is ETH. `_beforeTransferTo` returns the amount as `payValue` (no approval needed),
    /// the external `pay()` is called with `{value: amount}`, and `_afterTransferTo` is a no-op for
    /// native. The terminal needs an ETH balance to actually forward the value.
    function test_HappyPath_CrossTerminal_NativeToken() external {
        // Fund the terminal so the value-bearing external call has ETH to forward.
        vm.deal(address(_terminal), _defaultReclaim);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({
            token: JBConstants.NATIVE_TOKEN, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim
        });
        _stubABalanceRead(JBConstants.NATIVE_TOKEN, type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(JBConstants.NATIVE_TOKEN, _defaultReclaim);
        _stubCrossTerminalPay({
            token: JBConstants.NATIVE_TOKEN, reclaimAmount: _defaultReclaim - sourceFee, mintCount: _defaultMintCount
        });

        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, JBConstants.NATIVE_TOKEN, _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, _defaultReclaim);
        assertEq(m, _defaultMintCount);
        assertEq(_readFeeFreeSurplus(_destProjectId, JBConstants.NATIVE_TOKEN), 0, "external route is fee-paid");
    }

    //*********************************************************************//
    // ----------------------- cashout hook spec path -------------------- //
    //*********************************************************************//

    /// @notice Hook spec branch with a noop spec. The `noop: true` entry must SKIP the hook call and
    /// NOT count toward `amountEligibleForFees`. Without this, a noop spec would burn a fee on amounts
    /// that the hook never received.
    function test_HappyPath_WithCashOutHookSpec_NoopSkipsHookCall() external {
        _stubPermission(true);
        _stubBController(true);

        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](1);
        specs[0] = JBCashOutHookSpecification({hook: _mockHook, noop: true, amount: 1e6, metadata: ""});

        _stubCashoutSideWithSpecs({
            token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim, specs: specs
        });

        // Hook spec branch invokes `_tokenAmountOf` on the SOURCE project to build the hook context.
        _stubSourceAccountingContext(_mockToken);

        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        // No mockExpect on the hook — it must NOT be called.
        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, _defaultReclaim);
        assertEq(m, _defaultMintCount);
    }

    /// @notice Hook spec with a feeless hook. The hook IS called with the full spec amount (no fee
    /// deduction). No fee path is exercised — `amountEligibleForFees` stays zero, so `_takeFeeFrom`
    /// is not invoked. This is the simpler of the two hook variants — covers the `if
    /// (hookSpecifications.length != 0)` branch without dragging in the deferred fee plumbing.
    function test_HappyPath_WithCashOutHookSpec_FeelessHook() external {
        _stubPermission(true);
        _stubBController(true);

        uint256 hookAmount = 1e6;
        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](1);
        specs[0] = JBCashOutHookSpecification({hook: _mockHook, noop: false, amount: hookAmount, metadata: ""});

        _stubCashoutSideWithSpecs({
            token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim, specs: specs
        });

        // Hook spec branch invokes `_tokenAmountOf` on the SOURCE project to build the hook context.
        _stubSourceAccountingContext(_mockToken);

        // Hook is feeless → no fee deduction on the hook amount.
        mockExpect(
            address(feelessAddresses),
            abi.encodeCall(IJBFeelessAddresses.isFeelessFor, (address(_mockHook), _sourceProjectId)),
            abi.encode(true)
        );

        // The forwarded amount equals the spec amount (no fee subtracted).
        // forge-lint: disable-next-line(unsafe-typecast)
        JBTokenAmount memory reclaimedAmt = JBTokenAmount({
            token: _mockToken,
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(_mockToken)),
            value: _defaultReclaim
        });
        JBTokenAmount memory forwardedAmt = JBTokenAmount({
            token: _mockToken,
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(_mockToken)),
            value: hookAmount
        });

        // The cash out beneficiary inside the hook context is `address(this)` (the terminal custodies
        // the reclaim mid-flow) — NOT the user-passed `_bene`. This is critical: documents that hooks
        // see the terminal as the beneficiary in the cross-project flow.
        JBAfterCashOutRecordedContext memory ctx = JBAfterCashOutRecordedContext({
            holder: _holder,
            projectId: _sourceProjectId,
            rulesetId: _emptyRuleset().id,
            cashOutCount: _defaultCashOutCount,
            reclaimedAmount: reclaimedAmt,
            forwardedAmount: forwardedAmt,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            beneficiary: payable(address(_terminal)),
            hookMetadata: "",
            cashOutMetadata: ""
        });
        mockExpect(address(_mockHook), abi.encodeCall(IJBCashOutHook.afterCashOutRecordedWith, (ctx)), "");

        // Post-hook allowance check (mock-token has no code, so allowance call needs to be mocked).
        vm.mockCall(
            address(_mockToken),
            abi.encodeCall(IERC20.allowance, (address(_terminal), address(_mockHook))),
            abi.encode(0)
        );

        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: _defaultMintCount});

        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, _defaultReclaim);
        assertEq(m, _defaultMintCount);
    }

    //*********************************************************************//
    // ------------------------------ fuzz ------------------------------- //
    //*********************************************************************//

    /// @notice Fuzz the reclaim and mint counts. The minted count is what the destination terminal returns,
    /// passed through to the caller.
    function testFuzz_SameTerminal_MintPassThrough(uint128 reclaimAmount, uint128 mintCount) external {
        vm.assume(reclaimAmount > 0 && mintCount > 0);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: reclaimAmount});

        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: reclaimAmount});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: reclaimAmount, mintCount: mintCount});

        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, reclaimAmount, "reclaim pass-through");
        assertEq(m, mintCount, "mint count pass-through");
    }

    /// @notice Fuzz: any `minTokensOut` strictly greater than the actual mint count must revert.
    function testFuzz_RevertWhen_MinTokensOutTooHigh(uint64 mintCount, uint64 minTokensOut) external {
        vm.assume(mintCount > 0 && minTokensOut > mintCount);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: _defaultReclaim, mintCount: mintCount});

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, mintCount, minTokensOut)
        );

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, minTokensOut, "", ""
        );
    }

    /// @notice Fuzz: the fee-free credit equals the delivery delta on B's bucket — no matter the amount,
    /// the pre-existing balance, or any prior credit. Property: `creditAfter == creditBefore + (balanceAfter -
    /// balanceBefore)`, then capped to balanceAfter.
    function testFuzz_FeeFreeSurplusCreditEqualsDelta(
        uint96 preExistingCredit,
        uint96 balanceBefore,
        uint96 deliveryDelta
    )
        external
    {
        vm.assume(deliveryDelta > 0);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: deliveryDelta});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));

        uint256 balanceAfter = uint256(balanceBefore) + uint256(deliveryDelta);
        _stubBBalanceSequence({token: _mockToken, balanceBefore: balanceBefore, balanceAfter: balanceAfter});
        _stubSameTerminalPay({token: _mockToken, reclaimAmount: deliveryDelta, mintCount: _defaultMintCount});

        _seedFeeFreeSurplus(_destProjectId, _mockToken, preExistingCredit);

        vm.prank(_bene);
        _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        // Expected: pre-existing + delta, then capped to balanceAfter.
        uint256 expected = uint256(preExistingCredit) + uint256(deliveryDelta);
        if (expected > balanceAfter) expected = balanceAfter;
        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), expected, "credit = delta + pre-existing, capped");
    }

    /// @notice Fuzz the cross-terminal native-token path. The mint count is what the destination terminal
    /// returns and must pass through unchanged regardless of the ETH value forwarded.
    function testFuzz_CrossTerminal_NativeToken_MintPassThrough(uint64 reclaimAmount, uint64 mintCount) external {
        vm.assume(reclaimAmount > 0 && mintCount > 0);

        // Fund the terminal with at least the reclaim amount so the value-bearing external call has ETH.
        vm.deal(address(_terminal), reclaimAmount);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({
            token: JBConstants.NATIVE_TOKEN, cashOutCount: _defaultCashOutCount, reclaimAmount: reclaimAmount
        });
        _stubABalanceRead(JBConstants.NATIVE_TOKEN, type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(JBConstants.NATIVE_TOKEN, reclaimAmount);
        _stubCrossTerminalPay({
            token: JBConstants.NATIVE_TOKEN, reclaimAmount: reclaimAmount - sourceFee, mintCount: mintCount
        });

        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAndPay(
            _holder, _sourceProjectId, _defaultCashOutCount, JBConstants.NATIVE_TOKEN, _destProjectId, _bene, 0, "", ""
        );

        assertEq(r, reclaimAmount, "reclaim pass-through");
        assertEq(m, mintCount, "mint count pass-through");
        assertEq(_readFeeFreeSurplus(_destProjectId, JBConstants.NATIVE_TOKEN), 0, "external route is fee-paid");
    }
}
