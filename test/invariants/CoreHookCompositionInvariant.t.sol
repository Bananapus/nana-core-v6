// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "../../src/interfaces/IJBTerminalStore.sol";
import {IJBToken} from "../../src/interfaces/IJBToken.sol";
import {IJBTokens} from "../../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "../../src/structs/JBSplit.sol";
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "../../src/structs/JBSplitHookContext.sol";
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
import {TestBaseWorkflow} from "../helpers/TestBaseWorkflow.sol";

/// @notice Split hook used by the invariant model to exercise a real hook callback into `pay(...)`.
/// @dev The hook immediately forwards any native payout it receives into a target project. This models the
/// callback shape used by downstream split hooks while keeping the invariant surface small and deterministic.
contract ReentrantPaySplitHook is ERC165, IJBSplitHook {
    IJBMultiTerminal public immutable TERMINAL;
    uint256 public immutable TARGET_PROJECT_ID;

    uint256 public reentrantPayCount;
    uint256 public totalForwarded;
    uint256 public totalTokensMinted;

    constructor(IJBMultiTerminal terminal, uint256 targetProjectId) {
        TERMINAL = terminal;
        TARGET_PROJECT_ID = targetProjectId;
    }

    /// @notice Processes a payout split by paying the received native token into the target project.
    /// @dev The invariant intentionally re-enters the terminal from inside split processing so ledger assertions
    /// cover nested hook execution, not just straight-line `sendPayoutsOf(...)`.
    /// @param context The split context, used to prove the terminal offered native-token value to this hook.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        if (msg.value == 0) return;
        require(context.token == JBConstants.NATIVE_TOKEN, "ONLY_NATIVE");

        totalForwarded += msg.value;
        uint256 tokenCount = TERMINAL.pay{value: msg.value}({
            projectId: TARGET_PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: msg.value,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "invariant split hook pay",
            metadata: new bytes(0)
        });

        totalTokensMinted += tokenCount;
        reentrantPayCount++;
    }

    /// @notice Supports the split hook interface used by terminal payout processing.
    /// @param interfaceId The queried interface id.
    /// @return True for `IJBSplitHook` and inherited ERC-165 support.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface({interfaceId: interfaceId});
    }

    receive() external payable {}
}

/// @notice Handler for the core hook-composition invariant.
/// @dev Operations are intentionally few: payments create origin balance, payouts exercise the split hook callback,
/// and target cashouts prove the hook-minted supply remains redeemable only against real terminal backing.
contract CoreHookCompositionHandler is Test {
    IJBMultiTerminal public immutable terminal;
    IJBTerminalStore public immutable store;
    IJBTokens public immutable tokens;
    ReentrantPaySplitHook public immutable hook;

    uint256 public immutable feeProjectId;
    uint256 public immutable originProjectId;
    uint256 public immutable targetProjectId;
    address public immutable projectOwner;

    uint256 public callCountPayOrigin;
    uint256 public callCountSendPayouts;
    uint256 public callCountCashOutTarget;

    constructor(
        IJBMultiTerminal terminal_,
        IJBTerminalStore store_,
        IJBTokens tokens_,
        ReentrantPaySplitHook hook_,
        uint256 feeProjectId_,
        uint256 originProjectId_,
        uint256 targetProjectId_,
        address projectOwner_
    ) {
        terminal = terminal_;
        store = store_;
        tokens = tokens_;
        hook = hook_;
        feeProjectId = feeProjectId_;
        originProjectId = originProjectId_;
        targetProjectId = targetProjectId_;
        projectOwner = projectOwner_;
    }

    /// @notice Pays the origin project so later payout processing has balance to route through the split hook.
    /// @param amount The fuzzed native-token amount.
    function payOrigin(uint256 amount) public {
        amount = bound({x: amount, min: 0.01 ether, max: 20 ether});

        vm.deal({account: address(this), newBalance: amount});
        terminal.pay{value: amount}({
            projectId: originProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "invariant origin pay",
            metadata: new bytes(0)
        });

        callCountPayOrigin++;
    }

    /// @notice Sends origin payouts through the configured split hook.
    /// @param amount The fuzzed payout amount.
    function sendOriginPayouts(uint256 amount) public {
        uint256 balance =
            store.balanceOf({terminal: address(terminal), projectId: originProjectId, token: JBConstants.NATIVE_TOKEN});
        if (balance == 0) return;

        amount = bound({x: amount, min: 1, max: balance});

        vm.prank(projectOwner);
        try terminal.sendPayoutsOf({
            projectId: originProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0,
            referralProjectId: 0
        }) {
            callCountSendPayouts++;
        } catch {}
    }

    /// @notice Cashes out some of the target-project tokens minted to the split hook.
    /// @param cashOutPercent The percentage of the hook's target-project balance to cash out.
    function cashOutTargetFromHook(uint256 cashOutPercent) public {
        uint256 tokenBalance = tokens.totalBalanceOf({holder: address(hook), projectId: targetProjectId});
        if (tokenBalance == 0) return;

        cashOutPercent = bound({x: cashOutPercent, min: 1, max: 100});
        uint256 cashOutCount = (tokenBalance * cashOutPercent) / 100;
        if (cashOutCount == 0) return;

        vm.prank(address(hook));
        try terminal.cashOutTokensOf({
            holder: address(hook),
            projectId: targetProjectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(hook)),
            metadata: new bytes(0),
            referralProjectId: 0
        }) {
            callCountCashOutTarget++;
        } catch {}
    }
}

