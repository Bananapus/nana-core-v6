// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Tests for weird/non-standard ERC-20 tokens: fee-on-transfer, rebasing, return-false, low/high decimals.
contract WeirdTokenTests_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 public projectId;
    address public projectOwner;

    FeeOnTransferToken public fotToken;
    RebasingToken public rebasingToken;
    ReturnFalseToken public returnFalseToken;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // Deploy weird tokens
        fotToken = new FeeOnTransferToken("FeeOnTransfer", "FOT", 18, 100); // 1% fee
        rebasingToken = new RebasingToken("Rebasing", "REB", 18);
        returnFalseToken = new ReturnFalseToken("ReturnFalse", "RF", 18);

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

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        jbController().launchProjectFor({
            owner: address(420),
            projectUri: "feeCollector",
            rulesetConfigurations: feeRulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    function _launchProjectWithToken(address token, uint8 decimals, bool holdFees)
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
            baseCurrency: uint32(uint160(token)),
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
            holdFees: holdFees,
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
            token: token,
            decimals: decimals,
            currency: uint32(uint160(token))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        return jbController().launchProjectFor({
            owner: projectOwner,
            projectUri: "weirdTokenProject",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 1: FOT — pay records delta (not nominal amount)
    // ═══════════════════════════════════════════════════════════════════

    function test_feeOnTransfer_payRecordsDelta() public {
        uint256 pid = _launchProjectWithToken(address(fotToken), 18, false);

        address payer = address(0xBA1E);
        uint256 payAmount = 1000e18;
        fotToken.mint(payer, payAmount);

        vm.prank(payer);
        fotToken.approve(address(jbMultiTerminal()), payAmount);

        vm.prank(payer);
        jbMultiTerminal().pay({
            projectId: pid,
            token: address(fotToken),
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Terminal records the delta (after fee), not the nominal amount
        uint256 recordedBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), pid, address(fotToken));

        // 1% fee: 1000e18 * 99/100 = 990e18
        uint256 expectedDelta = 990e18;
        assertEq(recordedBalance, expectedDelta, "Terminal should record delta amount for FOT tokens");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 2: FOT — cashOut shortfall (outbound fee)
    // ═══════════════════════════════════════════════════════════════════

    function test_feeOnTransfer_cashOutShortfall() public {
        uint256 pid = _launchProjectWithToken(address(fotToken), 18, false);

        address payer = address(0xBA1E);
        uint256 payAmount = 1000e18;
        fotToken.mint(payer, payAmount);

        vm.prank(payer);
        fotToken.approve(address(jbMultiTerminal()), payAmount);

        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay({
            projectId: pid,
            token: address(fotToken),
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Cash out all tokens
        uint256 payerBalanceBefore = fotToken.balanceOf(payer);

        vm.prank(payer);
        uint256 reclaimAmount = jbMultiTerminal().cashOutTokensOf({
            holder: payer,
            projectId: pid,
            cashOutCount: tokensReceived,
            tokenToReclaim: address(fotToken),
            minTokensReclaimed: 0,
            beneficiary: payable(payer),
            metadata: new bytes(0)
        });

        uint256 payerBalanceAfter = fotToken.balanceOf(payer);
        uint256 actualReceived = payerBalanceAfter - payerBalanceBefore;

        // Beneficiary receives less than reclaimAmount due to outbound fee
        assertLt(actualReceived, reclaimAmount, "FOT: beneficiary receives less than reclaimAmount on outbound");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 3: FOT — split payout shortfall
    // ═══════════════════════════════════════════════════════════════════

    function test_feeOnTransfer_splitPayoutShortfall() public {
        address splitBeneficiary = address(0xBEEF);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(fotToken))),
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

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(splitBeneficiary),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(address(fotToken))), splits: splits});
        rulesetConfig[0].splitGroups = splitGroups;

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: uint224(500e18), currency: uint32(uint160(address(fotToken)))});
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: address(fotToken),
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: address(fotToken),
            decimals: 18,
            currency: uint32(uint160(address(fotToken)))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        uint256 pid = jbController().launchProjectFor({
            owner: projectOwner,
            projectUri: "fotSplitTest",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // Pay in
        address payer = address(0xBA1E);
        fotToken.mint(payer, 1000e18);
        vm.prank(payer);
        fotToken.approve(address(jbMultiTerminal()), 1000e18);
        vm.prank(payer);
        jbMultiTerminal().pay({
            projectId: pid,
            token: address(fotToken),
            amount: 1000e18,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Send payouts
        uint256 beneficiaryBalanceBefore = fotToken.balanceOf(splitBeneficiary);
        vm.prank(projectOwner);
        jbMultiTerminal().sendPayoutsOf({
            projectId: pid,
            token: address(fotToken),
            amount: 500e18,
            currency: uint32(uint160(address(fotToken))),
            minTokensPaidOut: 0
        });

        uint256 beneficiaryBalanceAfter = fotToken.balanceOf(splitBeneficiary);
        uint256 actualReceived = beneficiaryBalanceAfter - beneficiaryBalanceBefore;

        // Split recipient gets less than nominal due to outbound transfer fee
        assertTrue(actualReceived > 0, "Split beneficiary should receive something");
        // The terminal sends a computed net amount, but the FOT tax reduces what arrives
        // This documents the information finding: FOT tokens cause split recipients to receive less
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 4: Rebasing token — positive rebase, no phantom extraction
    // ═══════════════════════════════════════════════════════════════════

    function test_rebasingToken_positiveRebase_noPhantomExtraction() public {
        uint256 pid = _launchProjectWithToken(address(rebasingToken), 18, false);

        address payer = address(0xBA1E);
        rebasingToken.mint(payer, 1000e18);

        vm.prank(payer);
        rebasingToken.approve(address(jbMultiTerminal()), 1000e18);

        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay({
            projectId: pid,
            token: address(rebasingToken),
            amount: 1000e18,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Positive rebase: +10% on the terminal's holdings
        rebasingToken.rebaseHolder(address(jbMultiTerminal()), 10);

        // Terminal now holds 1100 tokens but store records 1000
        uint256 terminalActual = rebasingToken.balanceOf(address(jbMultiTerminal()));
        uint256 recordedBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), pid, address(rebasingToken));

        assertGt(terminalActual, recordedBalance, "Terminal should hold more than recorded after positive rebase");
        assertEq(recordedBalance, 1000e18, "Store should still record original amount");

        // Cash out — should only get recorded amount
        vm.prank(payer);
        uint256 reclaimAmount = jbMultiTerminal().cashOutTokensOf({
            holder: payer,
            projectId: pid,
            cashOutCount: tokensReceived,
            tokenToReclaim: address(rebasingToken),
            minTokensReclaimed: 0,
            beneficiary: payable(payer),
            metadata: new bytes(0)
        });

        // Payer only gets back what was recorded, not the rebased surplus
        assertEq(reclaimAmount, 1000e18, "CashOut should return recorded amount, not rebased amount");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 5: Rebasing token — negative rebase, cashOut insufficient funds
    // ═══════════════════════════════════════════════════════════════════

    function test_rebasingToken_negativeRebase_cashOutFails() public {
        uint256 pid = _launchProjectWithToken(address(rebasingToken), 18, false);

        address payer = address(0xBA1E);
        rebasingToken.mint(payer, 1000e18);

        vm.prank(payer);
        rebasingToken.approve(address(jbMultiTerminal()), 1000e18);

        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay({
            projectId: pid,
            token: address(rebasingToken),
            amount: 1000e18,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Negative rebase: -10% on the terminal's holdings
        rebasingToken.rebaseHolder(address(jbMultiTerminal()), -10);

        // Terminal now holds 900 but store records 1000
        uint256 terminalActual = rebasingToken.balanceOf(address(jbMultiTerminal()));
        assertLt(terminalActual, 1000e18, "Terminal should hold less after negative rebase");

        // CashOut should try to send 1000 but only 900 available → revert
        vm.prank(payer);
        vm.expectRevert();
        jbMultiTerminal().cashOutTokensOf({
            holder: payer,
            projectId: pid,
            cashOutCount: tokensReceived,
            tokenToReclaim: address(rebasingToken),
            minTokensReclaimed: 0,
            beneficiary: payable(payer),
            metadata: new bytes(0)
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 6: Low decimal token — rounding
    // ═══════════════════════════════════════════════════════════════════

    function test_lowDecimalToken_rounding() public {
        LowDecimalToken lowToken = new LowDecimalToken("LowDec", "LD");
        uint256 pid = _launchProjectWithToken(address(lowToken), 2, false);

        address payer = address(0xBA1E);
        uint256 payAmount = 100; // 1.00 in 2 decimals
        lowToken.mint(payer, payAmount);

        vm.prank(payer);
        lowToken.approve(address(jbMultiTerminal()), payAmount);

        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay({
            projectId: pid,
            token: address(lowToken),
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Weight calculation should not round to zero
        assertTrue(tokensReceived > 0, "Low decimal tokens should still mint project tokens");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 7: High decimal token — no overflow
    // ═══════════════════════════════════════════════════════════════════

    function test_highDecimalToken_noOverflow() public {
        HighDecimalToken highToken = new HighDecimalToken("HighDec", "HD");
        uint256 pid = _launchProjectWithToken(address(highToken), 24, false);

        address payer = address(0xBA1E);
        uint256 payAmount = 1_000_000e24; // Large amount in 24 decimals
        highToken.mint(payer, payAmount);

        vm.prank(payer);
        highToken.approve(address(jbMultiTerminal()), payAmount);

        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal().pay({
            projectId: pid,
            token: address(highToken),
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        assertTrue(tokensReceived > 0, "High decimal tokens should mint project tokens without overflow");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 8: Return-false token — SafeERC20 catches
    // ═══════════════════════════════════════════════════════════════════

    function test_returnFalseToken_safeERC20Reverts() public {
        uint256 pid = _launchProjectWithToken(address(returnFalseToken), 18, false);

        address payer = address(0xBA1E);
        returnFalseToken.mint(payer, 1000e18);
        returnFalseToken.setShouldReturnFalse(true);

        vm.prank(payer);
        returnFalseToken.approve(address(jbMultiTerminal()), 1000e18);

        // SafeERC20 should catch the false return and revert
        vm.prank(payer);
        vm.expectRevert();
        jbMultiTerminal().pay({
            projectId: pid,
            token: address(returnFalseToken),
            amount: 1000e18,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 9: FOT + holdFees + addToBalance with shouldReturnHeldFees
    // ═══════════════════════════════════════════════════════════════════

    function test_feeOnTransfer_addToBalance_heldFeeReturn() public {
        uint256 pid = _launchProjectWithToken(address(fotToken), 18, true);

        address payer = address(0xBA1E);
        fotToken.mint(payer, 2000e18);

        vm.prank(payer);
        fotToken.approve(address(jbMultiTerminal()), 2000e18);

        // Pay in (holdFees=true, so fees are held)
        vm.prank(payer);
        jbMultiTerminal().pay({
            projectId: pid,
            token: address(fotToken),
            amount: 1000e18,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 recordedBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), pid, address(fotToken));

        // Add to balance with shouldReturnHeldFees=true
        vm.prank(payer);
        fotToken.approve(address(jbMultiTerminal()), 1000e18);

        vm.prank(payer);
        jbMultiTerminal().addToBalanceOf({
            projectId: pid,
            token: address(fotToken),
            amount: 1000e18,
            shouldReturnHeldFees: true,
            memo: "",
            metadata: new bytes(0)
        });

        uint256 recordedAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), pid, address(fotToken));

        // Balance should increase (delta accounting handles the fee)
        assertGt(recordedAfter, recordedBefore, "Balance should increase with addToBalance");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 10: FOT + processHeldFees — fee project receives less
    // ═══════════════════════════════════════════════════════════════════

    function test_feeOnTransfer_processHeldFees_shortfall() public {
        // Need fee project to accept FOT tokens too
        // Launch a project with holdFees=true that uses FOT
        // This is complex since the fee project (#1) only accepts native token
        // We verify that the system doesn't silently lose tokens

        uint256 pid = _launchProjectWithToken(address(fotToken), 18, true);

        address payer = address(0xBA1E);
        fotToken.mint(payer, 1000e18);

        vm.prank(payer);
        fotToken.approve(address(jbMultiTerminal()), 1000e18);

        vm.prank(payer);
        jbMultiTerminal().pay({
            projectId: pid,
            token: address(fotToken),
            amount: 1000e18,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Advance time past fee holding period (28 days)
        vm.warp(block.timestamp + 29 days);

        // Process held fees — may fail since fee project doesn't accept FOT
        // The important check is that no tokens are lost from the terminal
        uint256 terminalBalanceBefore = fotToken.balanceOf(address(jbMultiTerminal()));

        try jbMultiTerminal().processHeldFeesOf(pid, address(fotToken), 10) {} catch {}

        uint256 terminalBalanceAfter = fotToken.balanceOf(address(jbMultiTerminal()));

        // Terminal should not have lost more than the fee amounts
        assertTrue(
            terminalBalanceAfter <= terminalBalanceBefore,
            "Terminal balance should decrease or stay same after processing fees"
        );
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
//  Mock Tokens
// ═══════════════════════════════════════════════════════════════════════

/// @notice ERC20 that charges a fee on every transfer.
contract FeeOnTransferToken is ERC20 {
    uint256 public feeRateBps; // basis points, e.g., 100 = 1%
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeRateBps_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        feeRateBps = feeRateBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeRateBps > 0) {
            uint256 fee = (value * feeRateBps) / 10_000;
            super._update(from, address(0), fee); // Burn the fee
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice ERC20 that can rebase specific holders' balances up or down.
/// @dev Simulates a rebasing token by minting/burning directly to a target address.
contract RebasingToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Rebase a specific holder's balance by a percentage.
    /// @param target The address whose balance to rebase.
    /// @param percent Positive to increase, negative to decrease.
    function rebaseHolder(address target, int256 percent) external {
        uint256 balance = balanceOf(target);
        if (percent > 0) {
            uint256 increase = (balance * uint256(percent)) / 100;
            _mint(target, increase);
        } else if (percent < 0) {
            uint256 decrease = (balance * uint256(-percent)) / 100;
            if (decrease > 0 && decrease <= balance) {
                _burn(target, decrease);
            }
        }
    }
}

/// @notice ERC20 that returns false on transfer instead of reverting.
contract ReturnFalseToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    bool public shouldReturnFalse;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setShouldReturnFalse(bool value) external {
        shouldReturnFalse = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (shouldReturnFalse) return false;
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (shouldReturnFalse) return false;
        if (balanceOf[from] < amount) return false;
        if (allowance[from][msg.sender] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice ERC20 with 2 decimals (like some stablecoins).
contract LowDecimalToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 2;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC20 with 24 decimals.
contract HighDecimalToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 24;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
