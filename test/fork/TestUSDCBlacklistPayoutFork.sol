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

interface IUSDC {
    function blacklister() external view returns (address);
    function blacklist(address) external;
    function isBlacklisted(address) external view returns (bool);
}

/// @notice Exercises USDC's runtime blacklist against the terminal's payment path. Circle can blacklist any address
/// at any moment; the contract must fail loudly (not silently lock funds) when a blacklisted payer or beneficiary
/// is on either side of a `pay` call.
contract TestUSDCBlacklistPayoutFork is TestBaseWorkflow {
    uint256 internal constant _FORK_BLOCK = 21_700_000;
    IERC20 internal constant _USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant _USDC_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;

    IJBController internal _controller;
    IJBMultiTerminal internal _terminal;
    address internal _projectOwner;
    address internal _payer = makeAddr("usdcPayer");
    address internal _beneficiary = makeAddr("usdcBeneficiary");
    uint256 internal _projectId;

    function setUp() public override {
        vm.createSelectFork("ethereum", _FORK_BLOCK);
        super.setUp();
        _controller = jbController();
        _terminal = jbMultiTerminal();
        _projectOwner = multisig();
        _launchUSDCProject();
    }

    function _launchUSDCProject() internal {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = 1000 * 10 ** 18;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(_USDC))),
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
            JBAccountingContext({token: address(_USDC), decimals: 6, currency: uint32(uint160(address(_USDC)))});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] = JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: contexts});

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "ipfs://usdc-blacklist",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    function _blacklist(address account) internal {
        address blacklister = IUSDC(address(_USDC)).blacklister();
        vm.prank(blacklister);
        IUSDC(address(_USDC)).blacklist(account);
        assertTrue(IUSDC(address(_USDC)).isBlacklisted(account), "blacklist applied");
    }

    /// @notice Happy-path sanity: a non-blacklisted payer can pay USDC into the project.
    function testFork_pay_nonBlacklistedPayer_succeeds() public {
        uint256 amount = 100 * 10 ** 6;
        vm.prank(_USDC_WHALE);
        SafeERC20.safeTransfer(_USDC, _payer, amount);
        vm.prank(_payer);
        SafeERC20.forceApprove(_USDC, address(_terminal), amount);
        vm.prank(_payer);
        uint256 minted = _terminal.pay(_projectId, address(_USDC), amount, _beneficiary, 0, "", "");
        assertGt(minted, 0);
    }

    /// @notice A payer who is blacklisted between approval and pay -> USDC's transferFrom reverts. The terminal
    /// surfaces that revert cleanly (no silent loss), and the project state is unchanged.
    function testFork_pay_blacklistedPayer_revertsCleanly() public {
        uint256 amount = 100 * 10 ** 6;
        vm.prank(_USDC_WHALE);
        SafeERC20.safeTransfer(_USDC, _payer, amount);
        vm.prank(_payer);
        SafeERC20.forceApprove(_USDC, address(_terminal), amount);

        // Blacklist the payer after they've approved but before the pay call.
        _blacklist(_payer);

        uint256 terminalBalanceBefore = _USDC.balanceOf(address(_terminal));

        vm.prank(_payer);
        vm.expectRevert(); // USDC reverts on Blacklistable._notBlacklisted check
        _terminal.pay(_projectId, address(_USDC), amount, _beneficiary, 0, "", "");

        assertEq(
            _USDC.balanceOf(address(_terminal)), terminalBalanceBefore, "no USDC moved when the payer is blacklisted"
        );
    }
}