/// @notice Shared setup for the core hook-composition invariant and direct handler sanity tests.
abstract contract CoreHookCompositionSetup is TestBaseWorkflow {
    uint256 internal constant _FEE_PROJECT_ID = 1;

    CoreHookCompositionHandler public handler;
    ReentrantPaySplitHook public hook;

    uint256 public originProjectId;
    uint256 public targetProjectId;
    address public projectOwner;

    function setUp() public virtual override {
        super.setUp();

        projectOwner = multisig();

        uint256 feeProjectId = _launchProject({splits: new JBSplit[](0), payoutLimit: 0});
        assertEq({left: feeProjectId, right: _FEE_PROJECT_ID, err: "fee project must be first"});

        targetProjectId = _launchProject({splits: new JBSplit[](0), payoutLimit: 0});
        hook = new ReentrantPaySplitHook({terminal: jbMultiTerminal(), targetProjectId: targetProjectId});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(address(hook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(hook))
        });
        originProjectId = _launchProject({splits: splits, payoutLimit: 100 ether});

        handler = new CoreHookCompositionHandler({
            terminal_: jbMultiTerminal(),
            store_: jbTerminalStore(),
            tokens_: jbTokens(),
            hook_: hook,
            feeProjectId_: _FEE_PROJECT_ID,
            originProjectId_: originProjectId,
            targetProjectId_: targetProjectId,
            projectOwner_: projectOwner
        });
    }

    function _assertTokenSupplyConsistencyOf(uint256 projectId) internal view {
        uint256 totalSupply = jbTokens().totalSupplyOf(projectId);
        uint256 creditSupply = jbTokens().totalCreditSupplyOf(projectId);

        IJBToken token = jbTokens().tokenOf(projectId);
        uint256 erc20Supply = address(token) == address(0) ? 0 : token.totalSupply();

        assertEq({left: totalSupply, right: creditSupply + erc20Supply, err: "HOOKCOMP: total supply mismatch"});
    }

    function _launchProject(JBSplit[] memory splits, uint256 payoutLimit) internal returns (uint256 projectId) {
        projectId = jbController()
            .launchProjectFor({
            owner: projectOwner,
            projectUri: "core-hook-composition",
            rulesetConfigurations: _rulesetConfig({splits: splits, payoutLimit: payoutLimit}),
            terminalConfigurations: _terminalConfig(),
            memo: ""
        });
    }

    function _recordedBalanceOf(uint256 projectId) internal view returns (uint256) {
        return jbTerminalStore()
            .balanceOf({terminal: address(jbMultiTerminal()), projectId: projectId, token: JBConstants.NATIVE_TOKEN});
    }

    function _rulesetConfig(
        JBSplit[] memory splits,
        uint256 payoutLimit
    )
        internal
        view
        returns (JBRulesetConfig[] memory rulesetConfig)
    {
        rulesetConfig = new JBRulesetConfig[](1);
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

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        rulesetConfig[0].splitGroups = splitGroups;

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBCurrencyAmount({amount: uint224(payoutLimit), currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal()),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });
        rulesetConfig[0].fundAccessLimitGroups = fundAccessLimitGroups;
    }

    function _terminalConfig() internal view returns (JBTerminalConfig[] memory terminalConfigurations) {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});
    }
}

