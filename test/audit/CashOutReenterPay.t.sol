// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IJBCashOutHook} from "../../src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../../src/interfaces/IJBRulesetDataHook.sol";
import {IJBTokens} from "../../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBFees} from "../../src/libraries/JBFees.sol";
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBAfterCashOutRecordedContext} from "../../src/structs/JBAfterCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "../../src/structs/JBCashOutHookSpecification.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {mul as UD60x18mul, unwrap as UD60x18unwrap, wrap as UD60x18wrap} from "@prb/math/src/UD60x18.sol";

/// @notice A malicious cashout hook that re-enters the terminal via pay() when called during a cashout.
/// @dev This hook receives ETH from the terminal as part of a cashout hook specification,
/// then immediately calls terminal.pay() with that ETH to re-enter the pay flow.
contract MaliciousCashOutHook is ERC165, IJBCashOutHook {
    /// @notice The terminal to re-enter via pay().
    IJBMultiTerminal public terminal;

    /// @notice The project ID to pay into during re-entry.
    uint256 public projectId;

    /// @notice The beneficiary who receives tokens from the re-entrant pay.
    address public payBeneficiary;

    /// @notice Tracks whether the re-entrant pay was executed successfully.
    bool public reentrantPayExecuted;

    /// @notice Tracks how many tokens the re-entrant pay minted.
    uint256 public reentrantTokensMinted;

    /// @notice Configures the hook with the terminal, project, and beneficiary for re-entry.
    /// @param _terminal The terminal to call pay() on during re-entry.
    /// @param _projectId The project to pay into.
    /// @param _payBeneficiary The address that receives tokens from re-entrant pay.
    constructor(IJBMultiTerminal _terminal, uint256 _projectId, address _payBeneficiary) {
        // Store the terminal reference for re-entry.
        terminal = _terminal;
        // Store the project to pay into.
        projectId = _projectId;
        // Store who gets tokens from the re-entrant pay.
        payBeneficiary = _payBeneficiary;
    }

    /// @notice Called by the terminal after a cashout is recorded. Re-enters via pay().
    /// @param context The cashout context provided by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        // Suppress unused variable warning.
        context;

        // Only re-enter if this hook received ETH from the terminal.
        if (msg.value > 0) {
            // Call terminal.pay() with the ETH received, re-entering the payment flow.
            reentrantTokensMinted = terminal.pay{value: msg.value}({
                projectId: projectId,
                amount: msg.value,
                token: JBConstants.NATIVE_TOKEN,
                beneficiary: payBeneficiary,
                minReturnedTokens: 0,
                memo: "reentrant pay from cashout hook",
                metadata: ""
            });

            // Mark that re-entry succeeded.
            reentrantPayExecuted = true;
        }
    }

    /// @notice Declares support for the IJBCashOutHook interface.
    /// @param interfaceId The interface ID to check.
    /// @return True if the interface is IJBCashOutHook or ERC165.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        // Return true for IJBCashOutHook or fall through to ERC165.
        return interfaceId == type(IJBCashOutHook).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Allows this contract to receive ETH (needed to receive funds from terminal).
    receive() external payable {}
}

