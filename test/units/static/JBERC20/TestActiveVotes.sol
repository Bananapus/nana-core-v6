// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBERC20} from "../../../../src/JBERC20.sol";
import {JBERC20Setup} from "./JBERC20Setup.sol";

contract TestActiveVotes_Local is JBERC20Setup {
    JBERC20 _token;

    address _amm = makeAddr("amm");
    address _holder = makeAddr("holder");
    address _passiveHolder = makeAddr("passiveHolder");
    address _representative = makeAddr("representative");

    function setUp() public {
        super.erc20Setup();

        _erc20.initialize("NANAPUS", "NANA", _tokens);
        _token = JBERC20(address(_erc20));
    }

    function test_WhenSupplyIsUndelegated_ThenTotalActiveVotesAreZero() external {
        uint256 holderAmount = 100 ether;
        uint256 passiveAmount = 300 ether;

        _mint({account: _holder, amount: holderAmount});
        _mint({account: _passiveHolder, amount: passiveAmount});

        uint256 undelegatedSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalSupply(undelegatedSnapshot), holderAmount + passiveAmount);
        assertEq(_token.getPastTotalActiveVotes(undelegatedSnapshot), 0);

        vm.prank(_holder);
        _token.delegate(_holder);

        uint256 delegatedSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalActiveVotes(delegatedSnapshot), holderAmount);
        assertEq(_token.getPastVotes({account: _holder, timepoint: delegatedSnapshot}), holderAmount);
        assertEq(_token.getPastVotes({account: _passiveHolder, timepoint: delegatedSnapshot}), 0);
    }

    function test_WhenHolderAddsAndRemovesAmmLiquidity_ThenOnlyHeldDelegatedTokensAreActive() external {
        uint256 amount = 100 ether;

        _mint({account: _holder, amount: amount});

        vm.prank(_holder);
        _token.delegate(_holder);

        uint256 heldSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalActiveVotes(heldSnapshot), amount);
        assertEq(_token.getPastVotes({account: _holder, timepoint: heldSnapshot}), amount);

        vm.prank(_holder);
        _token.transfer({to: _amm, value: amount});

        uint256 ammSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalSupply(ammSnapshot), amount);
        assertEq(_token.getPastTotalActiveVotes(ammSnapshot), 0);
        assertEq(_token.getPastVotes({account: _holder, timepoint: ammSnapshot}), 0);
        assertEq(_token.getPastVotes({account: _amm, timepoint: ammSnapshot}), 0);

        vm.prank(_amm);
        _token.transfer({to: _holder, value: amount});

        uint256 returnedSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalActiveVotes(returnedSnapshot), amount);
        assertEq(_token.getPastVotes({account: _holder, timepoint: returnedSnapshot}), amount);
    }

    function test_WhenDelegatedToRepresentative_ThenRepresentativeVotesAreActive() external {
        uint256 amount = 100 ether;

        _mint({account: _holder, amount: amount});

        vm.prank(_holder);
        _token.delegate(_representative);

        uint256 delegatedSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalActiveVotes(delegatedSnapshot), amount);
        assertEq(_token.getPastVotes({account: _holder, timepoint: delegatedSnapshot}), 0);
        assertEq(_token.getPastVotes({account: _representative, timepoint: delegatedSnapshot}), amount);

        vm.prank(_holder);
        _token.delegate(address(0));

        uint256 undelegatedSnapshot = _nextPastBlock();

        assertEq(_token.getPastTotalActiveVotes(undelegatedSnapshot), 0);
        assertEq(_token.getPastVotes({account: _representative, timepoint: undelegatedSnapshot}), 0);
    }

    function _mint(address account, uint256 amount) private {
        vm.prank(_tokens);
        _token.mint({account: account, amount: amount});
    }

    function _nextPastBlock() private returns (uint256 pastBlock) {
        pastBlock = block.number;
        vm.roll({newHeight: block.number + 1});
    }
}
