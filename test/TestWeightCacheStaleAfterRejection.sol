// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

/// @notice Mock approval hook that ALWAYS rejects queued rulesets.
contract AlwaysRejectApprovalHook is IJBRulesetApprovalHook {
    function DURATION() external pure override returns (uint256) {
        return 0;
    }

    function approvalStatusOf(uint256, JBRuleset memory) external pure override returns (JBApprovalStatus) {
        return JBApprovalStatus.Failed;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetApprovalHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Regression tests for the weight cache stale-after-rejection fix.
///
/// Before the fix, updateRulesetWeightCache() only updated the cache for latestRulesetIdOf.
/// When a queued ruleset was rejected by an approval hook, currentOf() would fall back to
/// the base ruleset, but that base ruleset's cache could never be updated — causing
/// deriveWeightFrom() to revert with WeightCacheRequired after >20,000 cycles.
///
/// The fix makes updateRulesetWeightCache() walk back through rejected rulesets to find
/// the effective base ruleset that currentOf() actually uses, and updates its cache.
contract TestWeightCacheStaleAfterRejection is TestBaseWorkflow {
    IJBController private _controller;
    IJBRulesets private _rulesets;
    address private _projectOwner;
    AlwaysRejectApprovalHook private _rejectHook;

    uint256 private _projectId;

    function setUp() public override {
        super.setUp();
        _controller = jbController();
        _rulesets = jbRulesets();
        _projectOwner = multisig();
        _rejectHook = new AlwaysRejectApprovalHook();
    }

    /// @notice Launch a project with a 1-second duration ruleset, weight decay, and an always-reject approval hook.
    function _launchProject() internal returns (uint256 projectId) {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
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
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        rulesetConfigurations[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 1, // 1 second — cycles very fast
            weight: 1000e18,
            weightCutPercent: 1, // Non-zero so weight decays each cycle
            approvalHook: _rejectHook, // Will reject all subsequent rulesets
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        vm.prank(_projectOwner);
        projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: new JBTerminalConfig[](0),
            memo: ""
        });
    }

    /// @notice Helper to build a new ruleset config for queuing (will be rejected).
    function _buildRejectedConfig() internal pure returns (JBRulesetConfig[] memory newConfigs) {
        newConfigs = new JBRulesetConfig[](1);
        newConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 1,
            weight: 500e18, // Specific weight, not 1 (inherit), to avoid deriveWeightFrom during queuing
            weightCutPercent: 1,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
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
                useTotalSurplusForCashOuts: true,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    /// @notice REGRESSION: After queuing a rejected ruleset and warping >20k cycles,
    /// updateRulesetWeightCache() should update the active base ruleset's cache (not just the
    /// rejected latest), allowing currentOf() to succeed.
    function test_weightCache_fixedAfterApprovalRejection() public {
        _projectId = _launchProject();

        // Verify the project works initially.
        JBRuleset memory initial = _rulesets.currentOf(_projectId);
        assertGt(initial.weight, 0, "Initial weight should be set");

        // Queue a new ruleset (B). It will be rejected by A's approval hook.
        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectId, rulesetConfigurations: _buildRejectedConfig(), memo: ""});

        // Verify B is now the latest but A is still the current (B is rejected).
        uint256 latestId = _rulesets.latestRulesetIdOf(_projectId);
        assertGt(latestId, initial.id, "Latest should be B");
        JBRuleset memory afterQueue = _rulesets.currentOf(_projectId);
        assertEq(afterQueue.id, initial.id, "Current should still be A (B is rejected)");

        // Warp beyond the 20,000-cycle cache threshold.
        vm.warp(block.timestamp + 20_001);

        // Before the fix, currentOf() would revert here with WeightCacheRequired.
        // After the fix, updateRulesetWeightCache walks back to A and updates A's cache.
        _rulesets.updateRulesetWeightCache(_projectId);

        // Now currentOf() should succeed because A's cache is populated.
        JBRuleset memory afterFix = _rulesets.currentOf(_projectId);
        assertEq(afterFix.id, initial.id, "Should still use ruleset A");
        // Weight should be less than initial (decayed over 20k+ cycles).
        assertLt(afterFix.weight, initial.weight, "Weight should have decayed");
    }

    /// @notice Multiple cache updates work correctly when the latest is rejected.
    /// Verifies that progressive caching (multiple updateRulesetWeightCache calls) also
    /// works for the base ruleset, not just the latest.
    function test_weightCache_progressiveCachingForRejectedLatest() public {
        _projectId = _launchProject();

        // Queue a rejected ruleset.
        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectId, rulesetConfigurations: _buildRejectedConfig(), memo: ""});

        // Warp far into the future (50k cycles — needs 3 cache update calls).
        vm.warp(block.timestamp + 50_001);

        // First cache update covers up to 20k cycles.
        _rulesets.updateRulesetWeightCache(_projectId);
        // Second covers up to 40k.
        _rulesets.updateRulesetWeightCache(_projectId);
        // Third covers up to 50k.
        _rulesets.updateRulesetWeightCache(_projectId);

        // currentOf() should now work.
        JBRuleset memory current = _rulesets.currentOf(_projectId);
        assertGt(current.cycleNumber, 50_000, "Should be past 50k cycles");
    }

    /// @notice With the fix applied, payments and cashouts continue to work even after
    /// a rejected ruleset + large cycle gap.
    function test_weightCache_terminalOperationsWorkAfterFix() public {
        // Set up terminal for the project.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});

        // Launch with terminals.
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 1,
            weight: 1000e18,
            weightCutPercent: 1,
            approvalHook: _rejectHook,
            metadata: JBRulesetMetadata({
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
                useTotalSurplusForCashOuts: true,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        vm.prank(_projectOwner);
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://test",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Make a payment so there are funds in the terminal.
        address payer = makeAddr("payer");
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Queue a rejected ruleset.
        vm.prank(_projectOwner);
        _controller.queueRulesetsOf({projectId: _projectId, rulesetConfigurations: _buildRejectedConfig(), memo: ""});

        // Warp beyond 20k cycles.
        vm.warp(block.timestamp + 20_001);

        // Update the cache (fix: this now updates A's cache, not B's).
        _rulesets.updateRulesetWeightCache(_projectId);

        // Payments should succeed after cache update.
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 tokenBalance = jbTokens().totalBalanceOf(payer, _projectId);
        assertGt(tokenBalance, 0, "Payer should have tokens after fix");
    }
}