/// @notice Tests that a cashout hook re-entering the terminal via pay() does not
/// corrupt surplus accounting, inflate fees, or create phantom token balances.
contract CashOutReenterPay is TestBaseWorkflow {
    // Use the metadata resolver to decode packed ruleset metadata.
    using JBRulesetMetadataResolver for JBRuleset;

    /// @notice Fixed weight for deterministic token issuance: 1000 tokens per ETH.
    uint112 private constant WEIGHT = 1000 * 10 ** 18;

    /// @notice Deterministic address used as the mock data hook.
    address private constant DATA_HOOK = address(bytes20(keccak256("datahook")));

    /// @notice Amount of ETH used for the initial payment to the project.
    uint256 private constant PAY_AMOUNT = 10 ether;

    /// @notice Amount of ETH the re-entrant hook will use to call pay().
    uint256 private constant REENTRANT_PAY_AMOUNT = 1 ether;

    /// @notice Reference to the controller contract.
    IJBController private _controller;

    /// @notice Reference to the terminal contract.
    IJBMultiTerminal private _terminal;

    /// @notice Reference to the tokens contract.
    IJBTokens private _tokens;

    /// @notice The project owner address.
    address private _projectOwner;

    /// @notice The beneficiary address for the original cashout.
    address private _beneficiary;

    /// @notice The project ID under test (project 2; project 1 collects fees).
    uint64 private _projectId;

    /// @notice The malicious cashout hook that will re-enter via pay().
    MaliciousCashOutHook private _maliciousHook;

    function setUp() public override {
        // Deploy all core JB contracts via the base workflow.
        super.setUp();

        // Label the mock data hook address for trace readability.
        vm.label(DATA_HOOK, "Data Hook");

        // Cache references to core contracts.
        _controller = jbController();
        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();

        // Configure ruleset metadata: data hook enabled for cashouts, no reserved percent.
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2, // 50% tax rate so fees apply.
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
            useDataHookForCashOut: true, // Enable data hook for cashouts.
            dataHook: DATA_HOOK,
            metadata: 0
        });

        // Build a single ruleset configuration with the above metadata.
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = WEIGHT;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = metadata;
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Set up terminal to accept native token.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: tokensToAccept});

        // Launch project 1 (fee recipient project, required by the protocol).
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "feeProject",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // Launch project 2 (the project under test).
        _projectId = uint64(
            _controller.launchProjectFor({
                owner: _projectOwner,
                projectUri: "testProject",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            })
        );

        // Deploy an ERC-20 token for the test project so balances are trackable.
        vm.prank(_projectOwner);
        _controller.deployERC20For(_projectId, "TestToken", "TT", bytes32(0));

        // Deploy the malicious hook that will re-enter pay() during cashout.
        _maliciousHook = new MaliciousCashOutHook(_terminal, _projectId, _beneficiary);
        // Label it for trace readability.
        vm.label(address(_maliciousHook), "MaliciousCashOutHook");
    }

    /// @notice Pays into the project and returns the number of tokens minted.
    /// @return tokensReceived The number of project tokens minted to this contract.
    function _fundProject() private returns (uint256 tokensReceived) {
        // Give this test contract ETH to pay with.
        vm.deal(address(this), PAY_AMOUNT);

        // Pay into the project, receiving tokens at the configured weight.
        tokensReceived = _terminal.pay{value: PAY_AMOUNT}({
            projectId: _projectId,
            amount: PAY_AMOUNT,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "initial funding",
            metadata: ""
        });
    }

    /// @notice Mocks the data hook to return a cashout specification pointing to the malicious hook.
    /// @param cashOutCount The number of tokens being cashed out (passed through to the data hook).
    /// @param totalSupply The total supply for the bonding curve (passed through to the data hook).
    function _mockDataHookWithMaliciousSpec(uint256 cashOutCount, uint256 totalSupply) private {
        // Get the current ruleset for the data hook mock.
        (JBRuleset memory ruleset,) = _controller.currentRulesetOf(_projectId);

        // Build the cashout hook specification pointing to our malicious hook.
        JBCashOutHookSpecification[] memory specifications = new JBCashOutHookSpecification[](1);
        specifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(_maliciousHook)),
            noop: false,
            amount: REENTRANT_PAY_AMOUNT, // Hook receives 1 ETH to re-enter with.
            metadata: ""
        });

        // Mock the data hook's beforeCashOutRecordedWith to return our malicious hook specification.
        vm.mockCall(
            DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(
                ruleset.cashOutTaxRate(), // Use the ruleset's 50% cash out tax rate.
                cashOutCount, // Number of tokens being cashed out.
                totalSupply, // Total supply for the bonding curve.
                totalSupply, // Tax total supply (same as totalSupply for single-chain).
                specifications // Our malicious hook specification.
            )
        );
    }

    /// @notice Computes the expected reclaim from the bonding curve for half-supply cashout.
    /// @param cashOutCount The number of tokens being cashed out.
    /// @param totalSupply The total supply for the bonding curve calculation.
    /// @return expectedReclaim The expected reclaim amount after fees.
    function _computeExpectedReclaim(
        uint256 cashOutCount,
        uint256 totalSupply
    )
        private
        pure
        returns (uint256 expectedReclaim)
    {
        // Use 50% cash out tax rate (matches the ruleset configuration).
        uint256 cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE / 2;
        // Calculate the base reclaim from the bonding curve: surplus * count / supply.
        uint256 base = mulDiv(PAY_AMOUNT, cashOutCount, totalSupply);
        // Apply the bonding curve formula: base * [(MAX - tax) + tax * (count/supply)] / MAX.
        uint256 grossReclaim = mulDiv(
            base,
            (JBConstants.MAX_CASH_OUT_TAX_RATE - cashOutTaxRate) + mulDiv(cashOutCount, cashOutTaxRate, totalSupply),
            JBConstants.MAX_CASH_OUT_TAX_RATE
        );
        // Subtract the 2.5% fee from the gross reclaim.
        uint256 fee = JBFees.feeAmountFrom({amountBeforeFee: grossReclaim, feePercent: 25});
        // Return the net reclaim after fee deduction.
        expectedReclaim = grossReclaim - fee;
    }

    /// @notice Tests that a cashout hook re-entering pay() does not corrupt accounting.
    /// Verifies:
    ///   1. The re-entrant pay() executes and mints tokens legitimately.
    ///   2. Terminal balance reflects both the original cashout reduction and the re-entrant pay addition.
    ///   3. The fee on the original cashout is computed from the pre-re-entry reclaim, not inflated.
    ///   4. Total token supply is consistent with burns and mints.
    function test_cashOutHookReentersPay_accountingRemainsConsistent() external {
        // --- Step 1: Fund the project by paying into it. ---

        // Fund the project and receive tokens.
        uint256 tokensReceived = _fundProject();

        // Calculate expected tokens: PAY_AMOUNT * WEIGHT (UD60x18 multiplication).
        uint256 expectedTokens = UD60x18unwrap(UD60x18mul(UD60x18wrap(PAY_AMOUNT), UD60x18wrap(WEIGHT)));
        // Verify the payer received the expected number of tokens.
        assertEq(tokensReceived, expectedTokens, "initial pay should mint expected tokens");

        // The terminal should hold exactly PAY_AMOUNT.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN),
            PAY_AMOUNT,
            "terminal balance should equal pay amount"
        );

        // --- Step 2: Prepare and execute the cashout with the malicious hook. ---

        // Cash out half the tokens to leave some supply for the bonding curve calculation.
        uint256 cashOutCount = expectedTokens / 2;

        // Mock the data hook to return a specification that points to the malicious hook.
        _mockDataHookWithMaliciousSpec(cashOutCount, expectedTokens);

        // Snapshot the fee project's terminal balance before cashout.
        uint256 feeProjectBalanceBefore = jbTerminalStore().balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);

        // Cash out tokens; the hook will re-enter terminal.pay() with 1 ETH.
        uint256 reclaimAmount = _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0)
        });

        // --- Step 3: Assert the re-entrant pay executed and minted correctly. ---

        // The malicious hook should have executed its re-entrant pay.
        assertTrue(_maliciousHook.reentrantPayExecuted(), "re-entrant pay should have executed");

        // The re-entrant pay should have minted tokens for the beneficiary.
        uint256 reentrantTokensMinted = _maliciousHook.reentrantTokensMinted();
        assertGt(reentrantTokensMinted, 0, "re-entrant pay should mint tokens");

        // The hook receives REENTRANT_PAY_AMOUNT minus the 2.5% fee deducted by the terminal.
        uint256 hookFee = JBFees.feeAmountFrom({amountBeforeFee: REENTRANT_PAY_AMOUNT, feePercent: 25});
        // Calculate the net ETH the hook actually received after the fee deduction.
        uint256 netHookAmount = REENTRANT_PAY_AMOUNT - hookFee;
        // Calculate expected tokens: netHookAmount * WEIGHT (UD60x18 multiplication).
        uint256 expectedReentrantTokens = UD60x18unwrap(UD60x18mul(UD60x18wrap(netHookAmount), UD60x18wrap(WEIGHT)));
        // Verify the re-entrant pay minted the correct number of tokens.
        assertEq(reentrantTokensMinted, expectedReentrantTokens, "re-entrant pay minted correct token count");

        // --- Step 4: Verify terminal balance covers all recorded project balances (no phantoms). ---

        // Read the project's recorded balance after cashout.
        uint256 projectBalance = jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);
        // Read the fee project's recorded balance after cashout.
        uint256 feeProjectBalanceAfter = jbTerminalStore().balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);

        // The terminal balance must be positive (no underflow/phantom balance).
        assertGt(projectBalance, 0, "terminal balance should remain positive");

        // The terminal's actual ETH balance should cover all recorded balances.
        assertGe(
            address(_terminal).balance,
            projectBalance + feeProjectBalanceAfter,
            "terminal ETH balance must cover all recorded project balances"
        );

        // --- Step 5: Verify token supply consistency. ---

        // Total supply should equal: initial - burned + re-entrant minted.
        uint256 expectedFinalSupply = expectedTokens - cashOutCount + reentrantTokensMinted;
        // Read the actual total supply from the tokens contract.
        uint256 actualTotalSupply = _tokens.totalSupplyOf(_projectId);
        // Verify they match exactly.
        assertEq(actualTotalSupply, expectedFinalSupply, "token supply must reflect burn and re-entrant mint");

        // --- Step 6: Verify fees were collected and reclaim matches bonding curve. ---

        // Fees should have been collected on the cashout (since cashOutTaxRate > 0).
        assertGt(feeProjectBalanceAfter, feeProjectBalanceBefore, "fee project should receive fees from the cashout");

        // Compute the expected reclaim from the bonding curve formula.
        uint256 expectedReclaim = _computeExpectedReclaim(cashOutCount, expectedTokens);
        // The actual reclaim should match exactly, proving re-entry did not inflate it.
        assertEq(reclaimAmount, expectedReclaim, "reclaim amount matches bonding curve expectation (not inflated)");
    }

    /// @notice Tests that re-entrant pay tokens cannot be double-spent via a second cashout.
    /// After the re-entrant pay mints tokens for the beneficiary, those tokens should only
    /// be redeemable against the surplus that includes the re-entrant payment, not the original.
    function test_cashOutHookReentersPay_noDoubleSpend() external {
        // --- Fund the project. ---

        // Fund the project and receive tokens.
        uint256 tokensReceived = _fundProject();

        // Cash out half the tokens through the re-entrant hook.
        uint256 cashOutCount = tokensReceived / 2;

        // Mock the data hook to return a specification that points to the malicious hook.
        _mockDataHookWithMaliciousSpec(cashOutCount, tokensReceived);

        // Execute the cashout with re-entry.
        _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0)
        });

        // --- Now try to cash out the re-entrant tokens. ---

        // The beneficiary received tokens from the re-entrant pay.
        uint256 beneficiaryTokens = _tokens.totalBalanceOf(_beneficiary, _projectId);
        // Verify the beneficiary actually got tokens.
        assertGt(beneficiaryTokens, 0, "beneficiary should have tokens from re-entrant pay");

        // Record terminal balance before the second cashout.
        uint256 terminalBalanceBefore =
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);

        // For the second cashout, mock the data hook to return no hook specifications (simple cashout).
        _mockDataHookSimple(beneficiaryTokens);

        // Cash out the beneficiary's re-entrant tokens.
        vm.prank(_beneficiary);
        uint256 secondReclaim = _terminal.cashOutTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            cashOutCount: beneficiaryTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        // Record terminal balance after the second cashout.
        uint256 terminalBalanceAfter =
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN);

        // The terminal balance should have decreased by the second reclaim (plus fees).
        assertLt(terminalBalanceAfter, terminalBalanceBefore, "terminal balance should decrease after second cashout");

        // The second reclaim should be <= the re-entrant pay amount (bonding curve + fees reduce it).
        assertLe(secondReclaim, REENTRANT_PAY_AMOUNT, "second cashout reclaim bounded by re-entrant pay amount");

        // The terminal's actual ETH must still cover all recorded balances.
        uint256 feeProjectBalance = jbTerminalStore().balanceOf(address(_terminal), 1, JBConstants.NATIVE_TOKEN);
        // Verify no phantom balances exist after both cashouts.
        assertGe(
            address(_terminal).balance,
            terminalBalanceAfter + feeProjectBalance,
            "terminal ETH must cover all recorded balances after double cashout"
        );
    }

    /// @notice Mocks the data hook for a simple cashout (no hook specifications).
    /// @param cashOutCount The number of tokens being cashed out.
    function _mockDataHookSimple(uint256 cashOutCount) private {
        // Get the current ruleset for the data hook mock.
        (JBRuleset memory ruleset,) = _controller.currentRulesetOf(_projectId);

        // Read the current total supply for the bonding curve calculation.
        uint256 totalSupply = _tokens.totalSupplyOf(_projectId);

        // Mock the data hook to return no hook specifications (simple cashout).
        vm.mockCall(
            DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(
                ruleset.cashOutTaxRate(), // Pass through the ruleset's tax rate.
                cashOutCount, // Number of tokens being cashed out.
                totalSupply, // Current total supply.
                totalSupply, // Tax total supply (same as totalSupply for single-chain).
                new JBCashOutHookSpecification[](0) // No hooks for this cashout.
            )
        );
    }

    /// @notice Allows this test contract to receive ETH (for cashout reclaim).
    receive() external payable {}

    /// @notice Fallback to receive ETH.
    fallback() external payable {}
}