/// @notice Composed invariant for terminal/store/controller/ruleset/split-hook callback accounting.
contract CoreHookCompositionInvariant_Local is StdInvariant, CoreHookCompositionSetup {
    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CoreHookCompositionHandler.payOrigin.selector;
        selectors[1] = CoreHookCompositionHandler.sendOriginPayouts.selector;
        selectors[2] = CoreHookCompositionHandler.cashOutTargetFromHook.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Composed accounting checks for the split-hook callback path.
    /// @dev Keep these assertions in one public invariant so Foundry replays one handler campaign while still checking
    /// terminal backing plus origin/target token supply consistency after every sequence.
    function invariant_HOOKCOMP_hookCompositionAccounting() public view {
        _assertTerminalBackingCoversRecordedBalances();
        _assertTokenSupplyConsistencyOf({projectId: targetProjectId});
        _assertTokenSupplyConsistencyOf({projectId: originProjectId});
    }

    /// @notice Terminal ETH backing must cover every project balance touched by the hook-composition model.
    function _assertTerminalBackingCoversRecordedBalances() private view {
        uint256 recordedTotal = _recordedBalanceOf(_FEE_PROJECT_ID) + _recordedBalanceOf(originProjectId)
            + _recordedBalanceOf(targetProjectId);

        assertGe({
            left: address(jbMultiTerminal()).balance,
            right: recordedTotal,
            err: "HOOKCOMP1: terminal backing must cover fee/origin/target balances"
        });
    }
}

/// @notice Direct sanity checks that the invariant handler reaches the hook callback path.
contract CoreHookCompositionHandlerSanity is CoreHookCompositionSetup {
    function test_handler_sendPayouts_reachesReentrantHook() public {
        handler.payOrigin({amount: 10 ether});

        uint256 hookPayCountBefore = hook.reentrantPayCount();
        handler.sendOriginPayouts({amount: 5 ether});

        assertGt({left: handler.callCountSendPayouts(), right: 0, err: "handler must send a payout"});
        assertGt({left: hook.reentrantPayCount(), right: hookPayCountBefore, err: "split hook must reenter pay"});
        assertGt({left: hook.totalTokensMinted(), right: 0, err: "hook reentrant pay must mint target tokens"});
    }

    function test_handler_cashOutTargetFromHook_movesHookMintedSupply() public {
        handler.payOrigin({amount: 10 ether});
        handler.sendOriginPayouts({amount: 5 ether});

        uint256 hookTokenBalance = jbTokens().totalBalanceOf({holder: address(hook), projectId: targetProjectId});
        assertGt({left: hookTokenBalance, right: 0, err: "hook must hold target tokens before cashout"});

        handler.cashOutTargetFromHook({cashOutPercent: 100});

        assertGt({
            left: handler.callCountCashOutTarget(), right: 0, err: "handler must cash out hook-minted target tokens"
        });
    }
}
