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
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice Unit tests for `JBMultiTerminal.cashOutAsPaymentToProjectOf`. The flow burns source-project tokens
/// and pays the reclaim into a destination project via that project's primary terminal for the reclaim token.
/// The first of B's accounting contexts on this terminal whose balance grows during the routing gets credited
/// to `_feeFreeSurplusOf[B][token]`.
/// @dev Heavy mocking — same convention as `TestCashOutTokensOf` and `TestPay`. `mockExpectSubsequent` is used
/// to simulate `STORE.balanceOf` before/after pattern with sequenced return values.
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
    function _stubCashoutSide(uint256 reclaimAmount) internal {
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

        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_sourceProjectId)), abi.encode(address(this))
        );
        mockExpect(
            address(this),
            abi.encodeCall(IJBController.burnTokensOf, (_holder, _sourceProjectId, _defaultCashOutCount, "")),
            ""
        );
    }

    /// @notice Stub A's `_capFeeFreeSurplus` balance read (default high so the cap doesn't bite).
    function _stubABalanceRead(uint256 value) internal {
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _sourceProjectId, _mockToken)),
            abi.encode(value)
        );
    }

    /// @notice Stub B's accounting contexts on this terminal. Most tests use a single-context list.
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

    /// @notice Stub the balanceOf sequence for B's single-context bucket on this terminal.
    /// 2 reads when no delivery, 3 reads when delivered (cap fires on the third).
    function _stubBBalanceSequence(uint256 balanceBefore, uint256 balanceAfter) internal {
        bool capFires = balanceAfter > balanceBefore;
        bytes[] memory returns_ = new bytes[](capFires ? 3 : 2);
        returns_[0] = abi.encode(balanceBefore);
        returns_[1] = abi.encode(balanceAfter);
        if (capFires) returns_[2] = abi.encode(balanceAfter);
        mockExpectSubsequent(
            address(store),
            abi.encodeCall(IJBTerminalStore.balanceOf, (address(_terminal), _destProjectId, _mockToken)),
            returns_
        );
    }

    /// @notice Stub the same-terminal `_pay` flow for routing into B.
    /// @dev payer == msg.sender == `_bene` under `vm.prank(_bene)`.
    function _stubSameTerminalPay(uint256 reclaimAmount, uint256 mintCount) internal {
        // B's primary terminal for the reclaim token resolves to this terminal.
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (_destProjectId, _mockToken)),
            abi.encode(address(_terminal))
        );

        JBAccountingContext memory ctx =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: _mockToken, decimals: 18, currency: uint32(uint160(_mockToken))});
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _destProjectId, _mockToken)),
            abi.encode(ctx)
        );

        JBTokenAmount memory tokenAmount = JBTokenAmount({
            token: _mockToken,
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(_mockToken)),
            value: reclaimAmount
        });

        // _pay -> STORE.recordPaymentFrom (payer = _bene under prank).
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPaymentFrom, (_bene, tokenAmount, _destProjectId, _bene, "")),
            abi.encode(_emptyRuleset(), mintCount, new bytes(0))
        );

        // _pay -> controllerOf(B) + mintTokensOf (only if mintCount > 0).
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
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryProjectFeeFreeInflowsPaused() external {
        // _stubBController(false) → not allowed → pause flag = true → revert.
        _stubPermission(true);
        _stubBController(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectFeeFreeInflowsPaused.selector, _destProjectId
            )
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_DestinationTerminalNotFound() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);

        // Directory returns zero for B's primary terminal for the reclaim token.
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
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryProjectHasNoAccountingContexts() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);

        // Destination resolves to this terminal, but B has no accounting contexts on this terminal.
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
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryProjectNotPaid() external {
        // Destination pay succeeds but B's bucket on this terminal doesn't grow (e.g. router deposited to a
        // different terminal). Revert prevents the source-side fee leak.
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: 0});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_BeneficiaryProjectNotPaid.selector, _destProjectId)
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );
    }

    function test_RevertWhen_BeneficiaryTokenCountLTMinTokensOut() external {
        _stubPermission(true);
        _stubBController(true);
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        uint256 unrealisticMin = _defaultMintCount * 10;

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, _defaultMintCount, unrealisticMin)
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, unrealisticMin, "", ""
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
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay(_defaultReclaim, _defaultMintCount);

        vm.prank(_bene);
        (uint256 reclaimAmount, uint256 beneficiaryTokenCount) = _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(reclaimAmount, _defaultReclaim, "reclaim should match the store's returned amount");
        assertEq(beneficiaryTokenCount, _defaultMintCount, "beneficiary should receive minted B tokens");
    }

    function test_HappyPath_ReclaimAmountZeroShortCircuits() external {
        _stubPermission(true);
        _stubBController(true);

        // Cashout returns reclaim=0 — short-circuits before routing.
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
        (uint256 reclaim, uint256 mintCount) = _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, 0, "", ""
        );

        assertEq(reclaim, 0, "no reclaim");
        assertEq(mintCount, 0, "no mint");
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
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: reclaimAmount});
        _stubSameTerminalPay(reclaimAmount, mintCount);

        vm.prank(_bene);
        (uint256 r, uint256 m) = _terminal.cashOutAsPaymentToProjectOf(
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
        _stubCashoutSide(_defaultReclaim);
        _stubABalanceRead(type(uint128).max);
        _stubBAccountingContexts(_singleTokenContext(_mockToken));
        _stubBBalanceSequence({balanceBefore: 0, balanceAfter: _defaultReclaim});
        _stubSameTerminalPay(_defaultReclaim, mintCount);

        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, mintCount, minTokensOut)
        );

        vm.prank(_bene);
        _terminal.cashOutAsPaymentToProjectOf(
            _holder, _sourceProjectId, _defaultCashOutCount, _mockToken, _destProjectId, _bene, minTokensOut, "", ""
        );
    }
}
