// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "forge-std/Test.sol";
import {JBConstants} from "../../../src/libraries/JBConstants.sol";
import {IJBMultiTerminal} from "../../../src/interfaces/IJBMultiTerminal.sol";
import {IJBController} from "../../../src/interfaces/IJBController.sol";
import {IJBTokens} from "../../../src/interfaces/IJBTokens.sol";
import {IJBToken} from "../../../src/interfaces/IJBToken.sol";

/// @notice Handler contract for JBTokens invariant testing.
/// @dev Drives mint, burn, claim, and transfer operations; tracks holders for sum-of-balances checks.
contract TokensHandler is Test {
    IJBMultiTerminal public terminal;
    IJBController public controller;
    IJBTokens public tokens;

    uint256 public projectId;
    address public projectOwner;

    // Track all unique holders for sum-of-balances invariant
    address[] public holders;
    mapping(address => bool) public isHolder;

    uint256 public constant NUM_ACTORS = 5;

    constructor(
        IJBMultiTerminal _terminal,
        IJBController _controller,
        IJBTokens _tokens,
        uint256 _projectId,
        address _projectOwner
    ) {
        terminal = _terminal;
        controller = _controller;
        tokens = _tokens;
        projectId = _projectId;
        projectOwner = _projectOwner;
    }

    function _getActor(uint256 seed) internal pure returns (address) {
        return address(uint160(0x2000 + (seed % NUM_ACTORS)));
    }

    function _trackHolder(address holder) internal {
        if (!isHolder[holder]) {
            isHolder[holder] = true;
            holders.push(holder);
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    /// @notice Pay the project to mint tokens for an actor.
    function mintTokens(uint256 actorSeed, uint256 amount) public {
        amount = bound(amount, 0.01 ether, 50 ether);
        address actor = _getActor(actorSeed);
        _trackHolder(actor);

        vm.deal(actor, amount);
        vm.prank(actor);
        terminal.pay{value: amount}({
            projectId: projectId,
            amount: amount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: actor,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });
    }

    /// @notice Burn tokens from an actor.
    function burnTokens(uint256 actorSeed, uint256 burnPercent) public {
        address actor = _getActor(actorSeed);
        uint256 balance = tokens.totalBalanceOf(actor, projectId);
        if (balance == 0) return;

        burnPercent = bound(burnPercent, 1, 100);
        uint256 burnCount = (balance * burnPercent) / 100;
        if (burnCount == 0) return;

        vm.prank(actor);
        controller.burnTokensOf({
            holder: actor,
            projectId: projectId,
            tokenCount: burnCount,
            memo: ""
        });
    }

    /// @notice Claim credits as ERC20 tokens.
    function claimCredits(uint256 actorSeed, uint256 claimPercent) public {
        address actor = _getActor(actorSeed);
        uint256 creditBalance = tokens.creditBalanceOf(actor, projectId);
        if (creditBalance == 0) return;

        claimPercent = bound(claimPercent, 1, 100);
        uint256 claimCount = (creditBalance * claimPercent) / 100;
        if (claimCount == 0) return;

        vm.prank(actor);
        controller.claimTokensFor({
            holder: actor,
            projectId: projectId,
            tokenCount: claimCount,
            beneficiary: actor
        });
    }

    /// @notice Transfer credits between actors.
    function transferCredits(uint256 fromSeed, uint256 toSeed, uint256 transferPercent) public {
        address from = _getActor(fromSeed);
        address to = _getActor(toSeed);
        if (from == to) return;

        uint256 creditBalance = tokens.creditBalanceOf(from, projectId);
        if (creditBalance == 0) return;

        transferPercent = bound(transferPercent, 1, 100);
        uint256 transferCount = (creditBalance * transferPercent) / 100;
        if (transferCount == 0) return;

        _trackHolder(to);

        vm.prank(from);
        controller.transferCreditsFrom({
            holder: from,
            projectId: projectId,
            recipient: to,
            creditCount: transferCount
        });
    }

    receive() external payable {}
}
