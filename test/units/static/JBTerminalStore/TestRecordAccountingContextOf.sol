// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBTerminalStore} from "../../../../src/JBTerminalStore.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBTerminalStoreSetup} from "./JBTerminalStoreSetup.sol";

contract TestRecordAccountingContextOf_Local is JBTerminalStoreSetup {
    uint256 private constant _PROJECT_ID = 1;
    uint32 private constant _CURRENCY = 1;

    function setUp() public {
        super.terminalStoreSetup();
    }

    function test_GivenNativeDecimalsGT36() external {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 37, currency: _CURRENCY});

        vm.expectRevert(
            abi.encodeWithSelector(
                JBTerminalStore.JBTerminalStore_AccountingContextDecimalsOutOfRange.selector,
                JBConstants.NATIVE_TOKEN,
                37
            )
        );
        _store.recordAccountingContextOf(_PROJECT_ID, contexts);
    }

    function test_GivenTokenDecimalsGT36() external {
        TokenWithDecimals token = new TokenWithDecimals(37);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(token), decimals: 18, currency: _CURRENCY});

        vm.expectRevert(
            abi.encodeWithSelector(
                JBTerminalStore.JBTerminalStore_AccountingContextDecimalsOutOfRange.selector, address(token), 37
            )
        );
        _store.recordAccountingContextOf(_PROJECT_ID, contexts);
    }

    function test_GivenTokenDecimalsEQ36() external {
        TokenWithDecimals token = new TokenWithDecimals(36);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(token), decimals: 36, currency: _CURRENCY});

        _store.recordAccountingContextOf(_PROJECT_ID, contexts);

        JBAccountingContext memory context =
            _store.accountingContextOf({terminal: address(this), projectId: _PROJECT_ID, token: address(token)});

        assertEq(context.token, address(token));
        assertEq(context.decimals, 36);
        assertEq(context.currency, _CURRENCY);
    }
}

contract TokenWithDecimals {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
