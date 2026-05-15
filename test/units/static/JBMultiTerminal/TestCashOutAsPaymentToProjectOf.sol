// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {JBPermissioned} from "../../../../src/abstract/JBPermissioned.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../../../../src/structs/JBCashOutHookSpecification.sol";
import {JBCashOutToProjectContext} from "../../../../src/structs/JBCashOutToProjectContext.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice Unit tests for `JBMultiTerminal.cashOutAsPaymentToProjectOf`. The flow burns source-project tokens,
/// routes the reclaim into a destination project via a caller-declared destination terminal, and credits
/// `_feeFreeSurplusOf[B]` by the `STORE.balanceOf` delta that lands back on this terminal under B's name.
/// @dev Heavy mocking — same convention as `TestCashOutTokensOf` and `TestPay`. `mockExpectSubsequent` is used
/// to simulate the `STORE.balanceOf` before/after pattern with sequenced return values.
contract TestCashOutAsPaymentToProjectOf_Local is JBMultiTerminalSetup {
    // -- Source project (A) --
    uint64 _sourceProjectId = 1;
    uint256 _defaultCashOutCount = 1e18;

    // -- Destination project (B) --
    uint64 _destProjectId = 2;

    // -- Actors --
    address _holder = makeAddr("holder");
    address payable _bene = payable(makeAddr("beneficiary"));

    // -- Tokens --
    address _mockToken = makeAddr("mockToken");

    // -- Defaults --
    uint256 _defaultReclaim = 1e9;
    uint256 _defaultMintCount = 5e8;

    function setUp() public {
        super.multiTerminalSetup();
    }

    //*********************************************************************//
    // ---------------------------- helpers ------------------------------ //
    //*********************************************************************//

    function _stubPermission(bool granted) internal {
        mockExpect(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (_bene, _holder, _sourceProjectId, JBPermissionIds.CASH_OUT_TOKENS, true, true)
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

    /// @notice Stub B's controller + current-ruleset response. The boolean parameter expresses the test's
    /// intent ("does B accept fee-free inflows?"); the helper inverts it into the underlying
    /// `pauseCrossProjectFeeFreeInflows` flag so call sites stay readable.
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

    function _defaultRouting() internal view returns (JBCashOutToProjectContext memory) {
        return JBCashOutToProjectContext({
            destinationTerminal: IJBTerminal(address(0)), // defaults to primaryTerminalOf(B, tokenToReclaim)
            tokenForBeneficiaryProject: _mockToken,
            minDeliveredToB: 0
        });
    }

    /// @notice Stub the cashout + burn side. Returns the gross reclaim amount and an empty hook spec array.
    function _stubCashoutSide(uint256 reclaimAmount) internal {
        // recordCashOutFor — the new entrypoint always passes `beneficiaryIsFeeless: true`.
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordCashOutFor,
                (_holder, _sourceProjectId, _defaultCashOutCount, _mockToken, true, "")
            ),
            abi.encode(
                _emptyRuleset(), reclaimAmount, JBConstants.MAX_CASH_OUT_TAX_RATE, new JBCashOutHookSpecification[](0)
            )
        );

        // Source-project controller resolution + burn.
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_sourceProjectId)), abi.encode(address(this))
        );
        mockExpect(
            address(this),
            abi.encodeCall(IJBController.burnTokensOf, (_holder, _sourceProjectId, _defaultCashOutCount, "")),
            ""
        );
    }

    /// @notice Stub the reads of `STORE.balanceOf` on B's bucket. The terminal makes 2 reads when the credit
    /// is zero (cap short-circuits) and 3 reads when the credit is nonzero (cap also reads). The helper picks
    /// the right shape based on whether `balanceAfter > balanceBefore`.
    /// @param balanceBefore Read before the pay.
    /// @param balanceAfter Read after the pay. The credit-equals-delta property uses
    /// `balanceAfter - balanceBefore`.
    function _stubBBalanceSequence(uint256 balanceBefore, uint256 balanceAfter) internal {
        bool capFires = balanceAfter > balanceBefore;
        bytes[] memory returns_ = new bytes[](capFires ? 3 : 2);
        returns_[0] = abi.encode(balanceBefore);
        returns_[1] = abi.encode(balanceAfter);
        if (capFires) returns_[2] = abi.encode(balanceAfter); // cap reads the same value as the after-snapshot
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _mockToken)),
            returns_
        );
    }

    /// @notice Stub A's `_capFeeFreeSurplus` balance read (one read; result doesn't affect the path when A has
    /// no fee-free credit, which is the default in unit tests).
    function _stubABalanceRead(uint256 value) internal {
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _sourceProjectId, _mockToken)),
            abi.encode(value)
        );
    }

    /// @notice Stub the same-terminal pay flow (`_pay` internal) for routing into B.
    /// @dev payer == msg.sender via `_msgSender()` — under `vm.prank(_bene)`, that's `_bene`.
    function _stubSameTerminalPay(uint256 reclaimAmount, uint256 mintCount) internal {
        // Resolve B's primary terminal — return THIS terminal to take the same-terminal path.
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, _mockToken)),
            abi.encode(address(_terminal))
        );

        JBAccountingContext memory ctx =
            JBAccountingContext({token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken))});
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _destProjectId, _mockToken)),
            abi.encode(ctx)
        );

        JBTokenAmount memory tokenAmount = JBTokenAmount({
            token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken)), value: reclaimAmount
        });

        // _pay -> STORE.recordPaymentFrom (payer = _bene under prank).
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPaymentFrom, (_bene, tokenAmount, _destProjectId, _bene, "")),
            abi.encode(_emptyRuleset(), mintCount, new bytes(0))
        );

        // _pay -> controllerOf(B) + mintTokensOf.
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_destProjectId)), abi.encode(address(this))
        );
        mockExpect(
            address(this),
            abi.encodeCall(IJBController.mintTokensOf, (_destProjectId, mintCount, _bene, "", true)),
            abi.encode(mintCount)
        );
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
        _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            0,
            "",
            "",
            _defaultRouting()
        );
    }

    function test_RevertWhen_TokenForBeneficiaryProjectIsZero() external {
        _stubPermission(true);

        JBCashOutToProjectContext memory routing = JBCashOutToProjectContext({
            destinationTerminal: IJBTerminal(address(0)), tokenForBeneficiaryProject: address(0), minDeliveredToB: 0
        });

        vm.expectRevert(JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectTokenNotSpecified.selector);

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", "", routing
        );
    }

    function test_RevertWhen_BeneficiaryProjectFeeFreeInflowsPaused() external {
        // _stubBController(false) → not allowed → pause flag = true → revert.
        _stubPermission(true);
        _stubBController(false); // opt-out: flag is false → revert

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectFeeFreeInflowsPaused.selector, _destProjectId
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            0,
            "",
            "",
            _defaultRouting()
        );
    }

    function test_RevertWhen_DestinationTerminalNotFound() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);

        // No explicit destination terminal AND directory returns zero for B → revert.
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, _mockToken)),
            abi.encode(address(0))
        );

        // The function reads B's balance once (before-snapshot) before the directory lookup that reverts.
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _mockToken)),
            abi.encode(0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_RecipientProjectTerminalNotFound.selector, _destProjectId, _mockToken
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            0,
            "",
            "",
            _defaultRouting()
        );
    }

    function test_RevertWhen_DeliveredToBLTMinDeliveredToB() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        // Pay-hooks-divert simulation: before == after, so delta = 0.
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: 0});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        JBCashOutToProjectContext memory routing = JBCashOutToProjectContext({
            destinationTerminal: IJBTerminal(address(0)),
            tokenForBeneficiaryProject: _mockToken,
            minDeliveredToB: _defaultReclaim // require full delivery — but delta is 0
        });

        vm.expectRevert(abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, 0, _defaultReclaim));

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", "", routing
        );
    }

    function test_RevertWhen_BeneficiaryTokenCountLTMinTokensOut() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        // Delivery floor passes (delta == reclaim), but the mint floor fails.
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        uint256 unrealisticMin = _defaultMintCount * 10;

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, _defaultMintCount, unrealisticMin)
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            unrealisticMin,
            "",
            "",
            _defaultRouting()
        );
    }

    //*********************************************************************//
    // ---------------------------- happy paths -------------------------- //
    //*********************************************************************//

    function test_HappyPath_SameTerminalSameToken() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        // balanceBefore = 0, balanceAfter = reclaim → delta = reclaim.
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        vm.prank(_bene);
        (uint256 reclaimAmount, uint256 beneficiaryTokenCount, uint256 deliveredToB) = _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            0,
            "",
            "",
            _defaultRouting()
        );

        assertEq(reclaimAmount, _defaultReclaim, "reclaim should match the store's returned amount");
        assertEq(beneficiaryTokenCount, _defaultMintCount, "beneficiary should receive minted B tokens");
        assertEq(deliveredToB, _defaultReclaim, "deliveredToB equals balance delta on (this, B, tokenB)");
    }

    function test_HappyPath_ExplicitDestinationTerminalEqualsThis() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});

        // Same as same-terminal pay but no `primaryTerminalOf` lookup — explicit override skips it.
        JBAccountingContext memory ctx =
            JBAccountingContext({token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken))});
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _destProjectId, _mockToken)),
            abi.encode(ctx)
        );
        JBTokenAmount memory tokenAmount = JBTokenAmount({
            token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken)), value: _defaultReclaim
        });
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPaymentFrom, (_bene, tokenAmount, _destProjectId, _bene, "")),
            abi.encode(_emptyRuleset(), _defaultMintCount, new bytes(0))
        );
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_destProjectId)), abi.encode(address(this))
        );
        mockExpect(
            address(this),
            abi.encodeCall(IJBController.mintTokensOf, (_destProjectId, _defaultMintCount, _bene, "", true)),
            abi.encode(_defaultMintCount)
        );

        JBCashOutToProjectContext memory routing = JBCashOutToProjectContext({
            destinationTerminal: IJBTerminal(address(_terminal)),
            tokenForBeneficiaryProject: _mockToken,
            minDeliveredToB: 0
        });

        vm.prank(_bene);
        (, uint256 mintCount, uint256 delivered) = _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", "", routing
        );

        assertEq(mintCount, _defaultMintCount);
        assertEq(delivered, _defaultReclaim);
    }

    function test_HappyPath_ReclaimAmountZeroShortCircuits() external {
        _stubPermission(true);
        _stubBController(true);

        // Cashout returns reclaim=0 — should short-circuit before `_routeReclaimToBeneficiaryProject`.
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordCashOutFor,
                (_holder, _sourceProjectId, _defaultCashOutCount, _mockToken, true, "")
            ),
            abi.encode(
                _emptyRuleset(), uint256(0), JBConstants.MAX_CASH_OUT_TAX_RATE, new JBCashOutHookSpecification[](0)
            )
        );
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_sourceProjectId)), abi.encode(address(this))
        );
        mockExpect(
            address(this),
            abi.encodeCall(IJBController.burnTokensOf, (_holder, _sourceProjectId, _defaultCashOutCount, "")),
            ""
        );
        _stubABalanceRead(0);

        vm.prank(_bene);
        (uint256 reclaim, uint256 mintCount, uint256 delivered) = _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            0,
            "",
            "",
            _defaultRouting()
        );

        assertEq(reclaim, 0, "no reclaim");
        assertEq(mintCount, 0, "no mint");
        assertEq(delivered, 0, "no delivery");
    }

    //*********************************************************************//
    // ------------------------------ fuzz ------------------------------- //
    //*********************************************************************//

    /// @notice Fuzz the reclaim and mint counts and verify `deliveredToB == reclaim` (delta-based credit
    /// property) under the same-terminal routing path.
    function testFuzz_SameTerminal_DeliveredEqualsReclaim(uint128 reclaimAmount, uint128 mintCount) external {
        // `_pay` skips `mintTokensOf` when the store returns `tokenCount == 0`, so the mint mock would go
        // unconsumed. Keep the fuzz in the path that actually exercises the mint call.
        vm.assume(reclaimAmount > 0 && mintCount > 0);

        _stubPermission(true);
        _stubBController(true);

        // Re-encode cashout-side stub with the fuzzed reclaim.
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordCashOutFor,
                (_holder, _sourceProjectId, _defaultCashOutCount, _mockToken, true, "")
            ),
            abi.encode(
                _emptyRuleset(),
                uint256(reclaimAmount),
                JBConstants.MAX_CASH_OUT_TAX_RATE,
                new JBCashOutHookSpecification[](0)
            )
        );
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_sourceProjectId)), abi.encode(address(this))
        );
        mockExpect(
            address(this),
            abi.encodeCall(IJBController.burnTokensOf, (_holder, _sourceProjectId, _defaultCashOutCount, "")),
            ""
        );

        _stubABalanceRead(type(uint128).max);
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: reclaimAmount});
        _stubSameTerminalPay(reclaimAmount, mintCount);

        vm.prank(_bene);
        (uint256 r, uint256 m, uint256 d) = _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            0,
            "",
            "",
            _defaultRouting()
        );

        assertEq(r, reclaimAmount, "reclaim pass-through");
        assertEq(m, mintCount, "mint count pass-through");
        assertEq(d, reclaimAmount, "deliveredToB == balance delta == reclaim");
    }

    /// @notice Fuzz: any `minTokensOut` strictly greater than the actual mint count must revert.
    function testFuzz_RevertWhen_MinTokensOutTooHigh(uint64 mintCount, uint64 minTokensOut) external {
        vm.assume(mintCount > 0 && minTokensOut > mintCount);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay(_defaultReclaim, mintCount);

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, mintCount, minTokensOut)
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder,
            _sourceProjectId,
            _defaultCashOutCount,
            _mockToken,
            _destProjectId,
            _bene,
            minTokensOut,
            "",
            "",
            _defaultRouting()
        );
    }

    /// @notice Fuzz: any `minDeliveredToB` strictly greater than the actual delta must revert.
    function testFuzz_RevertWhen_MinDeliveredToBTooHigh(uint128 actualDelta, uint128 minDelivered) external {
        vm.assume(minDelivered > actualDelta);

        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: actualDelta});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        JBCashOutToProjectContext memory routing = JBCashOutToProjectContext({
            destinationTerminal: IJBTerminal(address(0)),
            tokenForBeneficiaryProject: _mockToken,
            minDeliveredToB: minDelivered
        });

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, actualDelta, minDelivered)
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", "", routing
        );
    }
}
