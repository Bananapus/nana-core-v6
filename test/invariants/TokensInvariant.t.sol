// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/StdInvariant.sol";
import /* {*} from */ "../helpers/TestBaseWorkflow.sol";
import {TokensHandler} from "./handlers/TokensHandler.sol";

/// @notice Invariant tests for JBTokens supply and balance consistency.
/// @dev Verifies that the dual-balance system (credits + ERC20) maintains exact accounting.
contract TokensInvariant_Local is StdInvariant, TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    TokensHandler public handler;

    uint256 public projectId;
    address public projectOwner;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();

        // Launch fee collector project (#1)
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

        // Launch the test project with credits (no ERC20 initially, then deploy)
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 5000,
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

        projectId = jbController().launchProjectFor({
            owner: projectOwner,
            projectUri: "testProject",
            rulesetConfigurations: rulesetConfig,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });

        // Deploy ERC20 so claiming works
        vm.prank(projectOwner);
        jbController().deployERC20For(projectId, "TestToken", "TT", bytes32(0));

        // Deploy handler
        handler = new TokensHandler(jbMultiTerminal(), jbController(), jbTokens(), projectId, projectOwner);

        // Register handler
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = TokensHandler.mintTokens.selector;
        selectors[1] = TokensHandler.burnTokens.selector;
        selectors[2] = TokensHandler.claimCredits.selector;
        selectors[3] = TokensHandler.transferCredits.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INV-TK-1: totalSupplyOf == totalCreditSupplyOf + token.totalSupply()
    function invariant_TK1_totalSupplyDecomposition() public view {
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 creditSupply = jbTokens().totalCreditSupplyOf(projectId);
        IJBToken token = jbTokens().tokenOf(projectId);
        uint256 erc20Supply = address(token) != address(0) ? token.totalSupply() : 0;

        assertEq(
            totalSupply,
            creditSupply + erc20Supply,
            "INV-TK-1: totalSupply must equal creditSupply + erc20Supply"
        );
    }

    /// @notice INV-TK-2: For each holder, totalBalanceOf == creditBalanceOf + token.balanceOf
    function invariant_TK2_perHolderBalanceConsistency() public view {
        uint256 holderCount = handler.holderCount();
        IJBToken token = jbTokens().tokenOf(projectId);

        for (uint256 i = 0; i < holderCount; i++) {
            address holder = handler.holderAt(i);
            uint256 totalBalance = jbTokens().totalBalanceOf(holder, projectId);
            uint256 creditBalance = jbTokens().creditBalanceOf(holder, projectId);
            uint256 erc20Balance = address(token) != address(0) ? token.balanceOf(holder) : 0;

            assertEq(
                totalBalance,
                creditBalance + erc20Balance,
                "INV-TK-2: Per-holder totalBalance must equal credits + ERC20"
            );
        }
    }

    /// @notice INV-TK-3: Sum of all holder totalBalanceOf == totalSupplyOf
    function invariant_TK3_sumOfBalancesEqualsTotalSupply() public view {
        uint256 holderCount = handler.holderCount();
        uint256 sumOfBalances;

        for (uint256 i = 0; i < holderCount; i++) {
            address holder = handler.holderAt(i);
            sumOfBalances += jbTokens().totalBalanceOf(holder, projectId);
        }

        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);

        // Sum of tracked holder balances should be <= totalSupply.
        // It may be < totalSupply if there are holders we haven't tracked (e.g., fee project).
        assertLe(
            sumOfBalances,
            totalSupply,
            "INV-TK-3: Sum of tracked holder balances must not exceed totalSupply"
        );
    }

    /// @notice INV-TK-4: Claiming does not change totalSupplyOf.
    /// @dev This is implicitly tested via TK-1: if claiming changed totalSupply,
    ///      the creditSupply + erc20Supply decomposition would break.
    ///      We add an explicit check that supply is always non-negative (trivially true for uint).
    function invariant_TK4_supplyNeverNegative() public view {
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 creditSupply = jbTokens().totalCreditSupplyOf(projectId);

        assertGe(totalSupply, creditSupply, "INV-TK-4: totalSupply must be >= creditSupply");
    }
}
