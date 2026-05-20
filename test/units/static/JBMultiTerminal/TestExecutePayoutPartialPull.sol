// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBMultiTerminal} from "../../../../src/JBMultiTerminal.sol";
import {IJBFeelessAddresses} from "../../../../src/interfaces/IJBFeelessAddresses.sol";
import {IJBSplitHook} from "../../../../src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "../../../../src/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "../../../../src/libraries/JBConstants.sol";
import {JBFees} from "../../../../src/libraries/JBFees.sol";
import {JBAccountingContext} from "../../../../src/structs/JBAccountingContext.sol";
import {JBSplit} from "../../../../src/structs/JBSplit.sol";
import {JBSplitHookContext} from "../../../../src/structs/JBSplitHookContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {JBMultiTerminalSetup} from "./JBMultiTerminalSetup.sol";

/// @notice A mintable ERC20 used to give the terminal real token state so balance-delta math is exercised.
contract MockUSDC is ERC20 {
    uint8 internal _dec;

    constructor(uint8 decimals_) ERC20("MockUSDC", "USDC") {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A split hook that pulls a configurable percentage of its ERC-20 allowance and returns successfully.
/// @dev Models a hook that consumes some-but-not-all of what the terminal offered. The ETH path is symmetric:
/// it accepts `msg.value` and optionally returns part via low-level call (configurable per test).
contract MockPartialPullSplitHook is IJBSplitHook {
    /// @dev Pull `consumeNumerator / consumeDenominator` of the offered amount.
    uint256 public consumeNumerator;
    uint256 public consumeDenominator;
    /// @dev If true, `processSplitWith` reverts unconditionally (covers the "hook reverted" partial-pull edge case).
    bool public shouldRevert;

    constructor(uint256 numerator, uint256 denominator) {
        consumeNumerator = numerator;
        consumeDenominator = denominator;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        if (shouldRevert) revert("partial-pull hook reverted");
        uint256 toConsume = (context.amount * consumeNumerator) / consumeDenominator;
        if (context.token == JBConstants.NATIVE_TOKEN) {
            // ETH path: msg.value already arrived. Send back the un-consumed portion to the caller (the terminal).
            uint256 toReturn = msg.value - toConsume;
            if (toReturn != 0) {
                (bool ok,) = msg.sender.call{value: toReturn}("");
                require(ok, "return failed");
            }
        } else {
            if (toConsume != 0) {
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(context.token).transferFrom(msg.sender, address(this), toConsume);
            }
        }
    }

    receive() external payable {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Coverage for the partial-pull paths added to `JBMultiTerminal.executePayout` via
/// `JBPayoutSplitGroupLib.invokeSplitHookWithPartial`.
contract TestExecutePayoutPartialPull_Local is JBMultiTerminalSetup {
    uint64 _noProject = 0;
    uint48 _lockedUntil = 0;
    uint256 _defaultAmount = 1e18;
    uint256 _fee = 25; // 2.5%
    address payable _noBene = payable(address(0));
    address _native = JBConstants.NATIVE_TOKEN;

    function setUp() public {
        super.multiTerminalSetup();
    }

    /// @notice ERC-20 partial pull (50%): hook keeps half of net, the unconsumed portion (plus its share of the fee
    /// allocation) routes back to the project balance, and `feeEligibleAmount` scales to consumed.
    function test_executePayout_erc20_partialPull50_routesProportionalRefundAndFee() external {
        MockUSDC usdc = new MockUSDC(6);
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 1, denominator: 2});

        // Terminal already holds the gross — recordPayoutFor drew it from the project balance upstream.
        uint256 grossAmount = 100e6;
        usdc.mint(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: false, token: address(usdc), decimals: 6});

        // Compute expected values.
        uint256 fee = JBFees.feeAmountFrom({amountBeforeFee: grossAmount, feePercent: _fee});
        uint256 netOffered = grossAmount - fee;
        uint256 expectedConsumed = netOffered / 2;
        uint256 expectedRefund = (grossAmount * (netOffered - expectedConsumed)) / netOffered;
        uint256 expectedFeeEligible = (grossAmount * expectedConsumed) / netOffered;

        // The library will route the unconsumed portion (including proportional fee allocation) back to the project.
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_noProject, address(usdc), expectedRefund)),
            ""
        );

        JBSplit memory splitMem = _splitMem(address(hook));

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: splitMem,
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(usdc.balanceOf(address(hook)), expectedConsumed, "hook keeps the consumed amount");
        assertEq(usdc.balanceOf(address(_terminal)), grossAmount - expectedConsumed, "unconsumed stays in terminal");
        assertEq(usdc.allowance(address(_terminal), address(hook)), 0, "allowance fully revoked after partial pull");
        assertEq(sent, expectedConsumed, "sent reflects consumed amount");
        assertEq(feeEligible, expectedFeeEligible, "feeEligible scales with consumed");

        // Conservation: refund + feeEligible should equal grossAmount within 1 wei of rounding tolerance.
        assertLe(grossAmount - (expectedRefund + expectedFeeEligible), 1, "conservation within rounding");
    }

    /// @notice ERC-20 zero pull (hook returned without taking anything): full gross refunds to project, no fee held.
    function test_executePayout_erc20_zeroPull_refundsFullGrossNoFee() external {
        MockUSDC usdc = new MockUSDC(6);
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 0, denominator: 1});

        uint256 grossAmount = 100e6;
        usdc.mint(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: false, token: address(usdc), decimals: 6});

        // With consumed = 0, the proportional refund collapses to the full gross.
        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_noProject, address(usdc), grossAmount)),
            ""
        );

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(usdc.balanceOf(address(hook)), 0, "hook got nothing");
        assertEq(sent, 0, "sent = 0 on zero pull");
        assertEq(feeEligible, 0, "no fee held when hook took nothing");
    }

    /// @notice ERC-20 full pull (hook takes the entire offered net): no refund, fee held on the full gross.
    function test_executePayout_erc20_fullPull_noRefundFullFee() external {
        MockUSDC usdc = new MockUSDC(6);
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 1, denominator: 1});

        uint256 grossAmount = 100e6;
        usdc.mint(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: false, token: address(usdc), decimals: 6});

        uint256 fee = JBFees.feeAmountFrom({amountBeforeFee: grossAmount, feePercent: _fee});
        uint256 netOffered = grossAmount - fee;

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(usdc.balanceOf(address(hook)), netOffered, "hook keeps full net");
        assertEq(sent, netOffered, "sent == netOffered on full pull");
        assertEq(feeEligible, grossAmount, "feeEligible == grossAmount on full pull");
    }

    /// @notice ERC-20 reverting hook (partial-pull infrastructure must handle the revert): full gross refunds,
    /// no tokens left at the hook, no fee held.
    function test_executePayout_erc20_revertingHook_refundsFullGrossNoFee() external {
        MockUSDC usdc = new MockUSDC(6);
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 1, denominator: 2});
        hook.setRevert(true);

        uint256 grossAmount = 100e6;
        usdc.mint(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: false, token: address(usdc), decimals: 6});

        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_noProject, address(usdc), grossAmount)),
            ""
        );

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(usdc.balanceOf(address(hook)), 0, "reverting hook got nothing");
        assertEq(usdc.allowance(address(_terminal), address(hook)), 0, "allowance revoked even after revert");
        assertEq(sent, 0, "sent = 0 on revert");
        assertEq(feeEligible, 0, "no fee held on revert");
    }

    /// @notice ETH split-hook revert: hook receives `msg.value` and reverts; ETH transfer is rolled back in the
    /// same frame, library's catch fires, balance-delta is zero, full gross refunds to the project, no fee held.
    /// @dev ETH partial-keep is not a meaningful primitive on this terminal because `JBMultiTerminal` has no
    /// `receive()` — a hook cannot send the unconsumed portion back. Balance-delta on ETH therefore only ever
    /// resolves to `0` (revert) or `netOffered` (full success). For genuine partial-consumption semantics use an
    /// ERC-20 token where the allowance pattern enables short-pulls.
    function test_executePayout_eth_revertingHook_refundsFullGrossNoFee() external {
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 1, denominator: 2});
        hook.setRevert(true);

        uint256 grossAmount = _defaultAmount;
        vm.deal(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: false, token: _native, decimals: 0});

        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_noProject, _native, grossAmount)),
            ""
        );

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: _native,
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(address(hook).balance, 0, "reverting hook gets no ETH");
        assertEq(address(_terminal).balance, grossAmount, "ETH stays in terminal on revert");
        assertEq(sent, 0, "sent = 0 on ETH revert");
        assertEq(feeEligible, 0, "no fee held on ETH revert");
    }

    /// @notice ETH split-hook full success: hook accepts `msg.value` (net of fee) and keeps it all. The
    /// terminal's ETH balance drops by the offered net amount; `sent` equals net, `feeEligibleAmount` equals
    /// gross (full fee on the project's payout intent).
    function test_executePayout_eth_fullKeep_noRefundFullFee() external {
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 1, denominator: 1});

        uint256 grossAmount = _defaultAmount;
        vm.deal(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: false, token: _native, decimals: 0});

        uint256 fee = JBFees.feeAmountFrom({amountBeforeFee: grossAmount, feePercent: _fee});
        uint256 netOffered = grossAmount - fee;

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: _native,
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(address(hook).balance, netOffered, "hook kept the full net amount");
        assertEq(address(_terminal).balance, grossAmount - netOffered, "terminal retained the fee allocation");
        assertEq(sent, netOffered, "sent == netOffered on full ETH keep");
        assertEq(feeEligible, grossAmount, "feeEligible == grossAmount on full keep");
    }

    /// @notice Feeless split + partial pull: the unconsumed portion refunds but no fee is ever charged regardless
    /// of consumption level. `feeEligibleAmount` stays zero because `netPayoutAmount == amount` for feeless splits.
    function test_executePayout_erc20_feelessSplitPartialPull_noFee() external {
        MockUSDC usdc = new MockUSDC(6);
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: 1, denominator: 4});

        uint256 grossAmount = 100e6;
        usdc.mint(address(_terminal), grossAmount);

        _wireMocks({hook: address(hook), feeless: true, token: address(usdc), decimals: 6});

        // Feeless: netOffered == grossAmount, so consumed = 25% of gross = 25e6.
        uint256 expectedConsumed = grossAmount / 4;
        uint256 expectedRefund = grossAmount - expectedConsumed;

        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_noProject, address(usdc), expectedRefund)),
            ""
        );

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(usdc.balanceOf(address(hook)), expectedConsumed, "hook keeps consumed for feeless split");
        assertEq(sent, expectedConsumed, "sent reflects consumed amount");
        assertEq(feeEligible, 0, "no fee on feeless splits regardless of consumption");
    }

    // ────────────────────────────────────────────────────────────────────────────────
    //                                  FUZZ TESTS
    // ────────────────────────────────────────────────────────────────────────────────

    /// @notice Conservation invariant: for any consumption ratio of any amount, `consumed + refund + held_fee`
    /// must equal `amount` modulo the integer-rounding dust (≤ 1 wei in either direction).
    /// @dev Iterates the math externally and compares against `executePayout`'s returned (sent, feeEligibleAmount)
    /// plus the routed refund. The held fee on `feeEligibleAmount` later equals `_feeAmountFrom(feeEligibleAmount)`.
    function testFuzz_executePayout_erc20_conservationAcrossConsumptionRatios(
        uint256 grossAmount,
        uint16 consumeBasisPoints
    )
        external
    {
        // Bound to realistic, non-degenerate amounts: 1k to 1e30 (covers USDC dust through stretched-decimal cases).
        grossAmount = bound(grossAmount, 1e3, 1e30);
        // Bound consume ratio to [0, 10000] basis points (0% to 100%).
        uint256 consumeBps = bound(uint256(consumeBasisPoints), 0, 10_000);

        MockUSDC usdc = new MockUSDC(6);
        MockPartialPullSplitHook hook = new MockPartialPullSplitHook({numerator: consumeBps, denominator: 10_000});

        usdc.mint(address(_terminal), grossAmount);
        _wireMocks({hook: address(hook), feeless: false, token: address(usdc), decimals: 6});

        // Make recordAddedBalanceFor a no-op for any input (we'll verify amounts via balances + return values).
        vm.mockCall(address(store), abi.encodeWithSelector(IJBTerminalStore.recordAddedBalanceFor.selector), "");

        uint256 fee = JBFees.feeAmountFrom({amountBeforeFee: grossAmount, feePercent: _fee});
        uint256 netOffered = grossAmount - fee;

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        // Hook can never receive more than netOffered (the allowance cap).
        assertLe(sent, netOffered, "sent capped by netOffered");
        // The hook's USDC balance equals the consumed amount we observed.
        assertEq(usdc.balanceOf(address(hook)), sent, "hook balance == sent");

        // feeEligibleAmount must scale linearly with consumed: feeEligible / sent ≈ amount / netOffered.
        if (sent != 0) {
            // feeEligible is computed via mulDiv(grossAmount, sent, netOffered).
            uint256 expectedFeeEligible = (grossAmount * sent) / netOffered;
            assertEq(feeEligible, expectedFeeEligible, "feeEligible == amount * sent / netOffered");
        } else {
            assertEq(feeEligible, 0, "feeEligible = 0 when consumed = 0");
        }

        // Conservation: consumed + held-fee-base-equiv-of-consumed + refund-portion ≈ grossAmount.
        // refund + feeEligible should equal grossAmount within 1 wei of rounding.
        uint256 expectedRefund = sent == netOffered ? 0 : (grossAmount * (netOffered - sent)) / netOffered;
        uint256 reconstructed = expectedRefund + feeEligible;
        // Allow up to 1 wei rounding loss in each direction (two floor() operations).
        assertLe(reconstructed, grossAmount, "reconstruction never exceeds gross");
        assertGe(reconstructed + 2, grossAmount, "reconstruction within 2 wei of gross");
    }

    /// @notice Edge case: minimum partial pull (1 wei of net). Verifies tiny consumption is handled without
    /// over- or under-counting in the fee math.
    function test_executePayout_erc20_minimumPartialPull_oneWei() external {
        MockUSDC usdc = new MockUSDC(6);
        // Use a custom hook that pulls exactly 1 wei regardless of allowance.
        MockOneWeiPullSplitHook hook = new MockOneWeiPullSplitHook();

        uint256 grossAmount = 100e6;
        usdc.mint(address(_terminal), grossAmount);
        _wireMocks({hook: address(hook), feeless: false, token: address(usdc), decimals: 6});

        uint256 fee = JBFees.feeAmountFrom({amountBeforeFee: grossAmount, feePercent: _fee});
        uint256 netOffered = grossAmount - fee;
        uint256 expectedRefund = (grossAmount * (netOffered - 1)) / netOffered;
        uint256 expectedFeeEligible = grossAmount / netOffered; // amount * 1 / netOffered, which floors to either 1 or
        // 0
        if ((grossAmount * 1) % netOffered != 0) {
            // mulDiv floors, so the expected may be amount/netOffered which for 100e6 / 97.5e6 = 1
        }
        // For our concrete numbers: grossAmount = 100e6, netOffered = 97.5e6, expectedFeeEligible = floor(100e6/97.5e6)
        // = 1.
        assertEq(expectedFeeEligible, 1, "sanity: feeEligible for 1 wei consumed");

        mockExpect(
            address(store),
            abi.encodeCall(IJBTerminalStore.recordAddedBalanceFor, (_noProject, address(usdc), expectedRefund)),
            ""
        );

        vm.prank(address(_terminal));
        (uint256 sent, uint256 feeEligible) = JBMultiTerminal(address(_terminal))
            .executePayout({
            split: _splitMem(address(hook)),
            projectId: _noProject,
            token: address(usdc),
            amount: grossAmount,
            originalMessageSender: address(this)
        });

        assertEq(sent, 1, "sent == 1 wei");
        assertEq(feeEligible, expectedFeeEligible, "feeEligible matches mulDiv on 1-wei consumption");
        assertEq(usdc.balanceOf(address(hook)), 1, "hook keeps 1 wei");
    }

    // ────────────────────────────────────────────────────────────────────────────────
    //                                  HELPERS
    // ────────────────────────────────────────────────────────────────────────────────

    function _wireMocks(address hook, bool feeless, address token, uint8 decimals) internal {
        // Hook claims to support IJBSplitHook.
        vm.mockCall(hook, abi.encodeCall(IERC165.supportsInterface, (type(IJBSplitHook).interfaceId)), abi.encode(true));
        // Feelessness lookup.
        vm.mockCall(
            address(feelessAddresses),
            feelessCalldata(hook, _noProject, address(_terminal)),
            abi.encode(feeless)
        );
        // Library needs decimals to build the hook context.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currency = token == _native ? uint32(uint160(_native)) : uint32(uint160(token));
        vm.mockCall(
            address(store),
            abi.encodeCall(IJBTerminalStore.accountingContextOf, (address(_terminal), _noProject, token)),
            abi.encode(JBAccountingContext({token: token, decimals: decimals, currency: currency}))
        );
    }

    function _splitMem(address hook) internal view returns (JBSplit memory) {
        return JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: _noProject,
            beneficiary: _noBene,
            lockedUntil: _lockedUntil,
            hook: IJBSplitHook(hook)
        });
    }
}

/// @notice Helper hook that pulls exactly 1 wei of its ERC-20 allowance. Models the minimum-non-zero partial pull.
contract MockOneWeiPullSplitHook is IJBSplitHook {
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        if (context.token != JBConstants.NATIVE_TOKEN) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(context.token).transferFrom(msg.sender, address(this), 1);
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
