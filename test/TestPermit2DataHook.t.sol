// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import {TestBaseWorkflow} from "./helpers/TestBaseWorkflow.sol";
import {MetadataResolverHelper} from "./helpers/MetadataResolverHelper.sol";
import {IJBController} from "../src/interfaces/IJBController.sol";
import {IJBPrices} from "../src/interfaces/IJBPrices.sol";
import {IJBRulesetApprovalHook} from "../src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "../src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "../src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "../src/interfaces/IJBTokens.sol";
import {JBConstants} from "../src/libraries/JBConstants.sol";
import {JBAccountingContext} from "../src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "../src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "../src/structs/JBPayHookSpecification.sol";
import {JBRulesetConfig} from "../src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "../src/structs/JBRulesetMetadata.sol";
import {JBSingleAllowance} from "../src/structs/JBSingleAllowance.sol";
import {JBSplitGroup} from "../src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "../src/structs/JBTerminalConfig.sol";
import {IAllowanceTransfer, IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Tests combining Permit2 ERC-20 transfers with data hook weight overrides.
contract TestPermit2DataHook_Local is TestBaseWorkflow {
    uint112 private constant _WEIGHT = uint112(1000 * 10 ** 18);
    address private constant _DATA_HOOK = address(bytes20(keccak256("permit2datahook")));

    IJBController private _controller;
    IJBTerminal private _terminal;
    IJBPrices private _prices;
    IJBTokens private _tokens;
    IERC20 private _usdc;
    IPermit2 private _permit2;
    MetadataResolverHelper private _helper;
    address private _projectOwner;

    uint256 _projectId;

    // Permit2 params.
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DOMAIN_SEPARATOR;
    address from;
    uint256 fromPrivateKey;

    // Price.
    uint256 _nativePricePerUsd = 0.0005 * 10 ** 18; // 1/2000

    function setUp() public override {
        super.setUp();

        vm.label(_DATA_HOOK, "Data Hook");

        _controller = jbController();
        _projectOwner = multisig();
        _terminal = jbMultiTerminal();
        _prices = jbPrices();
        _tokens = jbTokens();
        _helper = metadataHelper();
        _usdc = usdcToken();
        _permit2 = permit2();

        fromPrivateKey = 0x12341234;
        from = vm.addr(fromPrivateKey);
        DOMAIN_SEPARATOR = permit2().DOMAIN_SEPARATOR();

        // First project: fee collector with data hook disabled.
        JBRulesetMetadata memory _feeMetadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
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
            allowAddPriceFeed: true,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory _feeRulesetConfig = new JBRulesetConfig[](1);
        _feeRulesetConfig[0].mustStartAtOrAfter = 0;
        _feeRulesetConfig[0].duration = 0;
        _feeRulesetConfig[0].weight = _WEIGHT;
        _feeRulesetConfig[0].weightCutPercent = 0;
        _feeRulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _feeRulesetConfig[0].metadata = _feeMetadata;
        _feeRulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _feeRulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](2);
        _tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        _tokensToAccept[1] = JBAccountingContext({
            token: address(usdcToken()), decimals: 6, currency: uint32(uint160(address(usdcToken())))
        });
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextsToAccept: _tokensToAccept});

        // Create fee project (project ID 1).
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "feeProject",
            rulesetConfigurations: _feeRulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        // Second project: data hook enabled for pay, uses USDC via Permit2.
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
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
            allowAddPriceFeed: true,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: _DATA_HOOK,
            metadata: 0
        });

        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = _WEIGHT;
        _rulesetConfig[0].weightCutPercent = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectUri: "permit2DataHookProject",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        vm.startPrank(_projectOwner);
        MockPriceFeed _priceFeedNativeUsd = new MockPriceFeed(_nativePricePerUsd, 18);
        vm.label(address(_priceFeedNativeUsd), "Mock Price Feed Native-USD");

        _controller.addPriceFeedFor({
            projectId: _projectId,
            pricingCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            unitCurrency: uint32(uint160(address(usdcToken()))),
            feed: _priceFeedNativeUsd
        });

        vm.stopPrank();
    }

    /// @notice Builds Permit2 metadata for the given coin amount and nonce.
    function _buildPermit2Metadata(uint256 coins, uint48 nonce) internal view returns (bytes memory packedData) {
        uint256 deadline = block.timestamp + 1 days;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 expiration = uint48(block.timestamp + 1 days);

        IAllowanceTransfer.PermitDetails memory details = IAllowanceTransfer.PermitDetails({
            token: address(_usdc),
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(coins),
            expiration: expiration,
            nonce: nonce
        });

        IAllowanceTransfer.PermitSingle memory permitSingle =
            IAllowanceTransfer.PermitSingle({details: details, spender: address(_terminal), sigDeadline: deadline});

        bytes memory sig = getPermitSignature(permitSingle, fromPrivateKey, DOMAIN_SEPARATOR);

        JBSingleAllowance memory permitData = JBSingleAllowance({
            sigDeadline: deadline,
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(coins),
            expiration: expiration,
            nonce: nonce,
            signature: sig
        });

        bytes4[] memory ids = new bytes4[](1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encode(permitData);
        ids[0] = _helper.getId("permit2", address(_terminal));

        packedData = _helper.createMetadata(ids, datas);
    }

    /// @notice Pay via Permit2 with a data hook that returns the original weight -- tokens should match normal
    /// issuance.
    function test_permit2_withDataHook_paySucceeds() public {
        uint256 _coins = 1_000_000; // 1 USDC (6 decimals)

        // Data hook returns the original weight and empty hook specifications.
        JBPayHookSpecification[] memory _emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(_WEIGHT), _emptySpecs)
        );

        // Build Permit2 metadata.
        bytes memory _packedData = _buildPermit2Metadata(_coins, 0);

        // Setup: give coins and approve permit2 contract.
        deal(address(_usdc), from, _coins);
        vm.prank(from);
        IERC20(address(_usdc)).approve(address(permit2()), _coins);

        // Pay using Permit2 with data hook.
        vm.prank(from);
        uint256 _minted = _terminal.pay({
            projectId: _projectId,
            amount: _coins,
            token: address(_usdc),
            beneficiary: from,
            minReturnedTokens: 0,
            memo: "Permit2 + data hook",
            metadata: _packedData
        });

        // Check: tokens were transferred.
        assertEq(_usdc.balanceOf(address(_terminal)), _coins, "terminal should hold the USDC");

        // Check: payer receives project tokens.
        assertEq(_tokens.totalBalanceOf(from, _projectId), _minted, "payer should have minted tokens");

        // Check: minted amount matches expected calculation.
        // The baseCurrency is NATIVE_TOKEN (ETH), so USDC amounts get converted via price feed.
        // 1 USDC = 0.0005 ETH (from _nativePricePerUsd). So 1e6 USDC = 0.0005e18 = 5e14 ETH.
        // Token count = ethEquivalent * weight / 10^18
        // ethEquivalent = _coins * 10^12 (6->18 decimals) * _nativePricePerUsd / 10^18
        uint256 adjustedAmount = _coins * 10 ** 12; // adjust from 6 to 18 decimals
        uint256 ethEquivalent = mulDiv(adjustedAmount, _nativePricePerUsd, 10 ** 18);
        uint256 expectedTokens = mulDiv(ethEquivalent, _WEIGHT, 10 ** 18);
        assertEq(_minted, expectedTokens, "minted tokens should match weight calculation");
    }

    /// @notice Pay via Permit2 with a data hook that modifies the weight (2x) -- tokens should reflect the modified
    /// weight.
    function test_permit2_withDataHook_hookModifiesWeight() public {
        uint256 _coins = 500_000; // 0.5 USDC (6 decimals)

        // Data hook returns 2x the original weight.
        uint256 _modifiedWeight = uint256(_WEIGHT) * 2;
        JBPayHookSpecification[] memory _emptySpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(_modifiedWeight, _emptySpecs)
        );

        // Build Permit2 metadata.
        bytes memory _packedData = _buildPermit2Metadata(_coins, 0);

        // Setup: give coins and approve permit2 contract.
        deal(address(_usdc), from, _coins);
        vm.prank(from);
        IERC20(address(_usdc)).approve(address(permit2()), _coins);

        // Pay using Permit2 with data hook.
        vm.prank(from);
        uint256 _minted = _terminal.pay({
            projectId: _projectId,
            amount: _coins,
            token: address(_usdc),
            beneficiary: from,
            minReturnedTokens: 0,
            memo: "Permit2 + modified weight",
            metadata: _packedData
        });

        // Check: correct ERC-20 amount transferred via Permit2.
        assertEq(_usdc.balanceOf(address(_terminal)), _coins, "terminal should hold the USDC");

        // Check: tokens minted matches the MODIFIED weight (2x), not the original.
        // USDC amounts are converted to ETH via price feed before token calculation.
        // 500_000 USDC (0.5 USDC) = 0.00025 ETH = 2.5e14 at 18 decimals.
        // Token count = ethEquivalent * modifiedWeight / 10^18
        uint256 adjustedAmount = _coins * 10 ** 12; // adjust from 6 to 18 decimals
        uint256 ethEquivalent = mulDiv(adjustedAmount, _nativePricePerUsd, 10 ** 18);
        uint256 expectedTokens = mulDiv(ethEquivalent, _modifiedWeight, 10 ** 18);
        assertEq(_minted, expectedTokens, "minted tokens should match 2x modified weight");

        // Check: payer balance matches.
        assertEq(_tokens.totalBalanceOf(from, _projectId), _minted, "payer should have all minted tokens");
    }

    /// Permit2 signature helpers.
    /// (required because `permit2/test/utils/PermitSignature.sol` imports `draft-EIP712.sol` which is no longer a
    /// draft.)

    bytes32 public constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

    bytes32 public constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    function getPermitSignatureRaw(
        IAllowanceTransfer.PermitSingle memory permitSingle,
        uint256 privateKey,
        bytes32 domainSeparator
    )
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permitSingle.details));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(_PERMIT_SINGLE_TYPEHASH, permitHash, permitSingle.spender, permitSingle.sigDeadline)
                )
            )
        );

        (v, r, s) = vm.sign(privateKey, msgHash);
    }

    function getPermitSignature(
        IAllowanceTransfer.PermitSingle memory permitSingle,
        uint256 privateKey,
        bytes32 domainSeparator
    )
        internal
        pure
        returns (bytes memory sig)
    {
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignatureRaw(permitSingle, privateKey, domainSeparator);
        return bytes.concat(r, s, bytes1(v));
    }
}
