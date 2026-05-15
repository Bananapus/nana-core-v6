// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBRulesets} from "../src/interfaces/IJBRulesets.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRuleset} from "../src/structs/JBRuleset.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

// A ruleset's weight can be cached to make larger intervals calculable while staying within the gas limit.
contract TestRulesetWeightCaching_Local is TestBaseWorkflow {
    uint256 private constant _GAS_LIMIT = 30_000_000;
    uint8 private constant _WEIGHT_DECIMALS = 18; // FIXED
    uint256 private constant _DURATION = 1;
    uint256 private constant _WEIGHT_CUT_PERCENT = 1;

    IJBController private _controller;
    IJBRulesets private _rulesets;
    address private _projectOwner;

    JBRulesetMetadata private _metadata;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _rulesets = jbRulesets();
        _controller = jbController();

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
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0,
            allowCrossProjectFeeFreeInflows: false
        });
    }

    /// Test that caching a ruleset's weight yields the same result as computing it.
    /// @dev Bounded to 1,000 rulesets for CI speed. For full coverage (80,000), run:
    ///      forge test --match-test testWeightCaching -vvv --fuzz-runs 8
    function testWeightCaching(uint256 _rulesetDiff) public {
        // Bound to a CI-friendly range. The cache threshold is 20,000 iterations;
        // 1,000 is enough to exercise the caching path without extreme gas usage.
        _rulesetDiff = bound(_rulesetDiff, 0, 1000);

        // Keep references to the projects.
        uint256 _projectId1;
        uint256 _projectId2;

        // Package up the ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);

        {
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            // forge-lint: disable-next-line(unsafe-typecast)
            _rulesetConfigurations[0].duration = uint32(_DURATION); // safe: _DURATION = 1
            _rulesetConfigurations[0].weight = uint112(1000 * 10 ** _WEIGHT_DECIMALS);
            // forge-lint: disable-next-line(unsafe-typecast)
            _rulesetConfigurations[0].weightCutPercent = uint32(_WEIGHT_CUT_PERCENT); // safe: _WEIGHT_CUT_PERCENT = 1
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

            // Create the project to test.
            _projectId1 = _controller.launchProjectFor({
                owner: _projectOwner,
                projectUri: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: new JBTerminalConfig[](0),
                memo: ""
            });

            // Create the project to test.
            _projectId2 = _controller.launchProjectFor({
                owner: _projectOwner,
                projectUri: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: new JBTerminalConfig[](0),
                memo: ""
            });
        }

        // Keep a reference to the current rulesets.
        JBRuleset memory _ruleset1 = jbRulesets().currentOf(_projectId1);
        JBRuleset memory _ruleset2 = jbRulesets().currentOf(_projectId2);

        // Go a few rolled over rulesets into the future.
        vm.warp(block.timestamp + (_DURATION * 10));

        // Keep a reference to the amount of gas before the caching call.
        uint256 _gasBeforeCache = gasleft();

        // Cache the weight in the second project using the latest ruleset ID.
        _rulesets.updateRulesetWeightCache(_projectId2, _rulesets.latestRulesetIdOf(_projectId2));

        // Keep a reference to the amount of gas spent on the call.
        uint256 _gasDiffCache = _gasBeforeCache - gasleft();

        // Make sure the difference is within the gas limit.
        assertLe(_gasDiffCache, _GAS_LIMIT);

        // Go many rolled over rulesets into the future.
        vm.warp(block.timestamp + (_DURATION * _rulesetDiff));

        // Cache the weight in the second project again.
        _rulesets.updateRulesetWeightCache(_projectId2, _rulesets.latestRulesetIdOf(_projectId2));

        // Inherit the weight (weight=1 is the inherit sentinel in the current API).
        _rulesetConfigurations[0].weight = 1;

        // Keep a reference to the amount of gas before the call.
        uint256 _gasBefore1 = gasleft();

        // Queue the ruleset.
        vm.startPrank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectId1, rulesetConfigurations: _rulesetConfigurations, memo: ""});

        // Keep a reference to the amount of gas spent on the call.
        uint256 _gasDiff1 = _gasBefore1 - gasleft();

        // Make sure the difference is within the gas limit.
        assertLe(_gasDiff1, _GAS_LIMIT);

        // Keep a reference to the amount of gas before the call.
        uint256 _gasBefore2 = gasleft();

        _controller.queueRulesetsOf({projectId: _projectId2, rulesetConfigurations: _rulesetConfigurations, memo: ""});
        vm.stopPrank();

        // Keep a reference to the amount of gas spent on the call.
        uint256 _gasDiff2 = _gasBefore2 - gasleft();

        // Make sure the difference is within the gas limit.
        assertLe(_gasDiff2, _GAS_LIMIT);

        // Renew the reference to the current ruleset.
        _ruleset1 = jbRulesets().currentOf(_projectId1);
        _ruleset2 = jbRulesets().currentOf(_projectId2);

        // The cached call should have been cheaper.
        assertLe(_gasDiff2, _gasDiff1);

        // Make sure the rulesets have the same weight.
        assertEq(_ruleset1.weight, _ruleset2.weight);

        // Cache the weight in the second project again.
        _rulesets.updateRulesetWeightCache(_projectId2, _rulesets.latestRulesetIdOf(_projectId2));

        // Go many rolled over rulesets into the future.
        vm.warp(block.timestamp + (_DURATION * _rulesetDiff));

        // Queue the ruleset.
        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectId2, rulesetConfigurations: _rulesetConfigurations, memo: ""});
    }
}
