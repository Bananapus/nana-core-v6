// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

/// @notice Property fuzz: for ANY sequence of {pay, addToBalance, cashOut} performed atomically (one transaction)
/// by a single attacker, the attacker's net ETH flow must be non-positive. This generalizes the hand-crafted cases
/// in `FlashLoanAttacks.t.sol` (which enumerate 12 specific attacks) into a universal property over short sequences.
///
/// The protection that makes this hold:
///   - pay + immediate cashOut returns less than paid (cashOutTaxRate burns the round-trip)
///   - addToBalance gives no tokens, so cashOut from that path returns 0
///   - sequential pay-then-cashOut cycles compound the tax, never escape it
///
/// The fuzz draws a 1-byte action selector per step (0=pay, 1=cashOut, 2=addToBalance) and a 16-byte amount.
/// Up to 5 actions per sequence (longer = slower to fuzz; 5 is enough to exercise interleaving).
contract FlashLoanAttacksFuzz is TestBaseWorkflow {
    uint256 internal projectId;
    address internal projectOwner;
    address internal attacker = address(0xA77AC0);

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();
        _launchFeeProject();
        _launchTestProject();
    }

    /// @notice Universal no-profit property over random atomic action sequences.
    /// @dev `actions` is a packed byte string: low nibble is action selector, high nibble is unused. `amounts`
    /// is the per-step amount (bounded). Seed projects start with 50 ETH pre-paid so the attacker has a non-empty
    /// surplus to attempt to drain.
    function testFuzz_atomicSequence_noNetProfit(
        uint8 a0,
        uint8 a1,
        uint8 a2,
        uint8 a3,
        uint8 a4,
        uint256[5] memory amounts
    )
        public
    {
        // Pre-seed the project so there's surplus to attempt to drain.
        _payProject(address(0x5EED), 50 ether);

        // Fund the attacker generously; we measure NET flow at the end.
        uint256 startingBalance = 1000 ether;
        vm.deal(attacker, startingBalance);

        uint8[5] memory actions = [a0, a1, a2, a3, a4];
        for (uint256 i; i < 5; ++i) {
            _doAction({selector: actions[i] % 3, amount: amounts[i]});
        }

        // Cash out everything the attacker still holds, so any latent token value is converted to ETH.
        uint256 finalTokens = jbTokens().totalBalanceOf(attacker, projectId);
        if (finalTokens > 0) _tryCashOut(finalTokens);

        // The attacker may have spent ETH on calls; they must NEVER have more than they started with.
        assertLe(
            attacker.balance,
            startingBalance,
            "atomic sequence yielded net profit to a single actor - flash-loan protection broken"
        );
    }

    function _doAction(uint256 selector, uint256 amount) internal {
        if (selector == 0) {
            amount = _boundLocal(amount, 0, 100 ether);
            if (attacker.balance < amount || amount == 0) return;
            _tryPay(amount);
        } else if (selector == 1) {
            uint256 holdings = jbTokens().totalBalanceOf(attacker, projectId);
            if (holdings == 0) return;
            uint256 burn = _boundLocal(amount, 1, holdings);
            _tryCashOut(burn);
        } else {
            amount = _boundLocal(amount, 0, 100 ether);
            if (attacker.balance < amount || amount == 0) return;
            _tryAddToBalance(amount);
        }
    }

    function _tryPay(uint256 amount) internal {
        vm.prank(attacker);
        try jbMultiTerminal().pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        }) returns (
            uint256
        ) {}
            catch {}
    }

    function _tryCashOut(uint256 count) internal {
        vm.prank(attacker);
        try jbMultiTerminal()
            .cashOutTokensOf({
            holder: attacker,
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(attacker),
            metadata: new bytes(0)
        }) returns (
            uint256
        ) {}
            catch {}
    }

    function _tryAddToBalance(uint256 amount) internal {
        vm.prank(attacker);
        try jbMultiTerminal().addToBalanceOf{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        }) {}
            catch {}
    }

    function _boundLocal(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (v % (hi - lo + 1));
    }

    // -- setup helpers --

    function _launchFeeProject() internal {
        JBRulesetConfig[] memory cfg = _basicRulesetConfig(0);
        jbController()
            .launchProjectFor({
            owner: address(420),
            projectUri: "feeCollector",
            rulesetConfigurations: cfg,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
    }

    function _launchTestProject() internal {
        JBRulesetConfig[] memory cfg = _basicRulesetConfig(3000); // 30% cash out tax
        projectId = jbController()
            .launchProjectFor({
            owner: projectOwner,
            projectUri: "flashFuzz",
            rulesetConfigurations: cfg,
            terminalConfigurations: _defaultTerminalConfig(),
            memo: ""
        });
        vm.prank(projectOwner);
        jbController().deployERC20For(projectId, "FT", "FT", bytes32(0));
    }

    function _basicRulesetConfig(uint16 cashOutTaxRate) internal pure returns (JBRulesetConfig[] memory cfg) {
        cfg = new JBRulesetConfig[](1);
        cfg[0].mustStartAtOrAfter = 0;
        cfg[0].duration = 0;
        cfg[0].weight = 1000e18;
        cfg[0].weightCutPercent = 0;
        cfg[0].approvalHook = IJBRulesetApprovalHook(address(0));
        cfg[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        cfg[0].splitGroups = new JBSplitGroup[](0);
        cfg[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
    }

    function _defaultTerminalConfig() internal view returns (JBTerminalConfig[] memory) {
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        JBAccountingContext[] memory ctx = new JBAccountingContext[](1);
        ctx[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: ctx});
        return tc;
    }

    function _payProject(address payer, uint256 amount) internal {
        vm.deal(payer, amount);
        vm.prank(payer);
        jbMultiTerminal().pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }
}
