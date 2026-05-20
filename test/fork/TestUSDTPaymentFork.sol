// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJBController} from "../../src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

/// @notice Exercises `JBMultiTerminal.pay` end-to-end with the canonical mainnet USDT contract. USDT is famously
/// non-spec-compliant: its `transfer` and `transferFrom` return void, so the terminal's `_acceptFundsFor` path must
/// use `SafeERC20` (otherwise calls would revert in Solidity's return-data decoder). This is the first fork test in
/// nana-core that drives an actual non-bool-return ERC-20 through the payment pipeline.
/// @dev Uses an existing USDT whale on the pinned block to source funds via `vm.prank`. No real signature needed.
contract TestUSDTPaymentFork is TestBaseWorkflow {
    uint256 internal constant _FORK_BLOCK = 21_700_000;
    IERC20 internal constant _USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    // Binance hot wallet 14 at this block holds plenty of USDT; impersonate to source funds.
    address internal constant _USDT_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;

    IJBController internal _controller;
    IJBMultiTerminal internal _terminal;
    address internal _projectOwner;
    address internal _beneficiary;
    address internal _payer = makeAddr("usdtPayer");
    uint256 internal _projectId;

    function setUp() public override {
        vm.createSelectFork("ethereum", _FORK_BLOCK);
        super.setUp();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _projectOwner = multisig();
        _beneficiary = beneficiary();

        _launchUSDTProject();
    }

    function _launchUSDTProject() internal {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = 1000 * 10 ** 18;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            // USDT has 6 decimals; quote project tokens against USDT itself.
            baseCurrency: uint32(uint160(address(_USDT))),
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
            JBAccountingContext({token: address(_USDT), decimals: 6, currency: uint32(uint160(address(_USDT)))});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: contexts});

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://usdt-fork",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    /// @notice USDT's non-bool `transferFrom` is handled correctly by `_acceptFundsFor`'s SafeERC20 path. Without
    /// SafeERC20 (or with naive `transferFrom` whose return value is decoded as a bool), this would revert.
    function testFork_pay_usdt_acceptsNonBoolTransfer() public {
        uint256 amount = 1000 * 10 ** 6; // 1000 USDT (6 decimals)

        // Fund the payer from the whale and grant the terminal an allowance. SafeERC20 handles USDT's void return.
        vm.prank(_USDT_WHALE);
        SafeERC20.safeTransfer(_USDT, _payer, amount);
        vm.prank(_payer);
        SafeERC20.forceApprove(_USDT, address(_terminal), amount);

        uint256 payerBalanceBefore = _USDT.balanceOf(_payer);
        uint256 terminalBalanceBefore = _USDT.balanceOf(address(_terminal));

        vm.prank(_payer);
        uint256 beneficiaryTokenCount = _terminal.pay({
            projectId: _projectId,
            token: address(_USDT),
            amount: amount,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertGt(beneficiaryTokenCount, 0, "USDT payment must mint project tokens");
        assertEq(_USDT.balanceOf(_payer), payerBalanceBefore - amount, "payer USDT decremented");
        assertEq(_USDT.balanceOf(address(_terminal)), terminalBalanceBefore + amount, "terminal received USDT");
        assertEq(jbTokens().totalBalanceOf(_beneficiary, _projectId), beneficiaryTokenCount, "beneficiary credited");
    }

    /// @notice Sanity: two sequential pays in separate transactions both mint. Forge resets transient storage
    /// between top-level test calls, so this only proves the happy-path pay flow holds twice in succession — NOT
    /// that the `_acceptingToken` guard clears correctly mid-tx. A real intra-tx reentrancy test would need a
    /// callback-capable token at the payer position.
    function testFork_pay_usdt_twoTxSanity() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(_USDT_WHALE);
        SafeERC20.safeTransfer(_USDT, _payer, amount * 2);

        vm.prank(_payer);
        SafeERC20.forceApprove(_USDT, address(_terminal), amount * 2);
        vm.prank(_payer);
        uint256 first = _terminal.pay(_projectId, address(_USDT), amount, _beneficiary, 0, "", "");
        vm.prank(_payer);
        uint256 second = _terminal.pay(_projectId, address(_USDT), amount, _beneficiary, 0, "", "");

        assertGt(first, 0, "first pay minted");
        assertGt(second, 0, "second pay minted");
    }
}
