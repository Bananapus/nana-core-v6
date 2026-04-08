// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBControllerSetup} from "./JBControllerSetup.sol";

contract TestPreviewMintOf_Local is JBControllerSetup {
    uint256 _projectId = 1;

    function setUp() public {
        super.controllerSetup();
    }

    function test_ReturnsZeroCountsWhenTokenCountIsZero() external view {
        (uint256 beneficiaryTokenCount, uint256 reservedTokenCount) = _controller.previewMintOf(_projectId, 0, true);

        assertEq(beneficiaryTokenCount, 0);
        assertEq(reservedTokenCount, 0);
    }

    function test_ReturnsSplitCountsWhenUsingReservedPercent() external {
        uint256 tokenCount = 1000;

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 2500,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
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

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(ruleset));

        (uint256 beneficiaryTokenCount, uint256 reservedTokenCount) =
            _controller.previewMintOf(_projectId, tokenCount, true);

        assertEq(beneficiaryTokenCount, 750);
        assertEq(reservedTokenCount, 250);
    }

    function test_IgnoresReservedPercentWhenFlagIsFalse() external {
        uint256 tokenCount = 1000;

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 9000,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
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

        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });

        mockExpect(address(rulesets), abi.encodeCall(IJBRulesets.currentOf, (_projectId)), abi.encode(ruleset));

        (uint256 beneficiaryTokenCount, uint256 reservedTokenCount) =
            _controller.previewMintOf(_projectId, tokenCount, false);

        assertEq(beneficiaryTokenCount, tokenCount);
        assertEq(reservedTokenCount, 0);
    }
}
