// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBApprovalStatus} from "../../../../src/enums/JBApprovalStatus.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {JBRulesetsSetup} from "./JBRulesetsSetup.sol";

contract TestCurrentOf_Local is JBRulesetsSetup {
    // Necessary params
    JBRulesetMetadata private _metadata;
    JBRulesetMetadata private _metadataWithApprovalHook;
    IJBRulesetApprovalHook private _mockApprovalHook = IJBRulesetApprovalHook(makeAddr("hook"));
    uint256 _packedMetadata;
    uint256 _packedWithApprovalHook;
    uint256 _projectId = 1;
    uint256 _duration = 3 days;
    uint256 _weight = 0;
    uint256 _weightCutPercent = 450_000_000;
    uint48 _mustStartAt = 0;
    uint256 _hookDuration = 1 days;
    IJBRulesetApprovalHook private _noHook = IJBRulesetApprovalHook(address(0));

    function setUp() public {
        super.rulesetsSetup();

        // Params for tests
        _metadata = JBRulesetMetadata({
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
            metadata: 0
        });

        // Params for tests
        _metadataWithApprovalHook = JBRulesetMetadata({
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
            metadata: 0
        });

        _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);
        _packedWithApprovalHook = JBRulesetMetadataResolver.packRulesetMetadata(_metadataWithApprovalHook);
    }

    function test_WhenLatestrulesetOfProjectEQZero() external view {
        // it will return an empty ruleset

        JBRuleset memory _ruleset = _rulesets.currentOf(_projectId);
        assertEq(_ruleset.id, 0);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    modifier whenLatestRulesetIdDNEQZero() {
        // put code at hook address
        vm.etch(address(_mockApprovalHook), abi.encode(1));

        // mock call to hook interface support
        mockExpect(
            address(_mockApprovalHook),
            abi.encodeCall(IERC165.supportsInterface, (type(IJBRulesetApprovalHook).interfaceId)),
            abi.encode(true)
        );

        // Setup: queueFor will call onlyControllerOf modifier -> Directory.controllerOf to see if caller has proper
        // permissions, encode & mock that.
        bytes memory _encodedCall = abi.encodeCall(IJBDirectory.controllerOf, (1));
        bytes memory _willReturn = abi.encode(address(this));

        mockExpect(address(directory), _encodedCall, _willReturn);

        // First queue a base ruleset.

        // Setup: expect ruleset event (RulesetQueued) is emitted
        vm.expectEmit();
        emit IJBRulesets.RulesetQueued(
            block.timestamp,
            _projectId,
            _duration,
            _weight,
            _weightCutPercent,
            _mockApprovalHook,
            _packedWithApprovalHook,
            block.timestamp,
            address(this)
        );

        // mock call to hook duration
        mockExpect(
            address(_mockApprovalHook), abi.encodeCall(IJBRulesetApprovalHook.DURATION, ()), abi.encode(_hookDuration)
        );

        // Send: Call from this contract as it's been mock authorized above.
        _rulesets.queueFor({
            projectId: _projectId,
            duration: _duration,
            weight: _weight,
            weightCutPercent: _weightCutPercent,
            approvalHook: _mockApprovalHook,
            metadata: _packedWithApprovalHook,
            mustStartAtOrAfter: _mustStartAt
        });

        // Setup: expect ruleset event (RulesetQueued) is emitted
        vm.expectEmit();
        emit IJBRulesets.RulesetQueued(
            block.timestamp + 1,
            _projectId,
            _duration,
            _weight,
            _weightCutPercent,
            _noHook,
            _packedMetadata,
            block.timestamp,
            address(this)
        );

        // Send: Call from this contract as it's been mock authorized above.
        _rulesets.queueFor({
            projectId: _projectId,
            duration: _duration,
            weight: _weight,
            weightCutPercent: _weightCutPercent,
            approvalHook: _noHook,
            metadata: _packedMetadata,
            mustStartAtOrAfter: _mustStartAt
        });

        /* // mock call to hook approvalStatusOf
        mockExpect(
            address(_mockApprovalHook),
            abi.encodeCall(
        IJBRulesetApprovalHook.approvalStatusOf, (_projectId, block.timestamp + 1, block.timestamp + _duration)
            ),
            abi.encode(JBApprovalStatus.Failed)
        ); */

        _;
    }

    function test_GivenTheCurrentlyApprovableRulesetIdOfApprovalStatusEQApprovedOrEmpty()
        external
        whenLatestRulesetIdDNEQZero
    {
        // it will return the latest approved ruleset

        JBRuleset memory _current = _rulesets.currentOf(_projectId);
        assertEq(_current.id, block.timestamp);
    }

    function test_GivenTheCurrentlyApprovableRulesetIdOfApprovalStatusDNEQApprovedOrEmpty()
        external
        whenLatestRulesetIdDNEQZero
    {
        // it will return the ruleset the pending approval ruleset is basedOn

        // Capture IDs from actual storage (avoid via_ir reordering of block.timestamp).
        uint256 _firstRulesetId = _rulesets.currentOf(_projectId).id;
        uint256 _rulesetWithHookId = _firstRulesetId + 1;

        JBRuleset memory _queuedRuleset = _rulesets.getRulesetOf(_projectId, _rulesetWithHookId);

        vm.warp(_firstRulesetId + 3 days);

        // mock approvalStatusOf to return Pending
        mockExpect(
            address(_mockApprovalHook),
            abi.encodeCall(IJBRulesetApprovalHook.approvalStatusOf, (_projectId, _queuedRuleset)),
            abi.encode(JBApprovalStatus.Active)
        );

        JBRuleset memory _current = _rulesets.currentOf(_projectId);
        assertEq(_current.id, _firstRulesetId);
    }

    function test_GivenTheCurrentlyApprovableRulesetIdOfEQZeroAndApprovalStatusOfTheLatestRulesetDNEQApprovedOrEmpty()
        external
        whenLatestRulesetIdDNEQZero
    {
        // it will return the basedOn of the latest ruleset

        // Capture IDs from actual storage (avoid via_ir reordering of block.timestamp).
        uint256 _firstRulesetId = _rulesets.currentOf(_projectId).id;
        uint256 _rulesetWithHookId = _firstRulesetId + 1;

        JBRuleset memory _queuedRuleset = _rulesets.getRulesetOf(_projectId, _rulesetWithHookId);

        vm.warp(_firstRulesetId + 4 days);

        // mock approvalStatusOf to return Pending
        mockExpect(
            address(_mockApprovalHook),
            abi.encodeCall(IJBRulesetApprovalHook.approvalStatusOf, (_projectId, _queuedRuleset)),
            abi.encode(JBApprovalStatus.Active)
        );

        JBRuleset memory _current = _rulesets.currentOf(_projectId);
        assertEq(_current.id, _firstRulesetId);
    }

    // Covered above.
    /* function test_WhenBaseOfTheCurrentlyApprovableRulesetIdOfDurationDNEQZero() external {
        // it will return simulateCycledRulesetBasedOn with allowMidRuleset true
    } */
}
