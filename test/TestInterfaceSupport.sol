// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {JBController} from "../src/JBController.sol";
import {JBDeadline} from "../src/JBDeadline.sol";
import {JBMultiTerminal} from "../src/JBMultiTerminal.sol";
import {JBProjects} from "../src/JBProjects.sol";
import {IJBCashOutTerminal} from "../src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBFeeTerminal} from "../src/interfaces/IJBFeeTerminal.sol";
import {IJBMigratable} from "../src/interfaces/IJBMigratable.sol";
import {IJBMultiTerminal} from "../src/interfaces/IJBMultiTerminal.sol";
import {IJBPayoutTerminal} from "../src/interfaces/IJBPayoutTerminal.sol";
import {IJBPermissioned} from "../src/interfaces/IJBPermissioned.sol";
import {IJBPermitTerminal} from "../src/interfaces/IJBPermitTerminal.sol";
import {IJBProjects} from "../src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// Contracts are introspective about the interfaces they adhere to.
contract TestEIP165_Local is TestBaseWorkflow {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    bytes4 private constant _notSupportedInterface = 0xffffffff;

    function testJBController() public view {
        JBController _controller = jbController();

        // Should support these interfaces.
        assertTrue(_controller.supportsInterface(type(IERC165).interfaceId));
        assertTrue(_controller.supportsInterface(type(IJBMigratable).interfaceId));
        assertTrue(_controller.supportsInterface(type(IJBPermissioned).interfaceId));
        assertTrue(_controller.supportsInterface(type(IJBController).interfaceId));

        // Make sure it doesn't always return true.
        assertTrue(!_controller.supportsInterface(_notSupportedInterface));
    }

    function testJBMultiTerminal() public view {
        JBMultiTerminal _terminal = jbMultiTerminal();

        // Should support these interfaces.
        assertTrue(_terminal.supportsInterface(type(IJBMultiTerminal).interfaceId));
        assertTrue(_terminal.supportsInterface(type(IJBTerminal).interfaceId));
        assertTrue(_terminal.supportsInterface(type(IJBCashOutTerminal).interfaceId));
        assertTrue(_terminal.supportsInterface(type(IJBPayoutTerminal).interfaceId));
        assertTrue(_terminal.supportsInterface(type(IJBPermitTerminal).interfaceId));
        assertTrue(_terminal.supportsInterface(type(IJBFeeTerminal).interfaceId));
        assertTrue(_terminal.supportsInterface(type(IERC165).interfaceId));

        // Make sure it doesn't always return true.
        assertTrue(!_terminal.supportsInterface(_notSupportedInterface));
    }

    function testJBProjects() public view {
        JBProjects _projects = jbProjects();

        // Should support these interfaces.
        assertTrue(_projects.supportsInterface(type(IERC165).interfaceId));
        assertTrue(_projects.supportsInterface(type(IERC721).interfaceId));
        assertTrue(_projects.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(_projects.supportsInterface(type(IJBProjects).interfaceId));

        // Make sure it doesn't always return true.
        assertTrue(!_projects.supportsInterface(_notSupportedInterface));
    }

    function testJBDeadline() public {
        JBDeadline _approvalHook = new JBDeadline(3000);

        // Should support these interfaces.
        assertTrue(_approvalHook.supportsInterface(type(IERC165).interfaceId));
        assertTrue(_approvalHook.supportsInterface(type(IJBRulesetApprovalHook).interfaceId));

        // Make sure it doesn't always return true.
        assertTrue(!_approvalHook.supportsInterface(_notSupportedInterface));
    }
}
