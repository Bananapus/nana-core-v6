// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBMultiTerminalSetup5_1} from "./JBMultiTerminalSetup.sol";

contract TestAccountingContextsOf5_1_Local is JBMultiTerminalSetup5_1 {
    uint256 _projectId = 1;
    address _usdc = makeAddr("USDC");
    IJBController controller = IJBController(makeAddr("controller"));
    uint256 _usdcCurrency = uint32(uint160(_usdc));

    function setUp() public {
        super.multiTerminalSetup();
    }

    function test_WhenAccountingContextsAreSet() external {
        // it will return contexts

        // mock call to JBProjects ownerOf(_projectId)
        bytes memory _projectsCall = abi.encodeCall(IERC721.ownerOf, (_projectId));
        bytes memory _projectsCallReturn = abi.encode(address(this));
        mockExpect(address(projects), _projectsCall, _projectsCallReturn);

        // mock call to JBDirectory controllerOf(_projectId)
        mockExpect(
            address(directory), abi.encodeCall(IJBDirectory.controllerOf, (_projectId)), abi.encode(address(controller))
        );

        // mock call to tokens decimals()
        mockExpect(_usdc, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(6));

        // setup: return data
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
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
        
        // mock call to rulesets currentOf returning 0 to bypass ruleset checking
        mockExpect(address(controller), abi.encodeCall(IJBController.currentRulesetOf, (_projectId)), abi.encode(ruleset, metadata));

        // call params
        JBAccountingContext[] memory _tokens = new JBAccountingContext[](1);
        _tokens[0] = JBAccountingContext({token: _usdc, decimals: 6, currency: uint32(uint160(_usdc))});

        _terminal.addAccountingContextsFor(_projectId, _tokens);

        JBAccountingContext[] memory _storedContexts = _terminal.accountingContextsOf(_projectId);
        assertEq(_storedContexts[0].currency, _usdcCurrency);
        assertEq(_storedContexts[0].token, _usdc);
        assertEq(_storedContexts[0].decimals, 6);
    }

    function test_WhenAccountingContextsAreNotSet() external view {
        // it will return an empty array
        JBAccountingContext[] memory _storedContexts = _terminal.accountingContextsOf(_projectId);
        assertEq(_storedContexts.length, 0);
    }
}
