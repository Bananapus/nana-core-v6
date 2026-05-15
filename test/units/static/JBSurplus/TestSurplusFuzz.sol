// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "../../../../src/interfaces/IJBCashOutTerminal.sol";
import {IJBTerminal} from "../../../../src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "../../../../src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "../../../../src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "../../../../src/structs/JBRuleset.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {JBTest} from "../../../helpers/JBTest.sol";
import {JBSurplus} from "../../../../src/libraries/JBSurplus.sol";

/// @notice Mock terminal that returns a fixed surplus for testing JBSurplus.
contract MockSurplusTerminal is ERC165, IJBCashOutTerminal {
    uint256 public surplusAmount;

    constructor(uint256 _surplus) {
        surplusAmount = _surplus;
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external view override returns (uint256) {
        return surplusAmount;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBCashOutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // Stub implementations for IJBTerminal
    function accountingContextForTokenOf(uint256, address)
        external
        pure
        override
        returns (JBAccountingContext memory)
    {}
    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {}
    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        pure
        override
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {}
    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        override
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {}
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}
    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint256)
    {
        return 0;
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address,
        uint256,
        address payable,
        bytes calldata
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function payAfterCashOutTokensOf(
        address,
        uint256,
        uint256,
        address,
        uint256,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    )
        external
        pure
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

/// @notice Fuzz tests for the JBSurplus library.
contract TestSurplusFuzz_Local is JBTest {
    function setUp() external {}

    /// @notice Surplus with no terminals is 0.
    function testFuzz_noTerminals_returnsZero(uint256 projectId) external view {
        IJBTerminal[] memory terminals = new IJBTerminal[](0);

        uint256 surplus = JBSurplus.currentSurplusOf(projectId, terminals, new address[](0), 18, 1);
        assertEq(surplus, 0, "surplus with no terminals should be 0");
    }

    /// @notice Surplus aggregates correctly across multiple terminals.
    function testFuzz_multipleTerminals_aggregates(uint128 surplus1, uint128 surplus2) external {
        MockSurplusTerminal terminal1 = new MockSurplusTerminal(surplus1);
        MockSurplusTerminal terminal2 = new MockSurplusTerminal(surplus2);

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = terminal1;
        terminals[1] = terminal2;

        uint256 total = JBSurplus.currentSurplusOf(1, terminals, new address[](0), 18, 1);
        assertEq(total, uint256(surplus1) + uint256(surplus2), "surplus should be sum of all terminals");
    }

    /// @notice Surplus is monotonically increasing as terminal surpluses increase.
    function testFuzz_monotonic(uint128 surplus1, uint128 surplus2) external {
        vm.assume(surplus1 <= surplus2);

        MockSurplusTerminal terminal1 = new MockSurplusTerminal(surplus1);
        MockSurplusTerminal terminal2 = new MockSurplusTerminal(surplus2);

        IJBTerminal[] memory terminals1 = new IJBTerminal[](1);
        terminals1[0] = terminal1;

        IJBTerminal[] memory terminals2 = new IJBTerminal[](1);
        terminals2[0] = terminal2;

        uint256 total1 = JBSurplus.currentSurplusOf(1, terminals1, new address[](0), 18, 1);
        uint256 total2 = JBSurplus.currentSurplusOf(1, terminals2, new address[](0), 18, 1);

        assertLe(total1, total2, "surplus should be monotonically increasing");
    }
}
