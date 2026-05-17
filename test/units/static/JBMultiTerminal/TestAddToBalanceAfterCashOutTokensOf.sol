// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "../../../mock/MockERC20.sol";
import {JBPayType} from "../../../../src/enums/JBPayType.sol";
import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {JBPermissioned} from "../../../../src/abstract/JBPermissioned.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBFees} from "../../../../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../../../../src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice Unit tests for `JBMultiTerminal.cashOutAndDeliver(..., JBPayType.DonationOnly)`. Sibling of
/// `TestPayAfterCashOutTokensOf` — same source-side cash-out flow, but the reclaim is added to B's balance via
/// `addToBalanceOf` (no destination tokens minted). Same-terminal retained balances are fee-free credited;
/// external/router routes pay the source fee up front and route net. Held-fee return on the destination side is
/// unavailable so this entrypoint cannot unlock B's held fees.
/// @dev Storage of internal `_feeFreeSurplusOf` is read via `vm.load` (slot 0 — confirmed via
/// `forge inspect`) so tests can directly verify the fee-free credit lands on the right (project, token)
/// bucket. Same `mockExpectSubsequent` pattern as the pay variant for the `STORE.balanceOf` before/after
/// snapshots.
contract TestAddToBalanceAfterCashOutTokensOf_Local is JBMultiTerminalSetup {
    // -- Source project (A) --
    uint64 _sourceProjectId = 1;
    uint256 _defaultCashOutCount = 1e18;

    // -- Destination project (B) --
    uint64 _destProjectId = 2;

    // -- Actors --
    address _holder = makeAddr("holder");
    address _caller = makeAddr("caller");

    // -- Tokens --
    address _mockToken = makeAddr("mockToken");
    address _otherTokenAddr = makeAddr("otherToken");
    MockERC20 _erc20;

    // -- Mocks --
    IJBTerminal _otherTerminal = IJBTerminal(makeAddr("otherTerminal"));

    // -- Defaults --
    uint256 _defaultReclaim = 1e9;

    function setUp() public {
        super.multiTerminalSetup();
        _erc20 = new MockERC20("Token", "TKN");
    }

    //*********************************************************************//
    // ---------------------------- helpers ------------------------------ //
    //*********************************************************************//

    function _stubPermission(bool granted) internal {
        mockExpect(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (_caller, _holder, _sourceProjectId, JBPermissionIds.CASH_OUT_TOKENS, true, true)
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
    /// fee-free inflows?") and gets inverted into the underlying `pauseCrossProjectFeeFreeInflows` flag.
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
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordCashOutFor, (_holder, _sourceProjectId, cashOutCount, token, true, "")
            ),
            abi.encode(
                    _emptyRuleset(),
                    reclaimAmount,
                    JBConstants.MAX_CASH_OUT_TAX_RATE,
                    new JBCashOutHookSpecification[](0)
                )
        );

        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_sourceProjectId)), abi.encode(address(this))
        );

        if (cashOutCount > 0) {
            mockExpect(
                address(this),
                abi.encodeCall(IJBController.burnTokensOf, (_holder, _sourceProjectId, cashOutCount, "")),
                ""
            );
        }
    }

    function _stubABalanceRead(address token, uint256 value) internal {
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _sourceProjectId, token)),
            abi.encode(value)
        );
    }

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

    /// @notice Stub the same-terminal `_addToBalanceOf` flow for routing into B. The internal
    /// `_addToBalanceOf` is invoked with `shouldReturnHeldFees: false` (hardcoded in the cross-project
    /// entrypoint) and forwards `metadata` as `addToBalanceMetadata`. It then calls
    /// `STORE.recordAddedBalanceFor` with the gross amount (no held-fee return path is exercised).
    function _stubSameTerminalAddToBalance(address token, uint256 reclaimAmount) internal {
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, token)),
            abi.encode(address(_terminal))
        );

        // _addToBalanceOf → STORE.recordAddedBalanceFor (no held-fee return because false hardcoded).
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_destProjectId, token, reclaimAmount)),
            ""
        );
    }

    /// @notice Stub the cross-terminal external `addToBalanceOf` path. `_externalAddToBalance` calls
    /// `terminal.addToBalanceOf` with `shouldReturnHeldFees: false`, no memo, and the supplied metadata.
    function _stubCrossTerminalAddToBalance(
        address token,
        uint256 reclaimAmount,
        bytes memory addToBalanceMetadata
    )
        internal
    {
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, token)),
            abi.encode(address(_otherTerminal))
        );

        uint256 ethValue = token == JBConstants.NATIVE_TOKEN ? reclaimAmount : 0;

        vm.mockCall(
            address(_otherTerminal),
            ethValue,
            abi.encodeCall(
                IJBTerminal.addToBalanceOf, (_destProjectId, token, reclaimAmount, false, "", addToBalanceMetadata)
            ),
            ""
        );
        vm.expectCall(
            address(_otherTerminal),
            ethValue,
            abi.encodeCall(
                IJBTerminal.addToBalanceOf, (_destProjectId, token, reclaimAmount, false, "", addToBalanceMetadata)
            )
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

    /// @notice Storage slot for `_feeFreeSurplusOf[projectId][token]` (slot 0 per `forge inspect`).
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
                _caller,
                _sourceProjectId,
                JBPermissionIds.CASH_OUT_TOKENS
            )
        );

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
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

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );
    }

    function test_RevertWhen_BeneficiaryProjectNotPaid() external {
        // Same-terminal addToBalance succeeds at the store level but the post-routing balance read returns
        // the same value as before (no delivery delta) — revert prevents the fee-skip leak.
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 100, balanceAfter: 100});
        _stubSameTerminalAddToBalance({token: _mockToken, reclaimAmount: _defaultReclaim});

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectNotPaid.selector, _destProjectId)
        );

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );
    }

    //*********************************************************************//
    // ---------------------------- happy paths -------------------------- //
    //*********************************************************************//

    /// @notice Same-terminal happy path. The reclaim is added to B's balance via the internal
    /// `_addToBalanceOf` (no token mint) and the fee-free credit lands by the delivery delta.
    function test_HappyPath_SameTerminalSameToken() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalAddToBalance({token: _mockToken, reclaimAmount: _defaultReclaim});

        vm.prank(_caller);
        (uint256 reclaim,) = _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        assertEq(reclaim, _defaultReclaim, "reclaim equals the store's returned amount");
        assertEq(
            _readFeeFreeSurplus(_destProjectId, _mockToken),
            _defaultReclaim,
            "fee-free credit lands on B by the delivery delta"
        );
    }

    /// @notice Reclaim of zero short-circuits before any routing. No primaryTerminalOf, no
    /// accountingContextsOf, no balance reads — the function returns 0 immediately.
    function test_HappyPath_ReclaimAmountZeroShortCircuits() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: 0});
        _stubABalanceRead(_mockToken, 0);

        vm.prank(_caller);
        (uint256 reclaim,) = _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        assertEq(reclaim, 0);
    }

    /// @notice Cross-token-only growth no longer proves that the source-token reclaim was retained in the
    /// same value basis. The other-token bucket may be credited internally during the scan, but the route
    /// reverts unless enough `tokenToReclaim` was also retained or the unretained source amount was fee-bound.
    function test_RevertWhen_MultiContext_OnlyNonSourceTokenGrows() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);

        // B has [_mockToken, _otherTokenAddr]. Reclaim is in _mockToken; the routing deposits into
        // _otherTokenAddr (simulated via the balance sequence).
        JBAccountingContext[] memory contexts = new JBAccountingContext[](2);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken))});
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[1] =
            JBAccountingContext({token: _otherTokenAddr, decimals: 18, currency: uint32(uint160(_otherTokenAddr))});
        _stubBAccountingContexts(contexts);

        // Pre-routing reads happen for both contexts in array order.
        bytes[] memory aReturns = new bytes[](2);
        aReturns[0] = abi.encode(uint256(0));
        aReturns[1] = abi.encode(uint256(0)); // didn't grow
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _mockToken)),
            aReturns
        );

        bytes[] memory bReturns = new bytes[](3);
        bReturns[0] = abi.encode(uint256(50));
        bReturns[1] = abi.encode(uint256(50 + _defaultReclaim)); // grew
        bReturns[2] = abi.encode(uint256(50 + _defaultReclaim)); // cap-after-credit read
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _otherTokenAddr)),
            bReturns
        );

        _stubSameTerminalAddToBalance({token: _mockToken, reclaimAmount: _defaultReclaim});

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectNotPaid.selector, _destProjectId)
        );
        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), 0, "no credit on input token");
        assertEq(_readFeeFreeSurplus(_destProjectId, _otherTokenAddr), 0, "revert rolls back other-token credit");
    }

    /// @notice If the source-token bucket fully covers the reclaim, every positive destination-context
    /// delta is credited to its own fee-free surplus bucket.
    function test_HappyPath_MultiContext_CreditsAllGrowingBucketsWhenSourceTokenCovered() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](2);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken))});
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[1] =
            JBAccountingContext({token: _otherTokenAddr, decimals: 18, currency: uint32(uint160(_otherTokenAddr))});
        _stubBAccountingContexts(contexts);

        uint256 otherDelta = 123;

        bytes[] memory aReturns = new bytes[](3);
        aReturns[0] = abi.encode(uint256(0));
        aReturns[1] = abi.encode(_defaultReclaim);
        aReturns[2] = abi.encode(_defaultReclaim);
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _mockToken)),
            aReturns
        );

        bytes[] memory bReturns = new bytes[](3);
        bReturns[0] = abi.encode(uint256(50));
        bReturns[1] = abi.encode(uint256(50 + otherDelta));
        bReturns[2] = abi.encode(uint256(50 + otherDelta));
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _otherTokenAddr)),
            bReturns
        );

        _stubSameTerminalAddToBalance({token: _mockToken, reclaimAmount: _defaultReclaim});

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), _defaultReclaim, "source token credited");
        assertEq(_readFeeFreeSurplus(_destProjectId, _otherTokenAddr), otherDelta, "other token credited");
    }

    /// @notice Cross-terminal happy path with ERC20. Routing uses `_externalAddToBalance` which forceApproves
    /// the token, calls `destinationTerminal.addToBalanceOf` with `shouldReturnHeldFees: false`, and asserts
    /// the post-call allowance is zero. The `addToBalanceMetadata` parameter is forwarded verbatim.
    function test_HappyPath_CrossTerminal_ERC20_ForwardsMetadata() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: address(_erc20), cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(address(_erc20), type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(address(_erc20), _defaultReclaim);

        bytes memory atbMeta = hex"deadbeef";
        _stubCrossTerminalAddToBalance({
            token: address(_erc20), reclaimAmount: _defaultReclaim - sourceFee, addToBalanceMetadata: atbMeta
        });

        // Mock the post-call allowance read (consumed by `_afterTransferTo`).
        vm.mockCall(
            address(_erc20),
            abi.encodeCall(IERC20.allowance, (address(_terminal), address(_otherTerminal))),
            abi.encode(0)
        );

        vm.prank(_caller);
        (uint256 reclaim,) = _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            address(_erc20),
            _destProjectId,
            address(0),
            0,
            "",
            atbMeta,
            JBPayType.DonationOnly
        );

        assertEq(reclaim, _defaultReclaim);
        assertEq(_readFeeFreeSurplus(_destProjectId, address(_erc20)), 0, "external route is fee-paid, not credited");
    }

    /// @notice Cross-terminal happy path with the native token. The terminal's ETH balance is forwarded as
    /// `msg.value` to the external `addToBalanceOf`. No allowance dance for native.
    function test_HappyPath_CrossTerminal_NativeToken() external {
        vm.deal(address(_terminal), _defaultReclaim);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({
            token: JBConstants.NATIVE_TOKEN, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim
        });
        _stubABalanceRead(JBConstants.NATIVE_TOKEN, type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(JBConstants.NATIVE_TOKEN, _defaultReclaim);
        _stubCrossTerminalAddToBalance({
            token: JBConstants.NATIVE_TOKEN, reclaimAmount: _defaultReclaim - sourceFee, addToBalanceMetadata: ""
        });

        vm.prank(_caller);
        (uint256 reclaim,) = _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            JBConstants.NATIVE_TOKEN,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        assertEq(reclaim, _defaultReclaim);
        assertEq(_readFeeFreeSurplus(_destProjectId, JBConstants.NATIVE_TOKEN), 0, "external route is fee-paid");
    }

    //*********************************************************************//
    // -------------------- security: held-fee unlock -------------------- //
    //*********************************************************************//

    /// @notice Critical invariant: this entrypoint MUST hardcode `shouldReturnHeldFees: false`. The
    /// cross-terminal stub asserts `addToBalanceOf` is called with `shouldReturnHeldFees: false`. If the
    /// implementation ever flips this to `true`, the call signature wouldn't match and the test would
    /// revert with "expected call but not made".
    /// @dev This is the load-bearing safety property called out in the natspec: combining a source-side
    /// fee skip with a destination-side held-fee unlock would create a fee-bypass vector. The
    /// `_efficientAddToBalance` helper hardcodes `false`, and this entrypoint uses that helper — but a
    /// future refactor could regress this. The test pins it.
    function test_HeldFeeReturn_HardcodedFalse_OnCrossTerminal() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: address(_erc20), cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(address(_erc20), type(uint128).max);
        uint256 sourceFee = _stubImmediateSourceFeeForgiven(address(_erc20), _defaultReclaim);

        // Stub asserts shouldReturnHeldFees == false in the encoded calldata.
        _stubCrossTerminalAddToBalance({
            token: address(_erc20), reclaimAmount: _defaultReclaim - sourceFee, addToBalanceMetadata: ""
        });

        vm.mockCall(
            address(_erc20),
            abi.encodeCall(IERC20.allowance, (address(_terminal), address(_otherTerminal))),
            abi.encode(0)
        );

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            address(_erc20),
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        // The cross-terminal stub's expectCall fails with "expected call but not made" if the implementation
        // doesn't pass `shouldReturnHeldFees: false`. Reaching this assertion means the invariant holds.
        assertTrue(true, "shouldReturnHeldFees hardcoded to false");
    }

    //*********************************************************************//
    // ------------------ fee-free surplus credit accounting -------------- //
    //*********************************************************************//

    /// @notice Direct verification: `_feeFreeSurplusOf[B][token]` is incremented by exactly the delivery
    /// delta after the routing — additive on top of any pre-existing balance.
    function test_HappyPath_FeeFreeSurplusCreditAccumulates() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide({token: _mockToken, cashOutCount: _defaultCashOutCount, reclaimAmount: _defaultReclaim});
        _stubABalanceRead(_mockToken, type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({token: _mockToken, balanceBefore: 1000, balanceAfter: 1000 + _defaultReclaim});
        _stubSameTerminalAddToBalance({token: _mockToken, reclaimAmount: _defaultReclaim});

        uint256 preExisting = 777;
        _seedFeeFreeSurplus(_destProjectId, _mockToken, preExisting);

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        assertEq(
            _readFeeFreeSurplus(_destProjectId, _mockToken),
            preExisting + _defaultReclaim,
            "additive on top of pre-existing balance"
        );
    }

    //*********************************************************************//
    // ------------------------------ fuzz ------------------------------- //
    //*********************************************************************//

    /// @notice Fuzz: the fee-free credit equals the delivery delta, capped to balanceAfter — same property
    /// as the pay variant, exercised through the addToBalance routing.
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
        _stubSameTerminalAddToBalance({token: _mockToken, reclaimAmount: deliveryDelta});

        _seedFeeFreeSurplus(_destProjectId, _mockToken, preExistingCredit);

        vm.prank(_caller);
        _terminal.cashOutAndDeliver(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            address(0),
            0,
            "",
            "",
            JBPayType.DonationOnly
        );

        uint256 expected = uint256(preExistingCredit) + uint256(deliveryDelta);
        if (expected > balanceAfter) expected = balanceAfter;
        assertEq(_readFeeFreeSurplus(_destProjectId, _mockToken), expected, "credit = delta + pre-existing, capped");
    }
}
