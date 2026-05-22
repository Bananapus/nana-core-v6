// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {JBPermissioned} from "../../../../src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBPayoutTerminal} from "../../../../src/interfaces/IJBPayoutTerminal.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../../../src/interfaces/IJBSplitHook.sol";
import {IJBSplits} from "../../../../src/interfaces/IJBSplits.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBSplit} from "../../../../src/structs/JBSplit.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

contract TestSendPayoutsOf_Local is JBMultiTerminalSetup {
    uint256 _projectId = 1;
    uint256 _defaultAmount = 1e18;

    function setUp() public {
        super.multiTerminalSetup();
    }

    function test_WhenAmountPaidOutLtMinTokensPaidOut() external {
        // it will revert UNDER_MIN_TOKENS_PAID_OUT
        // When recordPayoutFor returns 0 (capped), the early return in _sendPayoutsOf yields 0,
        // and the _checkMin in sendPayoutsOf reverts.

        // needed for terminal store mock call
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

        JBAccountingContext memory mockTokenContext = JBAccountingContext({token: address(0), decimals: 0, currency: 0});

        // record payout mock call — returns 0 (capped to limit)
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPayoutFor, (_projectId, mockTokenContext.token, 0, 0)),
            abi.encode(returnedRuleset, 0)
        );

        vm.expectRevert(abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, 0, 1));
        _terminal.sendPayoutsOf(_projectId, address(0), 0, 0, 1, 0);
    }

    function test_WhenOwnerMustSendPayoutsButCallerDNEQOwner() external {
        // it will check permissions
        // Must return non-zero amountPaidOut to reach the permission check (0 triggers early return).

        // needed for terminal store mock call
        JBRuleset memory returnedRuleset = generateUnfriendlyRuleset();

        JBAccountingContext memory mockTokenContext = JBAccountingContext({token: address(0), decimals: 0, currency: 0});

        // record payout mock call — return non-zero to reach permission check
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPayoutFor, (_projectId, mockTokenContext.token, 1, 0)),
            abi.encode(returnedRuleset, 1)
        );

        address owner = makeAddr("owner");

        // projects owner of
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(owner));

        // mock permissions call
        bytes memory _permCall = abi.encodeCall(
            IJBPermissions.hasPermission, (address(this), owner, _projectId, JBPermissionIds.SEND_PAYOUTS, true, true)
        );
        mockExpect(address(permissions), _permCall, abi.encode(false));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                address(this),
                _projectId,
                JBPermissionIds.SEND_PAYOUTS
            )
        );
        _terminal.sendPayoutsOf(_projectId, address(0), 1, 0, 0, 0);
    }

    function test_WhenExecutePayoutFails() external {
        // it will emit PayoutReverted
        // Must return non-zero amountPaidOut to reach the splits distribution (0 triggers early return).

        // needed for terminal store mock call
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

        JBAccountingContext memory mockTokenContext = JBAccountingContext({token: address(0), decimals: 0, currency: 0});

        // record payout mock call — return non-zero to reach split distribution
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPayoutFor, (_projectId, mockTokenContext.token, 100, 0)),
            abi.encode(returnedRuleset, 100)
        );

        // projects owner of
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // needed for splits return call
        // invalid data to ensure revert
        JBSplit[] memory returnedSplits = new JBSplit[](1);
        returnedSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: 0,
            projectId: 0,
            beneficiary: payable(address(this)),
            lockedUntil: uint48(block.timestamp + 1),
            hook: IJBSplitHook(address(0))
        });

        // mock splits of call
        mockExpect(
            address(splits),
            abi.encodeCall(IJBSplits.splitsOf, (_projectId, returnedRuleset.id, 0)),
            abi.encode(returnedSplits)
        );

        // mock directory call for fee processing
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, address(0))),
            abi.encode(address(_terminal))
        );

        // mock call to feelessAddresses
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(true)
        );

        vm.expectEmit(true, true, true, false);
        emit IJBPayoutTerminal.PayoutReverted(
            _projectId,
            returnedSplits[0],
            0,
            bytes("0x9996b3150000000000000000000000000000000000000000000000000000000000000000"),
            address(this)
        );

        _terminal.sendPayoutsOf(_projectId, address(0), 100, 0, 0, 0);
    }

    // it will revert UNDER_MIN_TOKENS_PAID_OUT
    function test_WhenPayoutFailsDoNotTakeFee() external {
        // needed for terminal store mock call
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

        JBAccountingContext memory mockTokenContext = JBAccountingContext({token: address(0), decimals: 0, currency: 0});

        // record payout mock call
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordPayoutFor, (_projectId, mockTokenContext.token, 0, 100)),
            abi.encode(returnedRuleset, 100)
        );

        // projects owner of
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // mock call to feeless addresses
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(false)
        );

        // needed for splits return call
        JBSplit[] memory returnedSplits = new JBSplit[](1);
        returnedSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: 0,
            projectId: 0,
            beneficiary: payable(address(this)),
            lockedUntil: uint48(block.timestamp + 1),
            hook: IJBSplitHook(address(1))
        });

        // mock splits of call
        mockExpect(
            address(splits),
            abi.encodeCall(IJBSplits.splitsOf, (_projectId, returnedRuleset.id, 0)),
            abi.encode(returnedSplits)
        );

        // mock directory call for fee processing
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, address(0))),
            abi.encode(address(_terminal))
        );

        vm.expectEmit(true, true, true, true);
        emit IJBPayoutTerminal.PayoutTransferReverted(
            _projectId,
            address(this),
            address(0),
            98, // Amount that would have been transferred after fee.
            2, // fee amount
            bytes(hex"5274afe70000000000000000000000000000000000000000000000000000000000000000"),
            address(this)
        );

        _terminal.sendPayoutsOf(_projectId, address(0), 0, 100, 100, 0);
    }
}
