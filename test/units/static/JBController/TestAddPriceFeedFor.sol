// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBController} from "../../../../src/JBController.sol";
import {JBPermissioned} from "../../../../src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBPriceFeed} from "../../../../src/interfaces/IJBPriceFeed.sol";
import {IJBPrices} from "../../../../src/interfaces/IJBPrices.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBControllerSetup} from "./JBControllerSetup.sol";

contract TestAddPriceFeedFor_Local is JBControllerSetup {
    IJBPriceFeed _feed = IJBPriceFeed(makeAddr("priceFeed"));
    uint256 _projectId = 1;
    uint256 _pricingCurrency = 1;
    uint256 _unitCurrency = 2;

    function setUp() public {
        super.controllerSetup();
    }

    function _packMetadata(bool allowAddPriceFeed) internal pure returns (uint256) {
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: allowAddPriceFeed,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        return JBRulesetMetadataResolver.packRulesetMetadata(_metadata);
    }

    function _authorizeCaller() internal {
        bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _ownerOfReturn = abi.encode(address(this));
        mockExpect(address(projects), _ownerOfCall, _ownerOfReturn);
    }

    function _expectAddPriceFeedDownstream() internal {
        bytes memory _pricesCall =
            abi.encodeCall(IJBPrices.addPriceFeedFor, (_projectId, _pricingCurrency, _unitCurrency, _feed));
        mockExpect(address(prices), _pricesCall, "");
    }

    function test_WhenCallerIsPermissionedAndCurrentRulesetAllowsPriceFeed() external {
        // it will register the feed via JBPrices

        _authorizeCaller();
        _expectAddPriceFeedDownstream();

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 8000,
            weight: 5000,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packMetadata(true)
        });

        bytes memory _currentRulesetCall = abi.encodeCall(IJBRulesets.currentOf, (_projectId));
        mockExpect(address(rulesets), _currentRulesetCall, abi.encode(ruleset));

        _controller.addPriceFeedFor(_projectId, _pricingCurrency, _unitCurrency, _feed);
    }

    function test_WhenCallerIsPermissionedAndNoCurrentRuleset() external {
        // it will register the feed via JBPrices even when ruleset.id == 0
        // (gap state / pre-launch — mirrors `setTokenFor`'s gap-state allowance)

        _authorizeCaller();
        _expectAddPriceFeedDownstream();

        // Return an all-zero ruleset (gap state). Notably, allowAddPriceFeed is false in the metadata,
        // but the controller must bypass the flag check when ruleset.id == 0.
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        bytes memory _currentRulesetCall = abi.encodeCall(IJBRulesets.currentOf, (_projectId));
        mockExpect(address(rulesets), _currentRulesetCall, abi.encode(ruleset));

        _controller.addPriceFeedFor(_projectId, _pricingCurrency, _unitCurrency, _feed);
    }

    function test_RevertWhen_CallerIsPermissionedAndCurrentRulesetDisallowsPriceFeed() external {
        // it will revert because the current (non-zero) ruleset has allowAddPriceFeed == false

        _authorizeCaller();

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 8000,
            weight: 5000,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packMetadata(false)
        });

        bytes memory _currentRulesetCall = abi.encodeCall(IJBRulesets.currentOf, (_projectId));
        mockExpect(address(rulesets), _currentRulesetCall, abi.encode(ruleset));

        vm.expectRevert(
            abi.encodeWithSelector(JBController.JBController_AddingPriceFeedNotAllowed.selector, _projectId)
        );
        _controller.addPriceFeedFor(_projectId, _pricingCurrency, _unitCurrency, _feed);
    }

    function test_RevertWhen_CallerIsNotPermissioned() external {
        // it will revert UNAUTHORIZED

        // mock ownerOf call as not this address (unauth)
        bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        address _ownerOfReturn = address(0);
        mockExpect(address(projects), _ownerOfCall, abi.encode(_ownerOfReturn));

        // mock permissions call as unauth
        bytes memory _permsCall = abi.encodeCall(
            IJBPermissions.hasPermission,
            (address(this), address(0), _projectId, JBPermissionIds.ADD_PRICE_FEED, true, true)
        );
        mockExpect(address(permissions), _permsCall, abi.encode(false));

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                _ownerOfReturn,
                address(this),
                _projectId,
                JBPermissionIds.ADD_PRICE_FEED
            )
        );
        _controller.addPriceFeedFor(_projectId, _pricingCurrency, _unitCurrency, _feed);
    }
}
