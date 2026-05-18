// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

/// @notice Same-project `preferAddToBalance` splits must not inflate `_feeFreeSurplusOf`.
/// @dev A split that routes a project's payout back to itself on the same terminal does not move funds outside the
/// project, so crediting `_feeFreeSurplusOf` would charge fees against the project's own future zero-tax cashouts
/// for value that never left.
contract FeeFreeSurplusSameProjectTest is TestBaseWorkflow {
    // --- State ---

    IJBController private _controller;
    JBMultiTerminal private _terminal;

    // The project whose payout split routes back to itself.
    uint256 private _projectId;
    address private _projectOwner;

    uint112 private constant WEIGHT = 1000 * 10 ** 18;
    uint256 private constant PAY_AMOUNT = 10 ether;
    uint32 private constant CYCLE_DURATION = 1 days;

    // Storage slot index for _feeFreeSurplusOf in JBMultiTerminal (verified via FeeFreeSurplusLifecycle.t.sol).
    uint256 private constant FEE_FREE_SURPLUS_SLOT = 0;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _terminal = jbMultiTerminal();
        _projectOwner = multisig();

        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: accountingContexts});

        // Fee project must exist before any fee-charging operations.
        JBRulesetConfig[] memory feeProjectRuleset = new JBRulesetConfig[](1);
        feeProjectRuleset[0] = _rulesetConfig(0, new JBSplitGroup[](0), new JBFundAccessLimitGroup[](0));
        _controller.launchProjectFor({
            owner: makeAddr("fee-project-owner"),
            projectUri: "fee-project",
            rulesetConfigurations: feeProjectRuleset,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Launch project with a placeholder split first; we patch the split to self-reference after we know its id.
        JBRulesetConfig[] memory placeholderRuleset = new JBRulesetConfig[](1);
        placeholderRuleset[0] = _rulesetConfig(0, new JBSplitGroup[](0), new JBFundAccessLimitGroup[](0));
        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "self-split-project",
            rulesetConfigurations: placeholderRuleset,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });

        // Now queue a ruleset whose payout split routes 100% back to this same project via addToBalance.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: true,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint64(_projectId),
            beneficiary: payable(address(0)),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint32(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint224(PAY_AMOUNT),
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBFundAccessLimitGroup[] memory limits = new JBFundAccessLimitGroup[](1);
        limits[0] = JBFundAccessLimitGroup({
            terminal: address(_terminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory selfSplitRuleset = new JBRulesetConfig[](1);
        selfSplitRuleset[0] = _rulesetConfig(CYCLE_DURATION, splitGroups, limits);

        vm.prank(_projectOwner);
        _controller.queueRulesetsOf(_projectId, selfSplitRuleset, "");
    }

    /// @notice After a same-project preferAddToBalance payout, `_feeFreeSurplusOf` stays at zero because funds never
    /// left the project balance.
    function test_sameProjectPreferAddToBalanceDoesNotInflateFeeFreeSurplus() external {
        // Fund the project.
        address payer = makeAddr("payer");
        vm.deal(payer, PAY_AMOUNT);
        vm.prank(payer);
        _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 balanceBefore = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 surplusBefore = _readFeeFreeSurplus(_projectId, JBConstants.NATIVE_TOKEN);
        assertEq(surplusBefore, 0, "Precondition: fee-free surplus is zero before payout");

        // Execute the self-referencing payout. Funds flow: project -> split -> same project via addToBalance.
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            token: JBConstants.NATIVE_TOKEN,
            minTokensPaidOut: 0
        });

        uint256 balanceAfter = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        uint256 surplusAfter = _readFeeFreeSurplus(_projectId, JBConstants.NATIVE_TOKEN);

        // Funds never left this project's balance.
        assertEq(balanceAfter, balanceBefore, "Same-project payout should leave the project's balance unchanged");

        // KEY ASSERTION: same-project preferAddToBalance must not credit fee-free surplus.
        // Without the guard, this would equal `netPayoutAmount` (the full PAY_AMOUNT, since intra-terminal
        // splits pay no fee), permanently inflating the fee-eligible portion of future zero-tax cashouts.
        assertEq(surplusAfter, 0, "Same-project preferAddToBalance must not inflate _feeFreeSurplusOf");
    }

    /// @notice Read `_feeFreeSurplusOf[projectId][token]` directly from JBMultiTerminal storage.
    function _readFeeFreeSurplus(uint256 projectId, address token) private view returns (uint256) {
        bytes32 innerSlot = keccak256(abi.encode(projectId, FEE_FREE_SURPLUS_SLOT));
        bytes32 finalSlot = keccak256(abi.encode(token, innerSlot));
        return uint256(vm.load(address(_terminal), finalSlot));
    }

    function _rulesetConfig(
        uint32 duration,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        private
        pure
        returns (JBRulesetConfig memory config)
    {
        config.mustStartAtOrAfter = 0;
        config.duration = duration;
        config.weight = WEIGHT;
        config.weightCutPercent = 0;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: true,
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
        config.splitGroups = splitGroups;
        config.fundAccessLimitGroups = fundAccessLimitGroups;
    }
}
