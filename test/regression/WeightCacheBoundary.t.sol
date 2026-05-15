// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBRulesets} from "../../src/interfaces/IJBRulesets.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
import {JBRulesets} from "../../src/JBRulesets.sol";

import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Deterministic (non-fuzz) tests for the JBRulesets weight cache at the 20,000 iteration boundary.
/// The contract reverts with `JBRulesets_WeightCacheRequired` when the cycle gap exceeds the threshold
/// and the cache has not been populated. These tests verify:
///   1. Exactly 20,000 cycles work without cache.
///   2. 20,001 cycles revert without cache.
///   3. Progressive `updateRulesetWeightCache()` calls unblock the revert.
///   4. The cached weight equals the iteratively computed weight.
contract WeightCacheBoundary_Local is TestBaseWorkflow {
    uint256 private constant _THRESHOLD = 20_000;

    /// @dev 1-second duration makes each cycle = 1 second, so we can hit the boundary fast.
    uint32 private constant _DURATION = 1;

    /// @dev Tiny weight cut (0.1%) so the weight doesn't decay to zero over 20k cycles.
    uint32 private constant _WEIGHT_CUT_PERCENT = 1_000_000; // 0.1% of MAX_WEIGHT_CUT_PERCENT (1e9)

    uint112 private constant _INITIAL_WEIGHT = 1000e18;

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
            pauseCrossProjectFeeFreeInflows: false
        });
    }

    /// @dev Helper: launch a project with a 1-second duration and the given weight cut percent.
    function _launchProject() internal returns (uint256 projectId) {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0].mustStartAtOrAfter = 0;
        configs[0].duration = _DURATION;
        configs[0].weight = _INITIAL_WEIGHT;
        configs[0].weightCutPercent = _WEIGHT_CUT_PERCENT;
        configs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        configs[0].metadata = _metadata;
        configs[0].splitGroups = new JBSplitGroup[](0);
        configs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "weightCacheBoundary",
            rulesetConfigurations: configs,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: ""
        });
    }

    /// @dev Compute expected weight by iterating the cut percent `n` times on the initial weight.
    function _expectedWeight(uint256 n) internal pure returns (uint256 weight) {
        weight = _INITIAL_WEIGHT;
        for (uint256 i; i < n; i++) {
            weight = mulDiv(
                weight, JBConstants.MAX_WEIGHT_CUT_PERCENT - _WEIGHT_CUT_PERCENT, JBConstants.MAX_WEIGHT_CUT_PERCENT
            );
            if (weight == 0) break;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 1: Exactly 20,000 cycles works without cache
    // ═══════════════════════════════════════════════════════════════════

    function test_exactlyAtThreshold_noCache_succeeds() public {
        uint256 projectId = _launchProject();

        // Warp forward exactly 20,000 durations.
        vm.warp(block.timestamp + _DURATION * _THRESHOLD);

        // currentOf should succeed — still within the iteration limit.
        JBRuleset memory ruleset = _rulesets.currentOf(projectId);

        // Verify weight matches the iterative calculation.
        uint256 expected = _expectedWeight(_THRESHOLD);
        assertEq(ruleset.weight, expected, "Weight at exactly 20,000 cycles should match iterative calculation");
        assertTrue(ruleset.weight > 0, "Weight should not have decayed to zero at 20k cycles with 0.1% cut");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 2: 20,001 cycles reverts without cache
    // ═══════════════════════════════════════════════════════════════════

    function test_aboveThreshold_noCache_reverts() public {
        uint256 projectId = _launchProject();

        // Warp forward 20,001 durations.
        vm.warp(block.timestamp + _DURATION * (_THRESHOLD + 1));

        // currentOf should revert because the iteration count exceeds the threshold.
        vm.expectRevert(abi.encodeWithSelector(JBRulesets.JBRulesets_WeightCacheRequired.selector, projectId));
        _rulesets.currentOf(projectId);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 3: Single cache call unblocks 20,001 cycles
    // ═══════════════════════════════════════════════════════════════════

    function test_aboveThreshold_singleCacheCall_succeeds() public {
        uint256 projectId = _launchProject();
        uint256 rulesetId = _rulesets.latestRulesetIdOf(projectId);

        // Warp forward 20,001 durations.
        vm.warp(block.timestamp + _DURATION * (_THRESHOLD + 1));

        // Without cache, this reverts.
        vm.expectRevert(abi.encodeWithSelector(JBRulesets.JBRulesets_WeightCacheRequired.selector, projectId));
        _rulesets.currentOf(projectId);

        // Populate the cache.
        _rulesets.updateRulesetWeightCache(projectId, rulesetId);

        // Now currentOf should succeed.
        JBRuleset memory ruleset = _rulesets.currentOf(projectId);

        // Verify weight matches iterative calculation.
        uint256 expected = _expectedWeight(_THRESHOLD + 1);
        assertEq(ruleset.weight, expected, "Weight at 20,001 cycles should match after single cache call");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 4: Progressive caching for large gaps (40,001 cycles)
    // ═══════════════════════════════════════════════════════════════════

    function test_largeGap_progressiveCaching_succeeds() public {
        uint256 projectId = _launchProject();
        uint256 rulesetId = _rulesets.latestRulesetIdOf(projectId);

        // Warp forward 40,001 durations (needs 2 cache calls).
        vm.warp(block.timestamp + _DURATION * (_THRESHOLD * 2 + 1));

        // Without cache, reverts.
        vm.expectRevert(abi.encodeWithSelector(JBRulesets.JBRulesets_WeightCacheRequired.selector, projectId));
        _rulesets.currentOf(projectId);

        // First cache call: advances cache by up to 20,000 iterations.
        _rulesets.updateRulesetWeightCache(projectId, rulesetId);

        // Still reverts — we need another cache call to cover the remaining gap.
        vm.expectRevert(abi.encodeWithSelector(JBRulesets.JBRulesets_WeightCacheRequired.selector, projectId));
        _rulesets.currentOf(projectId);

        // Second cache call: covers the rest.
        _rulesets.updateRulesetWeightCache(projectId, rulesetId);

        // Now it should succeed.
        JBRuleset memory ruleset = _rulesets.currentOf(projectId);

        // Verify weight matches iterative calculation.
        uint256 expected = _expectedWeight(_THRESHOLD * 2 + 1);
        assertEq(ruleset.weight, expected, "Weight at 40,001 cycles should match after two cache calls");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 5: Cache produces same weight as direct iteration
    // ═══════════════════════════════════════════════════════════════════

    function test_cachedWeight_matchesDirect_atBoundary() public {
        // Launch two identical projects.
        uint256 projectA = _launchProject();
        uint256 projectB = _launchProject();

        uint256 rulesetIdB = _rulesets.latestRulesetIdOf(projectB);

        // Warp to exactly 20,000 cycles (within threshold for both).
        vm.warp(block.timestamp + _DURATION * _THRESHOLD);

        // Project A: no cache, direct iteration.
        JBRuleset memory rulesetA = _rulesets.currentOf(projectA);

        // Project B: populate cache first, then query.
        _rulesets.updateRulesetWeightCache(projectB, rulesetIdB);
        JBRuleset memory rulesetB = _rulesets.currentOf(projectB);

        // Both should produce identical weights.
        assertEq(rulesetA.weight, rulesetB.weight, "Cached and uncached weights should be identical at threshold");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 6: Zero weightCutPercent — cache is no-op
    // ═══════════════════════════════════════════════════════════════════

    function test_zeroWeightCut_cacheNoOp() public {
        // Launch a project with zero weight cut.
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0].mustStartAtOrAfter = 0;
        configs[0].duration = _DURATION;
        configs[0].weight = _INITIAL_WEIGHT;
        configs[0].weightCutPercent = 0; // No decay
        configs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        configs[0].metadata = _metadata;
        configs[0].splitGroups = new JBSplitGroup[](0);
        configs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "zeroCut",
            rulesetConfigurations: configs,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: ""
        });

        // Warp far beyond the threshold — since weightCutPercent = 0, no iterations needed.
        vm.warp(block.timestamp + _DURATION * (_THRESHOLD * 5));

        // Should succeed without any cache because the weight cut loop is skipped.
        JBRuleset memory ruleset = _rulesets.currentOf(projectId);
        assertEq(ruleset.weight, _INITIAL_WEIGHT, "Weight should remain unchanged with zero cut percent");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 7: Cache with zero duration — updateRulesetWeightCache is no-op
    // ═══════════════════════════════════════════════════════════════════

    function test_zeroDuration_cacheNoOp() public {
        // Launch a project with zero duration.
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0].mustStartAtOrAfter = 0;
        configs[0].duration = 0; // Never expires
        configs[0].weight = _INITIAL_WEIGHT;
        configs[0].weightCutPercent = _WEIGHT_CUT_PERCENT;
        configs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        configs[0].metadata = _metadata;
        configs[0].splitGroups = new JBSplitGroup[](0);
        configs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        uint256 projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "zeroDuration",
            rulesetConfigurations: configs,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: ""
        });

        uint256 rulesetId = _rulesets.latestRulesetIdOf(projectId);

        // Warp far ahead.
        vm.warp(block.timestamp + 1_000_000);

        // updateRulesetWeightCache should be a no-op (returns without caching).
        _rulesets.updateRulesetWeightCache(projectId, rulesetId);

        // currentOf should succeed — zero duration means the same ruleset is always current.
        JBRuleset memory ruleset = _rulesets.currentOf(projectId);
        assertEq(ruleset.weight, _INITIAL_WEIGHT, "Weight should remain unchanged with zero duration");
    }
}
