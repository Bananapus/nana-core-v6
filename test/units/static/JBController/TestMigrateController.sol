// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import /* {*} from */ "../../../helpers/TestBaseWorkflow.sol";
import {JBControllerSetup} from "./JBControllerSetup.sol";

contract TestMigrateController_Local is JBControllerSetup {
    using stdStorage for StdStorage;

    function setUp() public {
        super.controllerSetup();
    }

    modifier whenCallerHasPermission() {
        // mock ownerOf call
        bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (1));
        bytes memory _ownerData = abi.encode(address(this));

        mockExpect(address(projects), _ownerOfCall, _ownerData);
        _;
    }

    modifier migrationIsAllowedByRuleset() {
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2, //50%
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2, //50%
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        // setup: return data
        JBRuleset memory data = JBRuleset({
            cycleNumber: 1,
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        // mock currentOf call
        bytes memory _currentOfCall = abi.encodeCall(IJBRulesets.currentOf, (1));
        bytes memory _returned = abi.encode(data);

        mockExpect(address(rulesets), _currentOfCall, _returned);
        _;
    }

    modifier migrationIsNotAllowedByRuleset() {
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2, //50%
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE / 2, //50%
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            holdFees: false,
            useTotalSurplusForCashOuts: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 _packedMetadata = JBRulesetMetadataResolver.packRulesetMetadata(_metadata);

        // setup: return data
        JBRuleset memory data = JBRuleset({
            cycleNumber: 1,
            id: uint48(block.timestamp),
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packedMetadata
        });

        // mock currentOf call
        bytes memory _currentOfCall = abi.encodeCall(IJBRulesets.currentOf, (1));
        bytes memory _returned = abi.encode(data);

        mockExpect(address(rulesets), _currentOfCall, _returned);
        _;
    }

    function test_Revert_When_Caller_Is_Not_Directory() external {
        // it should revert

        vm.expectRevert(
            abi.encodeWithSelector(
                JBController.JBController_OnlyDirectory.selector, address(this), _controller.DIRECTORY()
            )
        );
        IJBMigratable(address(_controller)).migrate(1, IJBMigratable(address(this)));
    }

    function test_Revert_When_GivenReservedTokenBalanceIsPending() external {
        // it should send reserved tokens to splits
        // set storage since we can't mock internal calls
        stdstore.target(address(IJBMigratable(address(_controller)))).sig("pendingReservedTokenBalanceOf(uint256)")
            .with_key(uint256(1)).checked_write(uint256(100));

        vm.prank(address(directory));

        // Revert as expected, this functionality is no longer allowed since `JBController4_1`,
        // Pending is send out as part of `beforeReceiveMigrationFrom`.
        vm.expectRevert(abi.encodeWithSelector(JBController.JBController_PendingReservedTokens.selector, 100));
        IJBMigratable(address(_controller)).migrate(1, IJBMigratable(address(this)));
    }

    function test_GivenNoReservedTokenBalanceIsPending() external {
        // event as expected
        vm.expectEmit();
        emit IJBMigratable.Migrate(1, IJBMigratable(address(this)), address(directory));

        vm.prank(address(directory));
        IJBMigratable(address(_controller)).migrate(1, IJBMigratable(address(this)));
    }
}
