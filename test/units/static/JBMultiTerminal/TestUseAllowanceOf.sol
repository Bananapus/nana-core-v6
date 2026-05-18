// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "../../../../src/interfaces/IJBFeeTerminal.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBPayoutTerminal} from "../../../../src/interfaces/IJBPayoutTerminal.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBTokenAmount} from "../../../../src/structs/JBTokenAmount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

contract TestUseAllowanceOf_Local is JBMultiTerminalSetup {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    uint256 _projectId = 1;

    function setUp() public {
        super.multiTerminalSetup();
    }

    function test_WhenAmountPaidOutLTMinTokensPaidOut() external {
        // it will revert UNDER_MIN_TOKENS_PAID_OUT

        // mock owner call
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // needed for terminal store mock call
        JBRuleset memory returnedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        JBAccountingContext memory mockTokenContext = JBAccountingContext({token: address(0), decimals: 0, currency: 0});

        // recordUsedAllowance
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordUsedAllowanceOf, (_projectId, mockTokenContext.token, 0, 0)),
            abi.encode(returnedRuleset, 0)
        );

        // feeless check
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(true)
        );

        vm.expectRevert(abi.encodeWithSelector(JBMultiTerminal.JBMultiTerminal_UnderMin.selector, 0, 1));
        _terminal.useAllowanceOf(_projectId, address(0), 0, 0, 1, payable(address(this)), payable(address(this)), "", 0);
    }

    function test_WhenOwnerEQFeeless() external {
        // it will not incur fees
        address mockToken = makeAddr("token");

        // mock owner call
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // needed for terminal store mock call
        JBRuleset memory returnedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        // recordUsedAllowance — terminal now passes token address directly.
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordUsedAllowanceOf, (_projectId, mockToken, 100, 0)),
            abi.encode(returnedRuleset, 100)
        );

        // feeless check
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(true)
        );

        mockExpect(mockToken, abi.encodeCall(IERC20.transfer, (address(this), 100)), abi.encode(true));

        vm.expectEmit();
        emit IJBPayoutTerminal.UseAllowance({
            rulesetId: returnedRuleset.id,
            rulesetCycleNumber: returnedRuleset.cycleNumber,
            projectId: _projectId,
            beneficiary: address(this),
            feeBeneficiary: address(this),
            amount: 100,
            amountPaidOut: 100,
            netAmountPaidOut: 100,
            memo: "",
            caller: address(this)
        });
        _terminal.useAllowanceOf(_projectId, mockToken, 100, 0, 0, payable(address(this)), payable(address(this)), "", 0);
    }

    function test_WhenBeneficiaryIsFeeless() external {
        address mockToken = makeAddr("token");
        address beneficiary = makeAddr("bene");

        // mock owner call
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // needed for terminal store mock call
        JBRuleset memory returnedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        // recordUsedAllowance — terminal now passes token address directly
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordUsedAllowanceOf, (_projectId, mockToken, 100, 0)),
            abi.encode(returnedRuleset, 100)
        );

        // first feeless check which will return false.
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(false)
        );

        // second which is true for beneficiary.
        mockExpect(address(feelessAddresses), feelessCalldata(beneficiary, _projectId, address(this)), abi.encode(true));

        mockExpect(mockToken, abi.encodeCall(IERC20.transfer, (beneficiary, 100)), abi.encode(true));

        vm.expectEmit();
        emit IJBPayoutTerminal.UseAllowance({
            rulesetId: returnedRuleset.id,
            rulesetCycleNumber: returnedRuleset.cycleNumber,
            projectId: _projectId,
            beneficiary: beneficiary,
            feeBeneficiary: address(this),
            amount: 100,
            amountPaidOut: 100,
            netAmountPaidOut: 100,
            memo: "",
            caller: address(this)
        });

        _terminal.useAllowanceOf({
            projectId: _projectId,
            token: mockToken,
            amount: 100,
            currency: 0,
            minTokensPaidOut: 100,
            beneficiary: payable(beneficiary),
            feeBeneficiary: payable(address(this)),
            memo: "",
            referralProjectId: 0
        });
    }

    function test_WhenNotFeeless() external {
        address mockToken = makeAddr("token");
        address beneficiary = makeAddr("bene");

        // Mock controller for mint call on fee payments
        address controller = makeAddr("controller");

        // Weight for a fee calculation that would take place in terminal store
        uint112 weight = 1000 * 10 ** 18;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currencyId = uint32(uint160(mockToken));

        // Start the cascade of issuing project tokens to the fee beneficiary. (recieving platform tokens for paying a
        // fee, or being designated as such).
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(controller))
        );

        // mock owner call
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // needed for terminal store mock call
        JBRuleset memory returnedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: mockToken, decimals: 18, currency: currencyId});

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // Mock accountingContextOf for subsequent reads (used by _tokenAmountOf during fee processing)
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, mockToken)),
            abi.encode(_tokens[0])
        );

        _terminal.accountingContextForTokenOf(_projectId, mockToken);

        // recordUsedAllowance
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordUsedAllowanceOf, (_projectId, _tokens[0].token, 100, 0)),
            abi.encode(returnedRuleset, 100)
        );

        // first feeless check which will return false.
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(false)
        );

        // second which is also false.
        mockExpect(
            address(feelessAddresses), feelessCalldata(beneficiary, _projectId, address(this)), abi.encode(false)
        );

        mockExpect(mockToken, abi.encodeCall(IERC20.transfer, (beneficiary, 98)), abi.encode(true));

        // call to find the primary terminal for fee processing
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, mockToken)),
            abi.encode(address(_terminal))
        );

        JBTokenAmount memory tokenContext =
            JBTokenAmount({token: mockToken, decimals: 18, currency: currencyId, value: 2});

        // mock call to jbterminalstore
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordPaymentFrom,
                // feeBeneficiary will receive platform tokens for paying a fee, project id is encoded for memo
                (address(_terminal), tokenContext, _projectId, address(this), bytes(abi.encodePacked(_projectId)))
            ),
            abi.encode(returnedRuleset, 1, new JBPayHookSpecification[](0))
        );

        // Return the mint of call as minting one project token for paying a fee.
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.mintTokensOf, (_projectId, 1, address(this), "", true)),
            abi.encode(2)
        );

        vm.expectEmit();
        emit IJBPayoutTerminal.UseAllowance({
            rulesetId: returnedRuleset.id,
            rulesetCycleNumber: returnedRuleset.cycleNumber,
            projectId: _projectId,
            beneficiary: beneficiary,
            feeBeneficiary: address(this),
            amount: 100,
            amountPaidOut: 100,
            netAmountPaidOut: 98,
            memo: "",
            caller: address(this)
        });

        _terminal.useAllowanceOf({
            projectId: _projectId,
            token: mockToken,
            amount: 100,
            currency: 0,
            minTokensPaidOut: 97,
            beneficiary: payable(beneficiary),
            feeBeneficiary: payable(address(this)),
            memo: "",
            referralProjectId: 0
        });
    }

    // forge-lint: disable-next-line(mixed-case-function)
    modifier whenMsgSenderDNEQFeeless() {
        _;
    }

    function test_GivenRulesetHoldFeesEQTrue() external whenMsgSenderDNEQFeeless {
        // it will hold fees and emit HoldFee
        address mockToken = makeAddr("token");
        address beneficiary = makeAddr("bene");

        // Mock controller (needed for addAccountingContextsFor permission check)
        address controller = makeAddr("controller");

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currencyId = uint32(uint160(mockToken));

        // Mock controllerOf for addAccountingContextsFor permission check
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(controller))
        );

        // mock owner call
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        // Build a ruleset with holdFees=true via packed metadata
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
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
            holdFees: true,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_rulesMetadata);

        JBRuleset memory returnedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packedMetadata
        });

        // Set up accounting context so the token is recognized
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: mockToken, decimals: 18, currency: currencyId});

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // recordUsedAllowance
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordUsedAllowanceOf, (_projectId, _tokens[0].token, 100, 0)),
            abi.encode(returnedRuleset, 100)
        );

        // first feeless check: owner is NOT feeless
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(false)
        );

        // second feeless check: beneficiary is NOT feeless
        mockExpect(
            address(feelessAddresses), feelessCalldata(beneficiary, _projectId, address(this)), abi.encode(false)
        );

        // Fee is 2.5% of 100 = 2, so net = 98
        mockExpect(mockToken, abi.encodeCall(IERC20.transfer, (beneficiary, 98)), abi.encode(true));

        // Expect HoldFee event (fee is held, not processed)
        vm.expectEmit(true, true, true, true);
        emit IJBFeeTerminal.HoldFee({
            projectId: _projectId,
            token: mockToken,
            amount: 100,
            fee: 25,
            beneficiary: address(this),
            caller: address(this)
        });

        // Expect UseAllowance event
        vm.expectEmit();
        emit IJBPayoutTerminal.UseAllowance({
            rulesetId: returnedRuleset.id,
            rulesetCycleNumber: returnedRuleset.cycleNumber,
            projectId: _projectId,
            beneficiary: beneficiary,
            feeBeneficiary: address(this),
            amount: 100,
            amountPaidOut: 100,
            netAmountPaidOut: 98,
            memo: "",
            caller: address(this)
        });

        _terminal.useAllowanceOf({
            projectId: _projectId,
            token: mockToken,
            amount: 100,
            currency: 0,
            minTokensPaidOut: 97,
            beneficiary: payable(beneficiary),
            feeBeneficiary: payable(address(this)),
            memo: "",
            referralProjectId: 0
        });
    }

    function test_GivenRulesetHoldFeesDNEQTrue() external whenMsgSenderDNEQFeeless {
        // it will not hold fees and emit ProcessFee
        address mockToken = makeAddr("token2");
        address beneficiary = makeAddr("bene2");

        // Mock controller for mint call on fee payments
        address controller = makeAddr("controller2");

        // Weight for a fee calculation that would take place in terminal store
        uint112 weight = 1000 * 10 ** 18;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currencyId = uint32(uint160(mockToken));

        // Build a ruleset with holdFees=false explicitly via packed metadata
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
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
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_rulesMetadata);

        // Start the cascade of issuing project tokens to the fee beneficiary.
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(controller))
        );

        // mock owner call
        mockExpect(address(projects), abi.encodeCall(IERC721.ownerOf, (_projectId)), abi.encode(address(this)));

        JBRuleset memory returnedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packedMetadata
        });

        // Set up accounting context
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: mockToken, decimals: 18, currency: currencyId});

        // Mock recordAccountingContextOf in the store (validation now happens there)
        mockExpect(
            address(store), abi.encodeCall(IJBTerminalStore.recordAccountingContextOf, (_projectId, _tokens)), ""
        );

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        // Mock accountingContextOf for subsequent reads (used by _tokenAmountOf during fee processing)
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _projectId, mockToken)),
            abi.encode(_tokens[0])
        );

        // recordUsedAllowance
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordUsedAllowanceOf, (_projectId, _tokens[0].token, 100, 0)),
            abi.encode(returnedRuleset, 100)
        );

        // first feeless check: false
        mockExpect(
            address(feelessAddresses), feelessCalldata(address(this), _projectId, address(this)), abi.encode(false)
        );

        // second feeless check: false
        mockExpect(
            address(feelessAddresses), feelessCalldata(beneficiary, _projectId, address(this)), abi.encode(false)
        );

        // Fee = 2.5% of 100 = 2, net = 98
        mockExpect(mockToken, abi.encodeCall(IERC20.transfer, (beneficiary, 98)), abi.encode(true));

        // call to find the primary terminal for fee processing
        mockExpect(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, mockToken)),
            abi.encode(address(_terminal))
        );

        JBTokenAmount memory tokenContext =
            JBTokenAmount({token: mockToken, decimals: 18, currency: currencyId, value: 2});

        // mock call to jbterminalstore recordPaymentFrom for the fee payment
        mockExpect(
            address(store),
            abi.encodeCall(
                IJBTerminalStore.recordPaymentFrom,
                (address(_terminal), tokenContext, _projectId, address(this), bytes(abi.encodePacked(_projectId)))
            ),
            abi.encode(returnedRuleset, 1, new JBPayHookSpecification[](0))
        );

        // Return the mint call as minting one project token for paying a fee.
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.mintTokensOf, (_projectId, 1, address(this), "", true)),
            abi.encode(2)
        );

        // Expect ProcessFee event (fee is processed immediately, not held)
        vm.expectEmit(true, true, true, true);
        emit IJBFeeTerminal.ProcessFee({
            projectId: _projectId,
            token: mockToken,
            amount: 2,
            wasHeld: false,
            beneficiary: address(this),
            caller: address(this)
        });

        // Expect UseAllowance event
        vm.expectEmit();
        emit IJBPayoutTerminal.UseAllowance({
            rulesetId: returnedRuleset.id,
            rulesetCycleNumber: returnedRuleset.cycleNumber,
            projectId: _projectId,
            beneficiary: beneficiary,
            feeBeneficiary: address(this),
            amount: 100,
            amountPaidOut: 100,
            netAmountPaidOut: 98,
            memo: "",
            caller: address(this)
        });

        _terminal.useAllowanceOf({
            projectId: _projectId,
            token: mockToken,
            amount: 100,
            currency: 0,
            minTokensPaidOut: 97,
            beneficiary: payable(beneficiary),
            feeBeneficiary: payable(address(this)),
            memo: "",
            referralProjectId: 0
        });
    }

    function test_WhenTokenEQNATIVE_TOKEN() external {
        // it will send ETH via sendValue
    }

    function test_WhenTokenEQERC20() external {
        // it will call safeTransfer
    }
}
