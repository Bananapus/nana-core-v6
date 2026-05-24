// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

// Accounting context is now read from the store

contract TestExecuteProcessFee_Local is JBMultiTerminalSetup {
    uint256 _projectId = 1;
    uint256 _defaultAmount = 1e18;
    address _bene = makeAddr("beneficiary");
    address _native = JBConstants.NATIVE_TOKEN;
    address _usdc = makeAddr("USDC");

    IJBTerminal _feeTerminal = IJBTerminal(makeAddr("feeTerminal"));
    IJBTerminal _invalidTerminal = IJBTerminal(address(0));

    function setUp() public {
        super.multiTerminalSetup();
    }

    function _setAccountingContext(address token, uint8 decimals, uint32 currency) internal {
        // Mock the store to return this accounting context
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, token)),
            abi.encode(JBAccountingContext({token: token, decimals: decimals, currency: currency}))
        );
    }

    function test_WhenCallerIsNotItself() external {
        // it will revert

        vm.expectRevert();
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId, token: _native, amount: _defaultAmount, beneficiary: _bene, feeTerminal: _feeTerminal
        });
    }

    function test_WhenFeeTerminalEQZeroAddress() external {
        // it will revert 404_1

        vm.prank(address(_terminal));
        vm.expectRevert(abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_FeeTerminalNotFound.selector, _native));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId,
            token: _native,
            amount: _defaultAmount,
            beneficiary: _bene,
            feeTerminal: _invalidTerminal
        });
    }

    function test_WhenTokenIsErc20AndFeeTerminalIsExternal() external {
        // it will forceApprove

        // mock approval call for forceApprove
        mockExpect(_usdc, abi.encodeCall(IERC20.approve, (address(_feeTerminal), _defaultAmount)), "");

        // Mock the forwarded allowance as fully consumed by the fee terminal.
        vm.mockCall(_usdc, abi.encodeCall(IERC20.allowance, (address(_terminal), address(_feeTerminal))), abi.encode(0));

        // mock pay call to fee terminal
        mockExpect(
            address(_feeTerminal),
            abi.encodeCall(
                IJBTerminal.pay, (_projectId, _usdc, _defaultAmount, _bene, 0, "", bytes(abi.encodePacked(_projectId)))
            ),
            abi.encode(1)
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId, token: _usdc, amount: _defaultAmount, beneficiary: _bene, feeTerminal: _feeTerminal
        });
    }

    function test_WhenFeeTerminalEQItself() external {
        // it will call internal _pay

        _setAccountingContext(_native, 0, 1);

        // needed for next mock call returns
        JBTokenAmount memory tokenAmount =
            JBTokenAmount({token: _native, decimals: 0, currency: 1, value: _defaultAmount});
        JBPayHookSpecification[] memory hookSpecifications = new JBPayHookSpecification[](0);
        JBRuleset memory returnedRuleset = JBRuleset({
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

        // mock call to JBTerminalStore recordPaymentFrom
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordPaymentFrom,
                (address(_terminal), tokenAmount, _projectId, _bene, bytes(abi.encodePacked(_projectId)))
            ),
            abi.encode(returnedRuleset, 0, hookSpecifications)
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId, token: _native, amount: _defaultAmount, beneficiary: _bene, feeTerminal: _terminal
        });
    }

    function test_GivenTokenEQNATIVE_TOKEN() external {
        // it will call external pay with msgvalue

        // Fund the terminal so it can forward native ETH.
        vm.deal(address(_terminal), _defaultAmount);

        // mock pay call to fee terminal
        mockExpect(
            address(_feeTerminal),
            abi.encodeCall(
                IJBTerminal.pay,
                (_projectId, _native, _defaultAmount, _bene, 0, "", bytes(abi.encodePacked(_projectId)))
            ),
            abi.encode(1)
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId, token: _native, amount: _defaultAmount, beneficiary: _bene, feeTerminal: _feeTerminal
        });
    }

    function test_GivenBeneficiaryEQZero_ERC20_ExternalFeeTerminal() external {
        // When `beneficiary == address(0)` the fee is routed via `addToBalanceOf` instead of `pay`.
        // The fee project still receives the value (no fee bypass), without minting fee-project tokens.

        // mock approval call for forceApprove on the external fee terminal
        mockExpect(_usdc, abi.encodeCall(IERC20.approve, (address(_feeTerminal), _defaultAmount)), "");

        // Mock the forwarded allowance as fully consumed by the fee terminal.
        vm.mockCall(_usdc, abi.encodeCall(IERC20.allowance, (address(_terminal), address(_feeTerminal))), abi.encode(0));

        // Critically: expect addToBalanceOf (NOT pay) to be invoked.
        mockExpect(
            address(_feeTerminal),
            abi.encodeCall(
                IJBTerminal.addToBalanceOf,
                (_projectId, _usdc, _defaultAmount, false, "", bytes(abi.encodePacked(_projectId)))
            ),
            ""
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId,
            token: _usdc,
            amount: _defaultAmount,
            beneficiary: address(0),
            feeTerminal: _feeTerminal
        });
    }

    function test_GivenBeneficiaryEQZero_Native_ExternalFeeTerminal() external {
        // Same as above, but with native ETH — must be forwarded as msg.value to addToBalanceOf.

        // Fund the terminal so it can forward native ETH.
        vm.deal(address(_terminal), _defaultAmount);

        // Expect addToBalanceOf (NOT pay) to be invoked, with native value.
        mockExpect(
            address(_feeTerminal),
            abi.encodeCall(
                IJBTerminal.addToBalanceOf,
                (_projectId, _native, _defaultAmount, false, "", bytes(abi.encodePacked(_projectId)))
            ),
            ""
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId,
            token: _native,
            amount: _defaultAmount,
            beneficiary: address(0),
            feeTerminal: _feeTerminal
        });
    }

    function test_GivenBeneficiaryEQZero_FeeTerminalEQItself() external {
        // When fee terminal is itself AND beneficiary is zero, the internal `_addToBalanceOf` path is taken
        // (which records added balance against the fee project) — no `recordPaymentFrom`, no token mint.

        // Expect the store's recordAddedBalanceFor (the internal addToBalance path) to be called.
        // The internal `_addToBalanceOf` calls `STORE.recordAddedBalanceFor` to credit balance.
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_projectId, _native, _defaultAmount)),
            ""
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId,
            token: _native,
            amount: _defaultAmount,
            beneficiary: address(0),
            feeTerminal: _terminal
        });
    }

    function test_GivenTokenDNEQNATIVE_TOKENAndPayingItself() external {
        // it will call external pay with zero msgvalue

        _setAccountingContext(_usdc, 0, 1);

        // needed for next mock call returns
        JBTokenAmount memory tokenAmount =
            JBTokenAmount({token: _usdc, decimals: 0, currency: 1, value: _defaultAmount});
        JBPayHookSpecification[] memory hookSpecifications = new JBPayHookSpecification[](0);
        JBRuleset memory returnedRuleset = JBRuleset({
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

        // mock call to JBTerminalStore recordPaymentFrom
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordPaymentFrom,
                (address(_terminal), tokenAmount, _projectId, _bene, bytes(abi.encodePacked(_projectId)))
            ),
            abi.encode(returnedRuleset, 0, hookSpecifications)
        );

        vm.prank(address(_terminal));
        JBMultiTerminal(address(_terminal))
            .executeProcessFee({
            projectId: _projectId, token: _usdc, amount: _defaultAmount, beneficiary: _bene, feeTerminal: _terminal
        });
    }
}
