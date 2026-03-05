// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";

/// @notice Tests for permission system correctness: ROOT restrictions, wildcard, boundary IDs, escalation prevention.
contract PermissionEscalation_Local is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    uint256 public projectId2;
    uint256 public projectId3;
    address public projectOwner;
    address public alice;
    address public bob;
    address public charlie;

    function setUp() public override {
        super.setUp();
        projectOwner = multisig();
        alice = address(0xA11CE);
        bob = address(0xB0B);
        charlie = address(0xC4A7);

        // Launch fee collector project (#1)
        _launchFeeProject();

        // Launch test project #2
        projectId2 = _launchSimpleProject("project2");

        // Launch test project #3
        projectId3 = _launchSimpleProject("project3");

        // Give Alice ROOT on project 2
        uint8[] memory rootPerms = new uint8[](1);
        rootPerms[0] = JBPermissionIds.ROOT;
        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner,
                JBPermissionsData({operator: alice, projectId: uint64(projectId2), permissionIds: rootPerms})
            );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _launchFeeProject() internal {
        JBRulesetConfig[] memory feeRulesetConfig = new JBRulesetConfig[](1);
        feeRulesetConfig[0].mustStartAtOrAfter = 0;
        feeRulesetConfig[0].duration = 0;
        feeRulesetConfig[0].weight = 1000e18;
        feeRulesetConfig[0].weightCutPercent = 0;
        feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        feeRulesetConfig[0].metadata = JBRulesetMetadata({
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
        feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory terminalConfigurations = _defaultTerminalConfig();

        jbController()
            .launchProjectFor({
                owner: address(420),
                projectUri: "feeCollector",
                rulesetConfigurations: feeRulesetConfig,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });
    }

    function _launchSimpleProject(string memory uri) internal returns (uint256) {
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 3000,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
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
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        return jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: uri,
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });
    }

    function _defaultTerminalConfig() internal view returns (JBTerminalConfig[] memory) {
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});
        return terminalConfigurations;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 1: ROOT cannot set wildcard permissions (projectId=0)
    // ═══════════════════════════════════════════════════════════════════

    function test_rootOperator_cannotSetWildcardPermissions() public {
        // Alice has ROOT on project 2. She tries to grant Bob permissions at projectId=0 (wildcard).
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.CASH_OUT_TOKENS;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissions.JBPermissions_Unauthorized.selector, projectOwner, alice, 0, JBPermissionIds.ROOT
            )
        );
        jbPermissions()
            .setPermissionsFor(projectOwner, JBPermissionsData({operator: bob, projectId: 0, permissionIds: perms}));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 2: ROOT cannot grant ROOT to a third party
    // ═══════════════════════════════════════════════════════════════════

    function test_rootOperator_cannotGrantRoot() public {
        // Alice has ROOT on project 2. She tries to grant ROOT to Bob.
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.ROOT;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissions.JBPermissions_Unauthorized.selector,
                projectOwner,
                alice,
                uint64(projectId2),
                JBPermissionIds.ROOT
            )
        );
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms})
            );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 3: ROOT CAN grant non-ROOT permissions (positive test)
    // ═══════════════════════════════════════════════════════════════════

    function test_rootOperator_canGrantNonRootPermissions() public {
        // Alice has ROOT on project 2. She grants Bob CASH_OUT_TOKENS.
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.CASH_OUT_TOKENS;

        vm.prank(alice);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms})
            );

        // Verify Bob now has CASH_OUT_TOKENS
        bool hasPerm = jbPermissions()
            .hasPermission({
                operator: bob,
                account: projectOwner,
                projectId: projectId2,
                permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                includeRoot: false,
                includeWildcardProjectId: false
            });
        assertTrue(hasPerm, "ROOT should be able to grant non-ROOT permissions");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 4: Wildcard permission — applies cross-project
    // ═══════════════════════════════════════════════════════════════════

    function test_wildcardPermission_crossProject() public {
        // Owner grants Bob CASH_OUT_TOKENS at projectId=0 (wildcard)
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.CASH_OUT_TOKENS;

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(projectOwner, JBPermissionsData({operator: bob, projectId: 0, permissionIds: perms}));

        // Bob should have CASH_OUT_TOKENS for project 2 (via wildcard)
        bool hasPermProject2 = jbPermissions()
            .hasPermission({
                operator: bob,
                account: projectOwner,
                projectId: projectId2,
                permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                includeRoot: false,
                includeWildcardProjectId: true
            });
        assertTrue(hasPermProject2, "Wildcard should apply to project 2");

        // Bob should have CASH_OUT_TOKENS for project 3 (via wildcard)
        bool hasPermProject3 = jbPermissions()
            .hasPermission({
                operator: bob,
                account: projectOwner,
                projectId: projectId3,
                permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                includeRoot: false,
                includeWildcardProjectId: true
            });
        assertTrue(hasPermProject3, "Wildcard should apply to project 3");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 5: Permission revocation is immediate
    // ═══════════════════════════════════════════════════════════════════

    function test_permissionRevocation_immediate() public {
        // Grant Bob CASH_OUT_TOKENS on project 2
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.CASH_OUT_TOKENS;

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms})
            );

        // Verify Bob has it
        assertTrue(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Bob should have CASH_OUT_TOKENS"
        );

        // Revoke by setting empty permissions
        uint8[] memory emptyPerms = new uint8[](0);

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner,
                JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: emptyPerms})
            );

        // Immediately verify Bob lost it
        assertFalse(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Revocation should be immediate"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 6: Bit 255 (ROOT) works. Bit 256 reverts.
    // ═══════════════════════════════════════════════════════════════════

    function test_permission_bit255_boundary() public {
        // Permission 255 should work (max valid ID)
        uint8[] memory perms = new uint8[](1);
        perms[0] = 255;

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms})
            );

        bool hasPerm = jbPermissions()
            .hasPermission({
                operator: bob,
                account: projectOwner,
                projectId: projectId2,
                permissionId: 255,
                includeRoot: false,
                includeWildcardProjectId: false
            });
        assertTrue(hasPerm, "Permission ID 255 should work");

        // Permission 256 should revert (out of bounds)
        vm.expectRevert(abi.encodeWithSelector(JBPermissions.JBPermissions_PermissionIdOutOfBounds.selector, 256));
        jbPermissions()
            .hasPermission({
                operator: bob,
                account: projectOwner,
                projectId: projectId2,
                permissionId: 256,
                includeRoot: false,
                includeWildcardProjectId: false
            });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 7: Permission ID 0 reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_permission_bit0_rejected() public {
        // Permission 0 is invalid
        uint8[] memory perms = new uint8[](1);
        perms[0] = 0;

        vm.prank(projectOwner);
        vm.expectRevert(abi.encodeWithSelector(JBPermissions.JBPermissions_NoZeroPermission.selector));
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms})
            );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 8: Bob can't cashOut Alice's tokens without permission
    // ═══════════════════════════════════════════════════════════════════

    function test_permissionedOperation_cashOut_requiresPermission() public {
        // Give Alice tokens by paying
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: projectId2,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: alice,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Bob tries to cash out Alice's tokens without permission
        vm.prank(bob);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: alice,
                projectId: projectId2,
                cashOutCount: tokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(bob),
                metadata: new bytes(0)
            });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 9: ownerMustSendPayouts flag enforcement
    // ═══════════════════════════════════════════════════════════════════

    function test_permissionedOperation_sendPayouts_ownerMustSend() public {
        // Launch project with ownerMustSendPayouts = true
        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0].mustStartAtOrAfter = 0;
        rulesetConfig[0].duration = 0;
        rulesetConfig[0].weight = 1000e18;
        rulesetConfig[0].weightCutPercent = 0;
        rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfig[0].metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            ownerMustSendPayouts: true, // KEY
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
        rulesetConfig[0].splitGroups = new JBSplitGroup[](0);

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 10 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;

        uint256 pid = jbController()
            .launchProjectFor({
                owner: projectOwner,
                projectUri: "ownerMustPayTest",
                rulesetConfigurations: rulesetConfig,
                terminalConfigurations: _defaultTerminalConfig(),
                memo: ""
            });

        // Fund the project
        vm.deal(address(0xBA1E), 20 ether);
        vm.prank(address(0xBA1E));
        jbMultiTerminal().pay{value: 20 ether}({
            projectId: pid,
            token: JBConstants.NATIVE_TOKEN,
            amount: 20 ether,
            beneficiary: address(0xBA1E),
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Grant Bob SEND_PAYOUTS permission
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.SEND_PAYOUTS;
        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(pid), permissionIds: perms})
            );

        // Charlie (no permission) tries to send payouts — should fail because ownerMustSendPayouts
        // requires SEND_PAYOUTS permission
        vm.prank(charlie);
        vm.expectRevert();
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });

        // Bob (with SEND_PAYOUTS permission) CAN send payouts
        vm.prank(bob);
        jbMultiTerminal()
            .sendPayoutsOf({
                projectId: pid,
                token: JBConstants.NATIVE_TOKEN,
                amount: 5 ether,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                minTokensPaidOut: 0
            });
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 10: ROOT on project 2 has no power over project 3
    // ═══════════════════════════════════════════════════════════════════

    function test_permission_rootOnProject_doesNotAffectOtherProject() public {
        // Alice has ROOT on project 2 (from setUp)
        // Alice should NOT have any permissions on project 3
        bool hasPermOnProject3 = jbPermissions()
            .hasPermission({
                operator: alice,
                account: projectOwner,
                projectId: projectId3,
                permissionId: JBPermissionIds.ROOT,
                includeRoot: true,
                includeWildcardProjectId: false
            });
        assertFalse(hasPermOnProject3, "ROOT on project 2 must not grant power over project 3");

        bool hasCashOutOnProject3 = jbPermissions()
            .hasPermission({
                operator: alice,
                account: projectOwner,
                projectId: projectId3,
                permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                includeRoot: true,
                includeWildcardProjectId: false
            });
        assertFalse(hasCashOutOnProject3, "ROOT on project 2 must not grant CASH_OUT on project 3");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 11: Double set overwrites previous (not additive)
    // ═══════════════════════════════════════════════════════════════════

    function test_permission_doubleSet_overwritesPrevious() public {
        // Grant Bob CASH_OUT_TOKENS + BURN_TOKENS
        uint8[] memory perms1 = new uint8[](2);
        perms1[0] = JBPermissionIds.CASH_OUT_TOKENS;
        perms1[1] = JBPermissionIds.BURN_TOKENS;

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms1})
            );

        assertTrue(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Bob should have CASH_OUT_TOKENS"
        );
        assertTrue(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.BURN_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Bob should have BURN_TOKENS"
        );

        // Now set ONLY MINT_TOKENS — should replace all previous
        uint8[] memory perms2 = new uint8[](1);
        perms2[0] = JBPermissionIds.MINT_TOKENS;

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms2})
            );

        // Bob should only have MINT_TOKENS, not the previous ones
        assertTrue(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.MINT_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Bob should now have MINT_TOKENS"
        );
        assertFalse(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Bob should no longer have CASH_OUT_TOKENS (overwritten)"
        );
        assertFalse(
            jbPermissions()
                .hasPermission({
                    operator: bob,
                    account: projectOwner,
                    projectId: projectId2,
                    permissionId: JBPermissionIds.BURN_TOKENS,
                    includeRoot: false,
                    includeWildcardProjectId: false
                }),
            "Bob should no longer have BURN_TOKENS (overwritten)"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Test 12: ERC2771 meta-tx uses correct msg.sender for permissions
    // ═══════════════════════════════════════════════════════════════════

    function test_rootPermission_trustedForwarder() public {
        // Grant Bob ROOT on project 2
        uint8[] memory perms = new uint8[](1);
        perms[0] = JBPermissionIds.CASH_OUT_TOKENS;

        vm.prank(projectOwner);
        jbPermissions()
            .setPermissionsFor(
                projectOwner, JBPermissionsData({operator: bob, projectId: uint64(projectId2), permissionIds: perms})
            );

        // Call from trusted forwarder with Bob appended as sender
        // The permission check should use Bob's address, not the forwarder
        address forwarder = trustedForwarder();

        // Verify the forwarder is set up correctly
        assertTrue(forwarder != address(0), "Trusted forwarder should be set");

        // Construct the calldata with Bob's address appended (ERC2771 pattern)
        bytes memory callData = abi.encodeWithSelector(
            IJBPermissions.hasPermission.selector,
            bob,
            projectOwner,
            projectId2,
            JBPermissionIds.CASH_OUT_TOKENS,
            false,
            false
        );

        // Direct call should return true
        bool hasPerm = jbPermissions()
            .hasPermission({
                operator: bob,
                account: projectOwner,
                projectId: projectId2,
                permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                includeRoot: false,
                includeWildcardProjectId: false
            });
        assertTrue(hasPerm, "Bob should have CASH_OUT_TOKENS via direct call");

        // Verify that permission checking respects msg.sender context
        // Charlie (unpermissioned) cannot use Bob's permissions
        bool charlieHasPerm = jbPermissions()
            .hasPermission({
                operator: charlie,
                account: projectOwner,
                projectId: projectId2,
                permissionId: JBPermissionIds.CASH_OUT_TOKENS,
                includeRoot: false,
                includeWildcardProjectId: false
            });
        assertFalse(charlieHasPerm, "Charlie should NOT have Bob's CASH_OUT_TOKENS");
    }

    receive() external payable {}
}
