// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBController} from "../../../../src/JBController.sol";
import {JBPermissioned} from "../../../../src/abstract/JBPermissioned.sol";
import {IJBController} from "../../../../src/interfaces/IJBController.sol";
import {IJBDirectory} from "../../../../src/interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "../../../../src/interfaces/IJBFundAccessLimits.sol";
import {IJBPermissions} from "../../../../src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "../../../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "../../../../src/interfaces/IJBRulesets.sol";
import {IJBPrices} from "../../../../src/interfaces/IJBPrices.sol";
import {IJBProjects} from "../../../../src/interfaces/IJBProjects.sol";
import {IJBSplits} from "../../../../src/interfaces/IJBSplits.sol";
import {IJBTokens} from "../../../../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "../../../../src/libraries/JBRulesetMetadataResolver.sol";
import {JBCurrencyAmount} from "../../../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "../../../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../../../src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "../../../../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../../../../src/structs/JBTerminalConfig.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {JBTest} from "../../../helpers/JBTest.sol";

/// @notice Tests the OMNICHAIN_RULESET_OPERATOR trust boundary — verifying the operator can bypass
/// LAUNCH_RULESETS, SET_TERMINALS, and QUEUE_RULESETS permission checks via alsoGrantAccessIf.
contract TestOmnichainRulesetOperator_Local is JBTest {
    IJBController public _controller;

    // Mocks
    IJBPermissions public permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory public directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets public rulesets = IJBRulesets(makeAddr("rulesets"));
    IJBSplits public splits = IJBSplits(makeAddr("splits"));
    IJBFundAccessLimits public fundAccessLimits = IJBFundAccessLimits(makeAddr("limits"));

    // Use makeAddr for projects so we can mock ERC721 calls
    address public projectsAddr = makeAddr("projects");

    address public operator = makeAddr("omnichainOperator");
    address public projectOwner = makeAddr("projectOwner");
    address public randomCaller = makeAddr("randomCaller");
    uint256 public projectId = 1;

    function setUp() public {
        // Deploy controller with a non-zero OMNICHAIN_RULESET_OPERATOR
        _controller = new JBController(
            directory,
            fundAccessLimits,
            permissions,
            IJBPrices(makeAddr("prices")),
            IJBProjects(projectsAddr),
            rulesets,
            splits,
            IJBTokens(makeAddr("tokens")),
            operator,
            makeAddr("forwarder")
        );
    }

    // ── Helpers
    // ──────────────────────────────────────────────────────────

    function _genRulesetConfig() internal pure returns (JBTerminalConfig[] memory, JBRulesetConfig[] memory) {
        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](0);
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);

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

        JBFundAccessLimitGroup[] memory limitGroups = new JBFundAccessLimitGroup[](1);
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 0, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        surplusAllowances[0] = JBCurrencyAmount({amount: 0, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        limitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(0),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: surplusAllowances
        });

        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 0;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = limitGroups;

        return (terminalConfigs, rulesetConfigs);
    }

    /// @dev Mock the full call chain for a successful launchRulesetsFor.
    function _mockLaunchSuccess(JBRulesetConfig[] memory rulesetConfigs) internal {
        uint48 ts = uint48(block.timestamp);

        // ownerOf
        vm.mockCall(projectsAddr, abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // No existing rulesets
        vm.mockCall(address(rulesets), abi.encodeCall(IJBRulesets.latestRulesetIdOf, (projectId)), abi.encode(0));

        // setControllerOf
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.setControllerOf, (projectId, IERC165(address(_controller)))),
            ""
        );

        // queueFor
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: ts,
            basedOnId: 0,
            start: ts,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        vm.mockCall(
            address(rulesets),
            abi.encodeCall(
                IJBRulesets.queueFor,
                (
                    projectId,
                    0,
                    0,
                    0,
                    rulesetConfigs[0].approvalHook,
                    JBRulesetMetadataResolver.packRulesetMetadata(rulesetConfigs[0].metadata),
                    0
                )
            ),
            abi.encode(ruleset)
        );

        // setSplitGroupsOf
        vm.mockCall(
            address(splits),
            abi.encodeCall(IJBSplits.setSplitGroupsOf, (projectId, ts, rulesetConfigs[0].splitGroups)),
            ""
        );

        // setFundAccessLimitsFor
        vm.mockCall(
            address(fundAccessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.setFundAccessLimitsFor, (projectId, ts, rulesetConfigs[0].fundAccessLimitGroups)
            ),
            ""
        );
    }

    /// @dev Mock the full call chain for a successful queueRulesetsOf.
    function _mockQueueSuccess(JBRulesetConfig[] memory rulesetConfigs) internal {
        uint48 ts = uint48(block.timestamp);

        // ownerOf
        vm.mockCall(projectsAddr, abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // queueFor
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 2,
            id: ts,
            basedOnId: 1,
            start: ts,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        vm.mockCall(
            address(rulesets),
            abi.encodeCall(
                IJBRulesets.queueFor,
                (
                    projectId,
                    0,
                    0,
                    0,
                    rulesetConfigs[0].approvalHook,
                    JBRulesetMetadataResolver.packRulesetMetadata(rulesetConfigs[0].metadata),
                    0
                )
            ),
            abi.encode(ruleset)
        );

        // setSplitGroupsOf
        vm.mockCall(
            address(splits),
            abi.encodeCall(IJBSplits.setSplitGroupsOf, (projectId, ts, rulesetConfigs[0].splitGroups)),
            ""
        );

        // setFundAccessLimitsFor
        vm.mockCall(
            address(fundAccessLimits),
            abi.encodeCall(
                IJBFundAccessLimits.setFundAccessLimitsFor, (projectId, ts, rulesetConfigs[0].fundAccessLimitGroups)
            ),
            ""
        );
    }

    // ── Tests
    // ────────────────────────────────────────────────────────────

    function test_operatorCanLaunchRulesetsWithoutPermission() external {
        (JBTerminalConfig[] memory terminalConfigs, JBRulesetConfig[] memory rulesetConfigs) = _genRulesetConfig();
        _mockLaunchSuccess(rulesetConfigs);

        // Operator calls launchRulesetsFor without owning the project or having any permission grants.
        // The alsoGrantAccessIf bypass should allow this.
        vm.prank(operator);
        _controller.launchRulesetsFor(projectId, "", rulesetConfigs, terminalConfigs, "");
    }

    function test_operatorCanQueueRulesetsWithoutPermission() external {
        (, JBRulesetConfig[] memory rulesetConfigs) = _genRulesetConfig();
        _mockQueueSuccess(rulesetConfigs);

        // Operator calls queueRulesetsOf without owning the project or having any permission grants.
        vm.prank(operator);
        _controller.queueRulesetsOf(projectId, rulesetConfigs, "");
    }

    function test_nonOperatorCannotBypassPermissions() external {
        (JBTerminalConfig[] memory terminalConfigs, JBRulesetConfig[] memory rulesetConfigs) = _genRulesetConfig();

        // Mock ownerOf — randomCaller is not the owner
        vm.mockCall(projectsAddr, abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // Mock permission check — randomCaller has no permissions
        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (randomCaller, projectOwner, projectId, JBPermissionIds.LAUNCH_RULESETS, true, true)
            ),
            abi.encode(false)
        );

        // Should revert for launchRulesetsFor
        vm.prank(randomCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                randomCaller,
                projectId,
                JBPermissionIds.LAUNCH_RULESETS
            )
        );
        _controller.launchRulesetsFor(projectId, "", rulesetConfigs, terminalConfigs, "");

        // Mock permission check for QUEUE_RULESETS — randomCaller has no permissions
        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.hasPermission,
                (randomCaller, projectOwner, projectId, JBPermissionIds.QUEUE_RULESETS, true, true)
            ),
            abi.encode(false)
        );

        // Should revert for queueRulesetsOf
        vm.prank(randomCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                projectOwner,
                randomCaller,
                projectId,
                JBPermissionIds.QUEUE_RULESETS
            )
        );
        _controller.queueRulesetsOf(projectId, rulesetConfigs, "");
    }

    function test_operatorCannotLaunchIfRulesetsExist() external {
        (JBTerminalConfig[] memory terminalConfigs, JBRulesetConfig[] memory rulesetConfigs) = _genRulesetConfig();

        // Mock ownerOf
        vm.mockCall(projectsAddr, abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));

        // Project already has rulesets
        vm.mockCall(address(rulesets), abi.encodeCall(IJBRulesets.latestRulesetIdOf, (projectId)), abi.encode(1));

        // Even the operator cannot launch if rulesets already exist
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(JBController.JBController_RulesetsAlreadyLaunched.selector, projectId));
        _controller.launchRulesetsFor(projectId, "", rulesetConfigs, terminalConfigs, "");
    }
}
