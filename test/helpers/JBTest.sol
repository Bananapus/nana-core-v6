// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBRuleset} from "../../src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {Test} from "lib/forge-std/src/Test.sol";

contract JBTest is Test {
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    /// @notice The pinned CREATE2 address of `JBPayoutSplitGroupLib` from `foundry.toml`.
    /// @dev Must match the `libraries = [...]` entry. Tests etch the runtime code here so
    /// `JBMultiTerminal`'s delegatecalls into the library resolve.
    address internal constant _JB_PAYOUT_SPLIT_GROUP_LIB = 0xE5767922e5f8d18c57C4685289Ef92D859eb980b;

    /// @notice Deploy `JBPayoutSplitGroupLib` locally and etch its runtime bytecode at the pinned
    /// address from `foundry.toml`. Forge auto-deploys linked libraries only when no `libraries`
    /// entry is configured; once the address is pinned (needed so deploy-all-v6 can read
    /// `artifacts/JBMultiTerminal.json::bytecode.object` as valid hex), unit tests must plant the
    /// runtime code themselves or any path through `executePayout` / `sendPayoutsToSplitGroupOf`
    /// reverts with `delegatecall to non-contract address`.
    function _etchPayoutSplitGroupLib() internal {
        bytes memory creationCode = vm.getCode("JBPayoutSplitGroupLib");
        address libImpl;
        assembly {
            libImpl := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(libImpl != address(0), "JBPayoutSplitGroupLib deploy failed");
        vm.etch(_JB_PAYOUT_SPLIT_GROUP_LIB, libImpl.code);
    }

    function mockExpect(address _where, bytes memory _encodedCall, bytes memory _returns) public {
        vm.mockCall(_where, _encodedCall, _returns);
        vm.expectCall(_where, _encodedCall);
    }

    /// @notice Calldata for `IJBFeelessAddresses.isFeelessFor(address,uint256,address)`.
    /// @dev `isFeelessFor` is overloaded on the registry; `abi.encodeCall(IJBFeelessAddresses.isFeelessFor, ...)` is
    /// ambiguous after the caller-aware overload was added. Terminals call the 3-arg variant forwarding
    /// `_msgSender()`, so unit tests mocking the registry must encode the 3-arg selector with the expected caller.
    function feelessCalldata(address addr, uint256 projectId, address caller) public pure returns (bytes memory) {
        return
            abi.encodeWithSelector(bytes4(keccak256("isFeelessFor(address,uint256,address)")), addr, projectId, caller);
    }

    // Multiple calls with different return values
    function mockExpectSubsequent(address _where, bytes memory _encodedCall, bytes[] memory _returns) public {
        // Mocks calls with different return values
        vm.mockCalls(_where, _encodedCall, _returns);

        // Will check that multiple calls are made
        for (uint256 i = 0; i < _returns.length; i++) {
            vm.expectCall(_where, _encodedCall);
        }
    }

    function generateFriendlyRuleset() public view returns (JBRuleset memory) {
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        return JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });
    }

    function generateEmptyMetadata() public pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
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
    }

    function generateUnfriendlyRuleset() public view returns (JBRuleset memory) {
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: true,
            pauseCreditTransfers: true,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: true,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            holdFees: true,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        return JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });
    }
}
