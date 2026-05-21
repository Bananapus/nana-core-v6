// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";

contract ReentrantERC20 is ERC20 {
    IJBMultiTerminal public terminal;
    uint256 public reentryProjectId;
    uint256 public reentryAmount;
    bool public reentryEnabled;

    bool private _reentering;

    constructor() ERC20("Reentrant ERC20", "R20") {}

    function configureReentry(IJBMultiTerminal terminal_, uint256 projectId_, uint256 amount_, bool enabled_) external {
        terminal = terminal_;
        reentryProjectId = projectId_;
        reentryAmount = amount_;
        reentryEnabled = enabled_;

        _approve(address(this), address(terminal_), type(uint256).max);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        if (!reentryEnabled || _reentering || to != address(terminal) || from == address(0) || amount == 0) return;

        _reentering = true;

        terminal.addToBalanceOf({
            projectId: reentryProjectId,
            token: address(this),
            amount: reentryAmount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        _reentering = false;
    }
}

contract ReentrantERC20IntakeGuard is TestBaseWorkflow {
    JBMultiTerminal private _terminal;
    ReentrantERC20 private _token;

    uint256 private _attackerProjectId;
    uint256 private _victimProjectId;

    address private _attacker = makeAddr("attacker");
    address private _victimFunder = makeAddr("victimFunder");

    function setUp() public override {
        super.setUp();

        _terminal = jbMultiTerminal();
        _token = new ReentrantERC20();

        _victimProjectId = _launchTokenProject();
        _attackerProjectId = _launchTokenProject();
    }

    function test_reentrantTokenAddToBalanceRevertsBeforeAccounting() public {
        uint256 victimAmount = 100 ether;
        uint256 outerAmount = 200 ether;
        uint256 reentryAmount = 100 ether;

        _token.mint(_victimFunder, victimAmount);
        vm.prank(_victimFunder);
        _token.approve(address(_terminal), victimAmount);

        vm.prank(_victimFunder);
        _terminal.addToBalanceOf({
            projectId: _victimProjectId,
            token: address(_token),
            amount: victimAmount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        _token.mint(_attacker, outerAmount);
        _token.mint(address(_token), reentryAmount);
        _token.configureReentry({
            terminal_: _terminal, projectId_: _attackerProjectId, amount_: reentryAmount, enabled_: true
        });

        vm.prank(_attacker);
        _token.approve(address(_terminal), outerAmount);

        vm.prank(_attacker);
        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_ReentrantTokenTransfer.selector, address(_token))
        );
        _terminal.addToBalanceOf({
            projectId: _attackerProjectId,
            token: address(_token),
            amount: outerAmount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: new bytes(0)
        });

        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _victimProjectId, address(_token)),
            victimAmount,
            "victim accounting changed"
        );
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _attackerProjectId, address(_token)),
            0,
            "attacker accounting changed"
        );
        assertEq(_token.balanceOf(address(_terminal)), victimAmount, "terminal token pool changed");
    }

    function test_reentrantTokenPayRevertsBeforeMintingOrAccounting() public {
        uint256 outerAmount = 200 ether;
        uint256 reentryAmount = 100 ether;

        _token.mint(_attacker, outerAmount);
        _token.mint(address(_token), reentryAmount);
        _token.configureReentry({
            terminal_: _terminal, projectId_: _attackerProjectId, amount_: reentryAmount, enabled_: true
        });

        vm.prank(_attacker);
        _token.approve(address(_terminal), outerAmount);

        vm.prank(_attacker);
        vm.expectRevert(
            abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_ReentrantTokenTransfer.selector, address(_token))
        );
        _terminal.pay({
            projectId: _attackerProjectId,
            token: address(_token),
            amount: outerAmount,
            beneficiary: _attacker,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _attackerProjectId, address(_token)),
            0,
            "attacker accounting changed"
        );
        assertEq(jbTokens().totalBalanceOf(_attacker, _attackerProjectId), 0, "attacker received project tokens");
        assertEq(_token.balanceOf(address(_terminal)), 0, "terminal token pool changed");
    }

    function _launchTokenProject() internal returns (uint256 projectId) {
        uint32 currency = 1;

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: currency,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = 1000e18;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = metadata;
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({token: address(_token), decimals: 18, currency: currency});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: accountingContextsToAccept});

        projectId = jbController()
            .launchProjectFor({
            owner: multisig(),
            projectUri: "reentrant-erc20-intake-guard",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }
}
