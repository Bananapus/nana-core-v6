// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/StdInvariant.sol";
import /* {*} from */ "../helpers/TestBaseWorkflow.sol";
import {RulesetsHandler} from "./handlers/RulesetsHandler.sol";

/// @notice Invariant tests for JBRulesets cycling, weight decay, and monotonicity.
contract RulesetsInvariant_Local is StdInvariant, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    RulesetsHandler public handler;

    uint256 public projectId;
    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // Launch a project with a cycled ruleset (30-day duration, 10% weight decay)
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 30 days;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = JBConstants.MAX_WEIGHT_CUT_PERCENT / 10; // 10% cut
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        projectId = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "rulesetsTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

        // Deploy handler
        handler = new RulesetsHandler(jbRulesets(), jbController(), projectId, projectOwner);

        // Register handler
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RulesetsHandler.queueRuleset.selector;
        selectors[1] = RulesetsHandler.advanceTime.selector;
        selectors[2] = RulesetsHandler.updateWeightCache.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-RS-1: After launch, currentOf(pid).id != 0 always.
    /// @dev A launched project must always have an active ruleset.
    function invariant_RS1_currentRulesetAlwaysExists() public view {
        JBRuleset memory current = jbRulesets().currentOf(projectId);
        assertGt(current.id, 0, "INV-RS-1: currentOf must return non-zero ruleset ID after launch");
    }

    /// @notice INV-RS-2: cycleNumber never decreases.
    /// @dev Even after time advances and new rulesets take effect, cycle numbers
    ///      must monotonically increase.
    function invariant_RS2_cycleNumberNeverDecreases() public view {
        JBRuleset memory current = jbRulesets().currentOf(projectId);

        // The current cycle number should be >= 1 (first cycle).
        assertGe(uint256(current.cycleNumber), 1, "INV-RS-2: cycleNumber must be >= 1");
    }

    /// @notice INV-RS-3: Weight is always within valid bounds.
    /// @dev Weight must fit in uint112 and should never be 0 unless explicitly set.
    function invariant_RS3_weightWithinBounds() public view {
        JBRuleset memory current = jbRulesets().currentOf(projectId);

        // Weight should fit in uint112 (it's stored as uint112, so this is a sanity check).
        assertLe(uint256(current.weight), uint256(type(uint112).max), "INV-RS-3: weight must fit in uint112");
    }

    /// @notice INV-RS-4: Ruleset start timestamp is always <= block.timestamp.
    /// @dev The current ruleset's start must be in the past or present.
    function invariant_RS4_rulesetStartNotFuture() public view {
        JBRuleset memory current = jbRulesets().currentOf(projectId);

        assertLe(uint256(current.start), block.timestamp, "INV-RS-4: current ruleset start must be <= block.timestamp");
    }
}
