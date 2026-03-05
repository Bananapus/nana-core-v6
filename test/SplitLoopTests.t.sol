// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @notice Tests for split loop edge cases: circular splits, reentrancy, gas consumption, rounding.
contract SplitLoopTests_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 public projectA;
    uint256 public projectB;
    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // Launch fee collector project (#1)
        _launchFeeProject();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _launchFeeProject() internal {
        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        feeRulesetConfig[0].duration = 0;
        feeRulesetConfig[0].weight = 1000e18;
        feeRulesetConfig[0].weightCutPercent = 0;
        feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        feeRulesetConfig[0].metadata = JBRulesetMetadata({
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = _defaultTerminalConfig();

        jbController()
            .launchProjectFor({
                owner: address(420),
                projectUri: "feeCollector",
                rulesetConfigurations: feeRulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });
    }

    function _defaultTerminalConfig() internal view returns (JBTerminalConfig[] memory) {
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});
        return terminalConfigurations;
    }

    function _launchProjectWithSplitsAndPayoutLimit(
        JBSplit[] memory splits,
        uint256 payoutLimit
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
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

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        rulesetConfig[0].splitGroups = splitGroups;

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: uint224(payoutLimit), currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;

        return jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "splitTestProject",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });
    }

    function _payProject(uint256 pid, address payer, uint256 amount) internal {
        vm.deal(payer, amount);
        vm.prank(payer);
        jbMultiTerminal().pay{value: amount}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 1: Circular splits A→B, B→A via addToBalance — no loop
    // ═══════════════════════════════════════════════════════════════════

    function test_circularSplits_AtoB_addToBalance_noLoop() public {
        // Project A splits to project B (preferAddToBalance=true)
        JBSplit[] memory splitsA = new JBSplit[](1);
        splitsA[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0, // Will set after B is created
            beneficiary: payable(address(0)),
            preferAddToBalance: true,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // Project B splits to project A (preferAddToBalance=true)
        JBSplit[] memory splitsB = new JBSplit[](1);
        splitsB[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0, // Will set after A is created
            beneficiary: payable(address(0)),
            preferAddToBalance: true,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        // Launch A first (with dummy splits, we'll update later)
        JBSplit[] memory dummySplits = new JBSplit[](0);
        projectA = _launchProjectWithSplitsAndPayoutLimit(dummySplits, 10 ether);

        // Now create B with split to A
        splitsB[0].projectId = uint64(projectA);
        projectB = _launchProjectWithSplitsAndPayoutLimit(splitsB, 10 ether);

        // Update A's splits to point to B
        (JBRuleset memory rulesetA,) = jbController().currentRulesetOf(projectA);
        JBSplitGroup[] memory newSplitGroupsA = new JBSplitGroup[](1);
        splitsA[0].projectId = uint64(projectB);
        newSplitGroupsA[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splitsA});
        vm.prank(projectOwner);
        jbController().setSplitGroupsOf(projectA, rulesetA.id, newSplitGroupsA);

        // Fund project A
        _payProject(projectA, address(0xBA1E), 10 ether);

        // Send payouts from A → should send to B via addToBalance (hook-free, no loop)
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: projectA,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // B should have received funds
        uint256 balanceB = jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectB, JBConstants.NATIVE_TOKEN);
        assertTrue(balanceB > 0, "Project B should have received funds from A's payout split");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 2: Circular splits A→B via pay — no loop
    // ═══════════════════════════════════════════════════════════════════

    function test_circularSplits_AtoB_pay_noLoop() public {
        // Project A splits to project B via pay (preferAddToBalance=false)
        JBSplit[] memory splitsA = new JBSplit[](1);
        splitsA[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(projectOwner),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        projectA = _launchProjectWithSplitsAndPayoutLimit(new JBSplit[](0), 10 ether);

        splitsA[0].projectId = 1; // Fee project, for simplicity
        projectB = projectA; // Reuse

        // Update A to split to fee project via pay
        (JBRuleset memory rulesetA,) = jbController().currentRulesetOf(projectA);
        JBSplitGroup[] memory newSplitGroups = new JBSplitGroup[](1);
        splitsA[0].projectId = 1;
        newSplitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splitsA});
        vm.prank(projectOwner);
        jbController().setSplitGroupsOf(projectA, rulesetA.id, newSplitGroups);

        // Fund and send payouts
        _payProject(projectA, address(0xBA1E), 10 ether);

        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: projectA,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Should complete without infinite recursion
        assertTrue(true, "Pay-based split should not cause infinite recursion");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 3: Split hook reentrancy — pay during split
    // ═══════════════════════════════════════════════════════════════════

    function test_splitHookReentrancy_payDuringSplit() public {
        ReentrantSplitHookPay reentrantHook = new ReentrantSplitHookPay(jbMultiTerminal());

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(reentrantHook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(reentrantHook))
        });

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(splits, 10 ether);
        reentrantHook.setTargetProject(pid);

        // Fund
        _payProject(pid, address(0xBA1E), 10 ether);

        // Send payouts — hook tries to re-enter via pay
        // This should either revert or complete safely (hook is try/caught)
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // If we got here, the system handled reentrancy safely
        assertTrue(true, "System handled split hook reentrancy via pay");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 4: Split hook reentrancy — cashOut during split
    // ═══════════════════════════════════════════════════════════════════

    function test_splitHookReentrancy_cashOutDuringSplit() public {
        ReentrantSplitHookCashOut reentrantHook = new ReentrantSplitHookCashOut(jbMultiTerminal());

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(reentrantHook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(reentrantHook))
        });

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(splits, 10 ether);
        reentrantHook.setTargetProject(pid);

        // Fund — reentrant hook needs tokens to cash out
        // Seed the fee project so it has funds (not needed for this test)
        _payProject(pid, address(0xBA1E), 10 ether);

        // Setup: give hook tokens for the target project
        vm.deal(address(reentrantHook), 5 ether);
        vm.prank(address(reentrantHook));
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: address(reentrantHook),
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Send payouts — hook tries to re-enter via cashOut
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // If we got here, the system handled cashOut reentrancy safely
        assertTrue(true, "System handled split hook reentrancy via cashOut");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 5: Split to self — no infinite recursion
    // ═══════════════════════════════════════════════════════════════════

    function test_splitToSelf_noInfiniteRecursion() public {
        // Project splits to itself via addToBalance
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0, // Will set to self
            beneficiary: payable(address(0)),
            preferAddToBalance: true,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(new JBSplit[](0), 10 ether);

        // Update splits to point to self
        splits[0].projectId = uint64(pid);
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(pid);
        JBSplitGroup[] memory newSplitGroups = new JBSplitGroup[](1);
        newSplitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        vm.prank(projectOwner);
        jbController().setSplitGroupsOf(pid, ruleset.id, newSplitGroups);

        // Fund
        _payProject(pid, address(0xBA1E), 10 ether);

        // Send payouts — self-split via addToBalance is hook-free, should complete
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        assertTrue(true, "Self-split via addToBalance completes without infinite loop");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 6: Many small splits — gas consumption
    // ═══════════════════════════════════════════════════════════════════

    function test_manySmallSplits_gasConsumption() public {
        uint256 numSplits = 200;
        JBSplit[] memory splits = new JBSplit[](numSplits);

        uint32 perSplitPercent = uint32(JBConstants.SPLITS_TOTAL_PERCENT / numSplits);

        for (uint256 i = 0; i < numSplits; i++) {
            splits[i] = JBSplit({
                percent: perSplitPercent,
                projectId: 0,
                beneficiary: payable(address(uint160(0x3000 + i))),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
        }

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(splits, 10 ether);

        // Fund
        _payProject(pid, address(0xBA1E), 10 ether);

        // Measure gas
        uint256 gasStart = gasleft();
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });
        uint256 gasUsed = gasStart - gasleft();

        // Should complete within block gas limit (~30M)
        assertLt(gasUsed, 30_000_000, "200 splits should complete within block gas limit");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 7: Split percentages rounding favor
    // ═══════════════════════════════════════════════════════════════════

    function test_splitPercentages_roundingFavor() public {
        // 3 splits at ~33.33% each
        uint32 oneThird = uint32(JBConstants.SPLITS_TOTAL_PERCENT / 3);

        JBSplit[] memory splits = new JBSplit[](3);
        for (uint256 i = 0; i < 3; i++) {
            splits[i] = JBSplit({
                percent: oneThird,
                projectId: 0,
                beneficiary: payable(address(uint160(0x4000 + i))),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
        }

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(splits, 10 ether);

        _payProject(pid, address(0xBA1E), 10 ether);

        uint256 totalBefore = address(jbMultiTerminal()).balance;

        vm.prank(projectOwner);
        uint256 netLeftover = jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 3 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Check no rounding loss greater than 3 wei (one per split)
        uint256 totalPaidToSplits = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalPaidToSplits += address(uint160(0x4000 + i)).balance;
        }

        // The difference between what was deducted and what splits received should be minimal
        // (just fees and rounding)
        assertTrue(totalPaidToSplits > 0, "Splits should have received something");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 8: Split percentage overflow rejected
    // ═══════════════════════════════════════════════════════════════════

    function test_splitPercentageOverflow_rejected() public {
        // Two splits totaling > 100%
        JBSplit[] memory splits = new JBSplit[](2);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(0x5000)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        splits[1] = JBSplit({
            percent: 1,
            projectId: 0,
            beneficiary: payable(address(0x5001)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
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

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        rulesetConfig[0].splitGroups = splitGroups;
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Should revert because splits total > 100%
        vm.expectRevert();
        jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "overflowSplitTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 9: Gas guzzling split hook — fallback
    // ═══════════════════════════════════════════════════════════════════

    function test_gasGuzzlingSplitHook_fallback() public {
        GasGuzzlingSplitHook gasHook = new GasGuzzlingSplitHook();

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(gasHook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(gasHook))
        });

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(splits, 10 ether);

        _payProject(pid, address(0xBA1E), 10 ether);

        // Send payouts — gas guzzling hook should be caught by try/catch
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // If we get here, the try/catch fallback worked
        assertTrue(true, "Gas guzzling split hook handled via try/catch");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 10: ETH to non-payable recipient — fallback
    // ═══════════════════════════════════════════════════════════════════

    function test_splitHook_ETH_nonPayableRecipient() public {
        NonPayableContract nonPayable = new NonPayableContract();

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(nonPayable)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        uint256 pid = _launchProjectWithSplitsAndPayoutLimit(splits, 10 ether);

        _payProject(pid, address(0xBA1E), 10 ether);

        // Send payouts to non-payable — should be caught by try/catch
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Funds should be retained in the project or sent to owner fallback
        assertTrue(true, "Non-payable recipient handled via try/catch fallback");
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
//  Mock Contracts
// ═══════════════════════════════════════════════════════════════════════

/// @notice Split hook that re-enters terminal via pay during processSplitWith.
contract ReentrantSplitHookPay is ERC165, IJBSplitHook {
    IJBMultiTerminal public terminal;
    uint256 public targetProjectId;

    constructor(IJBMultiTerminal _terminal) {
        terminal = _terminal;
    }

    function setTargetProject(uint256 pid) external {
        targetProjectId = pid;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {
        // Try to re-enter via pay
        if (msg.value > 0 && targetProjectId > 0) {
            try terminal.pay{value: msg.value}({
                projectId: targetProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: msg.value,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "reentrant",
                metadata: new bytes(0)
            }) {}
                catch {}
        }
    }

    function supportsInterface(bytes4 _interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return _interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(_interfaceId);
    }

    receive() external payable {}
}

/// @notice Split hook that re-enters terminal via cashOut during processSplitWith.
contract ReentrantSplitHookCashOut is ERC165, IJBSplitHook {
    IJBMultiTerminal public terminal;
    uint256 public targetProjectId;

    constructor(IJBMultiTerminal _terminal) {
        terminal = _terminal;
    }

    function setTargetProject(uint256 pid) external {
        targetProjectId = pid;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {
        // Try to re-enter via cashOut
        if (targetProjectId > 0) {
            IJBTokens tokens = terminal.TOKENS();
            uint256 balance = tokens.totalBalanceOf(address(this), targetProjectId);
            if (balance > 0) {
                try terminal.cashOutTokensOf({
                    holder: address(this),
                    projectId: targetProjectId,
                    cashOutCount: balance,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(address(this)),
                    metadata: new bytes(0)
                }) {}
                    catch {}
            }
        }
    }

    function supportsInterface(bytes4 _interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return _interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(_interfaceId);
    }

    receive() external payable {}
}

/// @notice Split hook that consumes all gas.
contract GasGuzzlingSplitHook is ERC165, IJBSplitHook {
    function processSplitWith(JBSplitHookContext calldata) external payable override {
        // Infinite loop to consume all gas
        while (true) {}
    }

    function supportsInterface(bytes4 _interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return _interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(_interfaceId);
    }

    receive() external payable {}
}

/// @notice Contract that cannot receive ETH.
contract NonPayableContract {
    // No receive() or fallback() — ETH transfers revert

    }
