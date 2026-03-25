// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

// Import the shared base test workflow that deploys all core Juicebox contracts.
import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
// Import the void-returning USDT mock token.
import {MockUSDT} from "../mock/MockUSDT.sol";
// Import the approval hook interface needed for ruleset configuration.
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
// Import the split hook interface needed for split configuration.
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
// Import constants used for fee maximums, native token address, and split percentages.
import {JBConstants} from "../../src/libraries/JBConstants.sol";
// Import the metadata resolver to pack/unpack ruleset metadata bits.
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
// Import the ruleset struct used to read current ruleset state.
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
// Import currency amount struct for payout/surplus limit configuration.
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
// Import fund access limit group struct for payout limit configuration.
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
// Import ruleset config struct for project launch configuration.
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
// Import ruleset metadata struct for per-ruleset settings.
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
// Import split struct for defining payout split recipients.
import {JBSplit} from "../../src/structs/JBSplit.sol";
// Import split group struct for grouping splits by token.
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
// Import terminal config struct for linking terminals to accounting contexts.
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
// Import accounting context struct for token acceptance configuration.
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";

/// @notice Tests that USDT-style void-returning ERC-20 tokens work with JBMultiTerminal.
/// @dev USDT's transfer/transferFrom/approve return void instead of bool. The terminal
/// uses SafeERC20 which handles void returns, and Permit2 which uses low-level calls.
/// These tests prove the full pay -> payout -> cashOut lifecycle works with such tokens.
contract USDTVoidReturnCompat is TestBaseWorkflow {
    // Use the metadata resolver library on ruleset structs.
    using JBRulesetMetadataResolver for JBRuleset;

    // The USDT mock token instance used across all tests.
    MockUSDT public usdt;
    // The project owner address (multisig from the base workflow).
    address public projectOwner;
    // The address that receives split payouts in test scenarios.
    address public splitBeneficiary;

    function setUp() public override {
        // Deploy all core Juicebox contracts via the base workflow.
        super.setUp();
        // Use the multisig as the project owner for test projects.
        projectOwner = multisig();
        // Create a dedicated address for receiving split payouts.
        splitBeneficiary = address(0xBEEF);
        // Deploy the void-returning USDT mock.
        usdt = new MockUSDT();
        // Label the USDT contract for clearer trace output.
        vm.label(address(usdt), "MockUSDT");
        // Launch the fee-collector project (project #1) required by the protocol.
        _launchFeeProject();
    }

    // =========================================================================
    //  Fee project helper — project #1 collects protocol fees
    // =========================================================================

    /// @notice Deploys project #1 which receives protocol fees.
    function _launchFeeProject() internal {
        // Create a single-element array for the fee project's ruleset configuration.
        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        // The fee project starts immediately (no delay).
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        // Duration of 0 means the ruleset never expires automatically.
        feeRulesetConfig[0].duration = 0;
        // Set the weight to 1000 tokens per unit paid, scaled to 18 decimals.
        feeRulesetConfig[0].weight = 1000e18;
        // No weight decay between cycles.
        feeRulesetConfig[0].weightCutPercent = 0;
        // No approval hook required for this ruleset.
        feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        // Configure metadata: minimal settings, accept accounting contexts.
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
        // No splits for the fee project.
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        // No fund access limits for the fee project.
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Configure the terminal to accept native ETH tokens.
        JBTerminalConfig[] memory termConfigs = new JBTerminalConfig[](1);
        // Create accounting context for native token with 18 decimals.
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        // Link the terminal to the accounting context.
        termConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        // Launch project #1 as the fee collector.
        jbController()
            .launchProjectFor({
                owner: address(420),
                projectUri: "feeCollector",
                rulesetConfigurations: feeRulesetConfig,
                terminalConfigurations: termConfigs,
                memo: ""
            });
    }

    // =========================================================================
    //  Test 1: Pay into a project with void-returning MockUSDT
    // =========================================================================

    /// @notice Verifies that paying with a void-returning token succeeds.
    /// @dev The terminal uses SafeERC20 which correctly handles tokens that return no data.
    function test_usdt_void_return_pay() public {
        // Launch a project that accepts USDT.
        uint256 pid = _launchUSDTProject();
        // Use a dedicated payer address.
        address payer = address(0xBA1E);
        // Mint 1000 USDT (6 decimals) to the payer.
        uint256 payAmount = 1000e6;
        usdt.mint(payer, payAmount);

        // Approve the terminal to spend the payer's USDT via Permit2.
        vm.prank(payer);
        // Approve Permit2 contract to pull USDT from the payer.
        usdt.approve(address(permit2()), payAmount);

        // Grant Permit2 allowance for the terminal to pull tokens.
        vm.prank(payer);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2().approve(address(usdt), address(jbMultiTerminal()), uint160(payAmount), type(uint48).max);

        // Execute the payment — this is the critical call that must handle void returns.
        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal()
            .pay({
                projectId: pid,
                token: address(usdt),
                amount: payAmount,
                beneficiary: payer,
                minReturnedTokens: 0,
                memo: "",
                metadata: new bytes(0)
            });

        // Verify the payer received project tokens in exchange for the payment.
        assertTrue(tokensReceived > 0, "Payer should receive project tokens from USDT payment");

        // Verify the terminal recorded the balance correctly.
        uint256 recordedBalance = jbTerminalStore().balanceOf(address(jbMultiTerminal()), pid, address(usdt));
        // The recorded balance should equal the full payment amount (no transfer fee).
        assertEq(recordedBalance, payAmount, "Terminal should record the full USDT pay amount");
    }

    // =========================================================================
    //  Test 2: Execute a split payout that sends MockUSDT to a beneficiary
    // =========================================================================

    /// @notice Verifies that split payouts work with void-returning tokens.
    /// @dev Split payouts go through executePayout -> _transferFrom -> SafeERC20.safeTransfer
    /// which handles void returns by checking returndata length.
    function test_usdt_void_return_split_payout() public {
        // Launch a project with a split that pays out to splitBeneficiary.
        uint256 pid = _launchUSDTProjectWithSplit();
        // Use a dedicated payer address.
        address payer = address(0xBA1E);
        // Mint 1000 USDT to the payer.
        uint256 payAmount = 1000e6;
        usdt.mint(payer, payAmount);

        // Approve Permit2 to pull USDT from payer.
        vm.prank(payer);
        usdt.approve(address(permit2()), payAmount);

        // Grant Permit2 allowance for the terminal.
        vm.prank(payer);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2().approve(address(usdt), address(jbMultiTerminal()), uint160(payAmount), type(uint48).max);

        // Pay into the project to fund it.
        vm.prank(payer);
        jbMultiTerminal()
            .pay({
                projectId: pid,
                token: address(usdt),
                amount: payAmount,
                beneficiary: payer,
                minReturnedTokens: 0,
                memo: "",
                metadata: new bytes(0)
            });

        // Record the split beneficiary's USDT balance before the payout.
        uint256 beneficiaryBefore = usdt.balanceOf(splitBeneficiary);

        // Execute the payout — sends USDT through the split to the beneficiary.
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: address(usdt),
                amount: 500e6,
                currency: uint32(uint160(address(usdt))),
                minTokensPaidOut: 0
            });

        // Calculate how much USDT the beneficiary actually received.
        uint256 beneficiaryAfter = usdt.balanceOf(splitBeneficiary);
        uint256 received = beneficiaryAfter - beneficiaryBefore;

        // The beneficiary should have received tokens (less fees).
        assertTrue(received > 0, "Split beneficiary should receive USDT from payout");
    }

    // =========================================================================
    //  Test 3: Cash out project tokens for MockUSDT reclaim
    // =========================================================================

    /// @notice Verifies that cashing out tokens reclaims void-returning USDT.
    /// @dev The cashOut flow uses _transferFrom -> SafeERC20.safeTransfer on the outbound side.
    function test_usdt_void_return_cashOut() public {
        // Launch a project that accepts USDT with 0% cashout tax for full reclaim.
        uint256 pid = _launchUSDTProject();
        // Use a dedicated payer address.
        address payer = address(0xBA1E);
        // Mint 1000 USDT to the payer.
        uint256 payAmount = 1000e6;
        usdt.mint(payer, payAmount);

        // Approve Permit2 to pull USDT from payer.
        vm.prank(payer);
        usdt.approve(address(permit2()), payAmount);

        // Grant Permit2 allowance for the terminal.
        vm.prank(payer);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2().approve(address(usdt), address(jbMultiTerminal()), uint160(payAmount), type(uint48).max);

        // Pay into the project to receive project tokens.
        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal()
            .pay({
                projectId: pid,
                token: address(usdt),
                amount: payAmount,
                beneficiary: payer,
                minReturnedTokens: 0,
                memo: "",
                metadata: new bytes(0)
            });

        // Record the payer's USDT balance before cashing out.
        uint256 payerBefore = usdt.balanceOf(payer);

        // Cash out all project tokens to reclaim USDT.
        vm.prank(payer);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: pid,
                cashOutCount: tokensReceived,
                tokenToReclaim: address(usdt),
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: new bytes(0)
            });

        // Calculate how much USDT the payer actually received back.
        uint256 payerAfter = usdt.balanceOf(payer);
        uint256 actualReclaimed = payerAfter - payerBefore;

        // The reclaim amount should be positive (some goes to fees at 0% tax rate).
        assertTrue(reclaimAmount > 0, "CashOut should reclaim USDT tokens");
        // The payer should have received the reclaimed USDT.
        assertEq(actualReclaimed, reclaimAmount, "Payer should receive the full reclaim amount");
    }

    // =========================================================================
    //  Test 4: Full lifecycle — pay, payout, cashOut in sequence
    // =========================================================================

    /// @notice End-to-end test: pay with USDT, distribute payout, then cash out remainder.
    /// @dev Proves the entire lifecycle works without reverting for void-returning tokens.
    function test_usdt_void_return_full_lifecycle() public {
        // Launch a project with splits and payout limits.
        uint256 pid = _launchUSDTProjectWithSplit();
        // Use a dedicated payer address.
        address payer = address(0xBA1E);
        // Mint 2000 USDT to the payer.
        uint256 payAmount = 2000e6;
        usdt.mint(payer, payAmount);

        // Approve Permit2 to pull USDT from payer.
        vm.prank(payer);
        usdt.approve(address(permit2()), payAmount);

        // Grant Permit2 allowance for the terminal.
        vm.prank(payer);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2().approve(address(usdt), address(jbMultiTerminal()), uint160(payAmount), type(uint48).max);

        // Step 1: Pay into the project.
        vm.prank(payer);
        uint256 tokensReceived = jbMultiTerminal()
            .pay({
                projectId: pid,
                token: address(usdt),
                amount: payAmount,
                beneficiary: payer,
                minReturnedTokens: 0,
                memo: "",
                metadata: new bytes(0)
            });
        // Verify payment succeeded by checking tokens were minted.
        assertTrue(tokensReceived > 0, "Step 1: Payer should receive project tokens");

        // Step 2: Distribute payouts through splits.
        vm.prank(projectOwner);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: address(usdt),
                amount: 500e6,
                currency: uint32(uint160(address(usdt))),
                minTokensPaidOut: 0
            });
        // Verify the split beneficiary received USDT.
        assertTrue(usdt.balanceOf(splitBeneficiary) > 0, "Step 2: Split beneficiary should have USDT");

        // Step 3: Cash out remaining project tokens.
        vm.prank(payer);
        uint256 reclaimAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: pid,
                cashOutCount: tokensReceived,
                tokenToReclaim: address(usdt),
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: new bytes(0)
            });
        // Verify the payer got USDT back from cashing out.
        assertTrue(reclaimAmount > 0, "Step 3: CashOut should return USDT to payer");
    }

    // =========================================================================
    //  Internal helpers
    // =========================================================================

    /// @notice Launches a project that accepts MockUSDT with no splits and no payout limits.
    // forge-lint: disable-next-line(mixed-case-function)
    function _launchUSDTProject() internal returns (uint256) {
        // Create a single-element array for the ruleset configuration.
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        // Start immediately.
        rulesetConfig[0].mustStartAtOrAfter = 0;
        // Non-expiring ruleset.
        rulesetConfig[0].duration = 0;
        // Weight scaled to 18 decimals for token issuance calculations.
        rulesetConfig[0].weight = 1000e18;
        // No weight decay.
        rulesetConfig[0].weightCutPercent = 0;
        // No approval hook.
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        // Configure metadata: use USDT as base currency, 0% cashout tax.
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(usdt))),
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
        // No splits.
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        // No fund access limits.
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Configure the terminal to accept MockUSDT with 6 decimals.
        JBTerminalConfig[] memory termConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        // Set up the accounting context for USDT: 6 decimals, currency = token address.
        tokensToAccept[0] =
            JBAccountingContext({token: address(usdt), decimals: 6, currency: uint32(uint160(address(usdt)))});
        // Link the terminal to the USDT accounting context.
        termConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        // Launch the project and return its ID.
        return jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "usdtProject",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: termConfigs,
                memo: ""
            });
    }

    /// @notice Launches a project that accepts MockUSDT with a 100% split to splitBeneficiary.
    // forge-lint: disable-next-line(mixed-case-function)
    function _launchUSDTProjectWithSplit() internal returns (uint256) {
        // Create a single-element array for the ruleset configuration.
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        // Start immediately.
        rulesetConfig[0].mustStartAtOrAfter = 0;
        // Non-expiring ruleset.
        rulesetConfig[0].duration = 0;
        // Weight scaled to 18 decimals.
        rulesetConfig[0].weight = 1000e18;
        // No weight decay.
        rulesetConfig[0].weightCutPercent = 0;
        // No approval hook.
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        // Configure metadata: USDT base currency, 0% cashout tax, 0% reserved.
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(usdt))),
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

        // Create a split that sends 100% of payouts to splitBeneficiary.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(splitBeneficiary),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        // Group the splits under the USDT token's group ID (token address as uint256).
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(address(usdt))), splits: splits});
        // Assign the split groups to the ruleset.
        rulesetConfig[0].splitGroups = splitGroups;

        // Configure a payout limit of 500 USDT so sendPayoutsOf can distribute funds.
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: uint224(500e6), currency: uint32(uint160(address(usdt)))});
        // Create the fund access limit group linking the terminal, token, and payout limit.
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: address(usdt),
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        // Assign the fund access limit groups to the ruleset.
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;

        // Configure the terminal to accept MockUSDT with 6 decimals.
        JBTerminalConfig[] memory termConfigs = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        // USDT accounting context: 6 decimals, currency keyed to token address.
        tokensToAccept[0] =
            JBAccountingContext({token: address(usdt), decimals: 6, currency: uint32(uint160(address(usdt)))});
        // Link terminal to accounting context.
        termConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        // Launch the project with splits and payout limits, return its ID.
        return jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "usdtSplitProject",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: termConfigs,
                memo: ""
            });
    }

    // Allow the test contract to receive native ETH (required for some test helpers).
    receive() external payable {}
}
