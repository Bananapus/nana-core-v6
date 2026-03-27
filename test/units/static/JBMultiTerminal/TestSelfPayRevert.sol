// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "../../../../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice Tests that `_pay` reverts when the terminal is paying itself (self-referencing payout split).
contract TestSelfPayRevert_Local is JBMultiTerminalSetup {
    uint64 _projectId = 1;
    uint256 _defaultAmount = 1e18;
    address _bene = makeAddr("beneficiary");
    address _native = JBConstants.NATIVE_TOKEN;
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 _nativeCurrency = uint32(uint160(_native));

    function setUp() public {
        super.multiTerminalSetup();
    }

    /// @notice When the terminal calls _pay on itself (payer == address(this)), it should revert
    /// with MintNotAllowed. This prevents same-project payout splits from minting tokens against
    /// existing balance without new funds entering the system.
    function test_RevertWhen_TerminalPaysItself() external {
        // Mock TOKENS.totalBalanceOf (called in external pay() before _pay).
        mockExpect(
            address(tokens),
            abi.encodeCall(IJBTokens.totalBalanceOf, (_bene, uint256(_projectId))),
            abi.encode(uint256(0))
        );

        // Mock the accounting context for _acceptFundsFor.
        JBAccountingContext memory ctx =
            JBAccountingContext({token: _native, decimals: 18, currency: _nativeCurrency});
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), uint256(_projectId), _native)),
            abi.encode(ctx)
        );

        // Mock recordPaymentFrom - return a ruleset and token count.
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        JBPayHookSpecification[] memory hooks = new JBPayHookSpecification[](0);

        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordPaymentFrom,
                (
                    address(_terminal),
                    JBTokenAmount({token: _native, value: _defaultAmount, decimals: 18, currency: _nativeCurrency}),
                    uint256(_projectId),
                    _bene,
                    ""
                )
            ),
            abi.encode(ruleset, _defaultAmount, hooks)
        );

        // Call pay from the terminal itself - should revert with MintNotAllowed.
        vm.deal(address(_terminal), _defaultAmount);
        vm.prank(address(_terminal));
        vm.expectRevert(JBMultiTerminal.JBMultiTerminal_MintNotAllowed.selector);
        _terminal.pay{value: _defaultAmount}({
            projectId: uint256(_projectId),
            token: _native,
            amount: _defaultAmount,
            beneficiary: _bene,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }
}
