// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBCashOutHook} from "../src/interfaces/IJBCashOutHook.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBPayHook} from "../src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../src/interfaces/IJBRulesetDataHook.sol";
import {IJBSplitHook} from "../src/interfaces/IJBSplitHook.sol";
import {IJBTokens} from "../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBAfterCashOutRecordedContext} from "../src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "../src/structs/JBAfterPayRecordedContext.sol";
import {JBCashOutHookSpecification} from "../src/structs/JBCashOutHookSpecification.sol";
import {JBCurrencyAmount} from "../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";

contract TestForwardedTokenConsumption_Local is TestBaseWorkflow {
    uint112 private constant _WEIGHT = 1000 * 10 ** 18;
    uint256 private constant _PAY_AMOUNT = 10 * 10 ** 6;
    uint256 private constant _HOOK_FORWARD_AMOUNT = 1 * 10 ** 6;
    uint256 private constant _PAYOUT_AMOUNT = 4 * 10 ** 6;
    address private constant _DATA_HOOK = address(bytes20(keccak256("datahook")));

    IJBController private _controller;
    IJBMultiTerminal private _terminal;
    IJBMultiTerminal private _terminal2;
    IJBTokens private _tokens;
    address private _projectOwner;

    uint64 private _projectId;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _terminal = jbMultiTerminal();
        _terminal2 = jbMultiTerminal2();
        _tokens = jbTokens();
        _projectOwner = multisig();

        // Launch the fee beneficiary project first so project ID 1 has a terminal and accounting context.
        _launchProject({
            terminal: _terminal,
            projectUri: "fee-project",
            metadata: _metadataWithHooks({useDataHookForPay: true, useDataHookForCashOut: true, dataHook: _DATA_HOOK}),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        _projectId = uint64(
            _launchProject({
                terminal: _terminal,
                projectUri: "hook-project",
                metadata: _metadataWithHooks({
                    useDataHookForPay: true, useDataHookForCashOut: true, dataHook: _DATA_HOOK
                }),
                splitGroups: new JBSplitGroup[](0),
                fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
            })
        );
    }

    function test_RevertIfERC20PayHookDoesNotConsumeForwardedTokens() external {
        NonConsumingPayHook hook = new NonConsumingPayHook();
        JBPayHookSpecification[] memory specifications = new JBPayHookSpecification[](1);
        specifications[0] =
            JBPayHookSpecification({hook: hook, noop: false, amount: _HOOK_FORWARD_AMOUNT, metadata: ""});

        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(_WEIGHT, specifications)
        );

        vm.prank(multisig());
        jbFeelessAddresses().setFeelessAddress(address(hook), true);

        address payer = makeAddr("payer");
        usdcToken().mint(payer, _PAY_AMOUNT);
        vm.prank(payer);
        usdcToken().approve(address(_terminal), _PAY_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_TemporaryAllowanceNotConsumed.selector,
                address(usdcToken()),
                address(hook),
                _HOOK_FORWARD_AMOUNT
            )
        );
        vm.prank(payer);
        _terminal.pay({
            projectId: _projectId,
            token: address(usdcToken()),
            amount: _PAY_AMOUNT,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    function test_RevertIfERC20CashOutHookDoesNotConsumeForwardedTokens() external {
        JBPayHookSpecification[] memory emptyPaySpecifications = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(_WEIGHT, emptyPaySpecifications)
        );

        usdcToken().mint(address(this), _PAY_AMOUNT);
        usdcToken().approve(address(_terminal), _PAY_AMOUNT);

        _terminal.pay({
            projectId: _projectId,
            token: address(usdcToken()),
            amount: _PAY_AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 cashOutCount = _tokens.totalBalanceOf(address(this), _projectId) / 2;

        NonConsumingCashOutHook hook = new NonConsumingCashOutHook();
        JBCashOutHookSpecification[] memory specifications = new JBCashOutHookSpecification[](1);
        specifications[0] =
            JBCashOutHookSpecification({hook: hook, noop: false, amount: _HOOK_FORWARD_AMOUNT, metadata: ""});

        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(0, cashOutCount, _controller.totalTokenSupplyWithReservedTokensOf(_projectId), uint256(0), specifications)
        );

        vm.prank(multisig());
        jbFeelessAddresses().setFeelessAddress(address(hook), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBMultiTerminal.JBMultiTerminal_TemporaryAllowanceNotConsumed.selector,
                address(usdcToken()),
                address(hook),
                _HOOK_FORWARD_AMOUNT
            )
        );
        _terminal.cashOutTokensOf({
            holder: address(this),
            projectId: _projectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: address(usdcToken()),
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: ""
        });
    }

    function test_SendPayoutsToMultiTerminalAddToBalanceConsumesForwardedAllowance() external {
        uint256 recipientProjectId = _launchProject({
            terminal: _terminal2,
            projectUri: "recipient-add-to-balance",
            metadata: _metadataWithHooks({
                useDataHookForPay: false, useDataHookForCashOut: false, dataHook: address(0)
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 sourceProjectId = _launchProject({
            terminal: _terminal,
            projectUri: "source-add-to-balance",
            metadata: _metadataWithHooks({
                useDataHookForPay: false, useDataHookForCashOut: false, dataHook: address(0)
            }),
            splitGroups: _splitGroupsToProject({targetProjectId: recipientProjectId, preferAddToBalance: true}),
            fundAccessLimitGroups: _usdcPayoutLimitGroups({terminal: _terminal, payoutAmount: _PAYOUT_AMOUNT})
        });

        usdcToken().mint(address(this), _PAYOUT_AMOUNT);
        usdcToken().approve(address(_terminal), _PAYOUT_AMOUNT);

        _terminal.pay({
            projectId: sourceProjectId,
            token: address(usdcToken()),
            amount: _PAYOUT_AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 fee = _PAYOUT_AMOUNT * _terminal.FEE() / JBConstants.MAX_FEE;
        uint256 expectedNetPayout = _PAYOUT_AMOUNT - fee;

        _terminal.sendPayoutsOf({
            projectId: sourceProjectId,
            amount: _PAYOUT_AMOUNT,
            currency: uint32(uint160(address(usdcToken()))),
            token: address(usdcToken()),
            minTokensPaidOut: 0
        });

        assertEq(usdcToken().allowance(address(_terminal), address(_terminal2)), 0);
        assertEq(jbTerminalStore().balanceOf(address(_terminal), sourceProjectId, address(usdcToken())), fee);
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal2), recipientProjectId, address(usdcToken())),
            expectedNetPayout
        );
        assertEq(usdcToken().balanceOf(address(_terminal2)), expectedNetPayout);
    }

    function test_SendPayoutsToMultiTerminalPayConsumesForwardedAllowance() external {
        uint256 recipientProjectId = _launchProject({
            terminal: _terminal2,
            projectUri: "recipient-pay",
            metadata: _metadataWithHooks({
                useDataHookForPay: false, useDataHookForCashOut: false, dataHook: address(0)
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        uint256 sourceProjectId = _launchProject({
            terminal: _terminal,
            projectUri: "source-pay",
            metadata: _metadataWithHooks({
                useDataHookForPay: false, useDataHookForCashOut: false, dataHook: address(0)
            }),
            splitGroups: _splitGroupsToProject({targetProjectId: recipientProjectId, preferAddToBalance: false}),
            fundAccessLimitGroups: _usdcPayoutLimitGroups({terminal: _terminal, payoutAmount: _PAYOUT_AMOUNT})
        });

        usdcToken().mint(address(this), _PAYOUT_AMOUNT);
        usdcToken().approve(address(_terminal), _PAYOUT_AMOUNT);

        _terminal.pay({
            projectId: sourceProjectId,
            token: address(usdcToken()),
            amount: _PAYOUT_AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 fee = _PAYOUT_AMOUNT * _terminal.FEE() / JBConstants.MAX_FEE;
        uint256 expectedNetPayout = _PAYOUT_AMOUNT - fee;

        _terminal.sendPayoutsOf({
            projectId: sourceProjectId,
            amount: _PAYOUT_AMOUNT,
            currency: uint32(uint160(address(usdcToken()))),
            token: address(usdcToken()),
            minTokensPaidOut: 0
        });

        assertEq(usdcToken().allowance(address(_terminal), address(_terminal2)), 0);
        assertEq(jbTerminalStore().balanceOf(address(_terminal), sourceProjectId, address(usdcToken())), fee);
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal2), recipientProjectId, address(usdcToken())),
            expectedNetPayout
        );
        assertEq(usdcToken().balanceOf(address(_terminal2)), expectedNetPayout);
    }

    function _launchProject(
        IJBMultiTerminal terminal,
        string memory projectUri,
        JBRulesetMetadata memory metadata,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        returns (uint256)
    {
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].duration = 0;
        rulesetConfigurations[0].weight = _WEIGHT;
        rulesetConfigurations[0].weightCutPercent = 0;
        rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigurations[0].metadata = metadata;
        rulesetConfigurations[0].splitGroups = splitGroups;
        rulesetConfigurations[0].fundAccessLimitGroups = fundAccessLimitGroups;

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: terminal, accountingContextsToAccept: _usdcAccountingContexts()});

        return _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: ""
        });
    }

    function _metadataWithHooks(
        bool useDataHookForPay,
        bool useDataHookForCashOut,
        address dataHook
    )
        internal
        view
        returns (JBRulesetMetadata memory)
    {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(address(usdcToken()))),
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
            useDataHookForPay: useDataHookForPay,
            useDataHookForCashOut: useDataHookForCashOut,
            dataHook: dataHook,
            metadata: 0
        });
    }

    function _splitGroupsToProject(
        uint256 targetProjectId,
        bool preferAddToBalance
    )
        internal
        view
        returns (JBSplitGroup[] memory)
    {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT);
        // forge-lint: disable-next-line(unsafe-typecast)
        splits[0].projectId = uint64(targetProjectId);
        splits[0].beneficiary = payable(address(0));
        splits[0].preferAddToBalance = preferAddToBalance;
        splits[0].lockedUntil = 0;
        splits[0].hook = IJBSplitHook(address(0));

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(address(usdcToken()))), splits: splits});

        return splitGroups;
    }

    function _usdcAccountingContexts() internal view returns (JBAccountingContext[] memory) {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: address(usdcToken()),
            decimals: usdcToken().decimals(),
            currency: uint32(uint160(address(usdcToken())))
        });

        return accountingContexts;
    }

    function _usdcPayoutLimitGroups(
        IJBMultiTerminal terminal,
        uint256 payoutAmount
    )
        internal
        view
        returns (JBFundAccessLimitGroup[] memory)
    {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        payoutLimits[0] =
            JBCurrencyAmount({amount: uint224(payoutAmount), currency: uint32(uint160(address(usdcToken())))});

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(terminal),
            token: address(usdcToken()),
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        return fundAccessLimitGroups;
    }
}

contract NonConsumingPayHook is ERC165, IJBPayHook {
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata) external payable override {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBPayHook).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract NonConsumingCashOutHook is ERC165, IJBCashOutHook {
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata) external payable override {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBCashOutHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
