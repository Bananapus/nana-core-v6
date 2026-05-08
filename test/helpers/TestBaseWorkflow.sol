// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

// forge-lint: disable-next-line(unused-import)
import {Test} from "forge-std/Test.sol";
// forge-lint: disable-next-line(unused-import)
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

// forge-lint: disable-next-line(unused-import)
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// forge-lint: disable-next-line(unused-import)
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
// forge-lint: disable-next-line(unused-import)
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// forge-lint: disable-next-line(unused-import)
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
// forge-lint: disable-next-line(unused-import)
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
// forge-lint: disable-next-line(unused-import)
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// forge-lint: disable-next-line(unused-import)
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// forge-lint: disable-next-line(unused-import)
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
// forge-lint: disable-next-line(unused-import)
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
// forge-lint: disable-next-line(unused-import)
import {JBControlled} from "../../src/abstract/JBControlled.sol";
// forge-lint: disable-next-line(unused-import)
import {JBPermissioned} from "../../src/abstract/JBPermissioned.sol";
import {JBController} from "../../src/JBController.sol";
import {JBDirectory} from "../../src/JBDirectory.sol";
import {JBTerminalStore} from "../../src/JBTerminalStore.sol";
import {JBFeelessAddresses} from "../../src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "../../src/JBFundAccessLimits.sol";
import {JBRulesets} from "../../src/JBRulesets.sol";
import {JBPermissions} from "../../src/JBPermissions.sol";
import {JBPrices} from "../../src/JBPrices.sol";
import {JBProjects} from "../../src/JBProjects.sol";
import {JBSplits} from "../../src/JBSplits.sol";
import {JBERC20} from "../../src/JBERC20.sol";
import {JBTokens} from "../../src/JBTokens.sol";
// forge-lint: disable-next-line(unused-import)
import {JBDeadline} from "../../src/JBDeadline.sol";
// forge-lint: disable-next-line(unused-import)
import {JBApprovalStatus} from "../../src/enums/JBApprovalStatus.sol";
import {JBMultiTerminal} from "../../src/JBMultiTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {JBAccountingContext} from "../../src/structs/JBAccountingContext.sol";
// forge-lint: disable-next-line(unused-import)
import {JBCurrencyAmount} from "../../src/structs/JBCurrencyAmount.sol";
// forge-lint: disable-next-line(unused-import)
import {JBAfterPayRecordedContext} from "../../src/structs/JBAfterPayRecordedContext.sol";
// forge-lint: disable-next-line(unused-import)
import {JBAfterCashOutRecordedContext} from "../../src/structs/JBAfterCashOutRecordedContext.sol";
// forge-lint: disable-next-line(unused-import)
import {JBFee} from "../../src/structs/JBFee.sol";
// forge-lint: disable-next-line(unused-import)
import {JBFees} from "../../src/libraries/JBFees.sol";
// forge-lint: disable-next-line(unused-import)
import {JBMetadataResolver} from "../../src/libraries/JBMetadataResolver.sol";
// forge-lint: disable-next-line(unused-import)
import {JBCashOuts} from "../../src/libraries/JBCashOuts.sol";
// forge-lint: disable-next-line(unused-import)
import {JBFundAccessLimitGroup} from "../../src/structs/JBFundAccessLimitGroup.sol";
// forge-lint: disable-next-line(unused-import)
import {JBRuleset} from "../../src/structs/JBRuleset.sol";
// forge-lint: disable-next-line(unused-import)
import {JBRulesetWithMetadata} from "../../src/structs/JBRulesetWithMetadata.sol";
// forge-lint: disable-next-line(unused-import)
import {JBRulesetMetadata} from "../../src/structs/JBRulesetMetadata.sol";
// forge-lint: disable-next-line(unused-import)
import {JBRulesetConfig} from "../../src/structs/JBRulesetConfig.sol";
// forge-lint: disable-next-line(unused-import)
import {JBSplitGroup} from "../../src/structs/JBSplitGroup.sol";
// forge-lint: disable-next-line(unused-import)
import {JBPermissionsData} from "../../src/structs/JBPermissionsData.sol";
// forge-lint: disable-next-line(unused-import)
import {JBBeforePayRecordedContext} from "../../src/structs/JBBeforePayRecordedContext.sol";
// forge-lint: disable-next-line(unused-import)
import {JBBeforeCashOutRecordedContext} from "../../src/structs/JBBeforeCashOutRecordedContext.sol";
// forge-lint: disable-next-line(unused-import)
import {JBSplit} from "../../src/structs/JBSplit.sol";
// forge-lint: disable-next-line(unused-import)
import {JBTerminalConfig} from "../../src/structs/JBTerminalConfig.sol";
// forge-lint: disable-next-line(unused-import)
import {JBPayHookSpecification} from "../../src/structs/JBPayHookSpecification.sol";
// forge-lint: disable-next-line(unused-import)
import {JBCashOutHookSpecification} from "../../src/structs/JBCashOutHookSpecification.sol";
// forge-lint: disable-next-line(unused-import)
import {JBTokenAmount} from "../../src/structs/JBTokenAmount.sol";
// forge-lint: disable-next-line(unused-import)
import {JBSplitHookContext} from "../../src/structs/JBSplitHookContext.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBToken} from "../../src/interfaces/IJBToken.sol";
// forge-lint: disable-next-line(unused-import)
import {JBSingleAllowance} from "../../src/structs/JBSingleAllowance.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBController} from "../../src/interfaces/IJBController.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBFeelessAddresses} from "../../src/interfaces/IJBFeelessAddresses.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBFundAccessLimits} from "../../src/interfaces/IJBFundAccessLimits.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBMigratable} from "../../src/interfaces/IJBMigratable.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPermissions} from "../../src/interfaces/IJBPermissions.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBDirectoryAccessControl} from "../../src/interfaces/IJBDirectoryAccessControl.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBTerminalStore} from "../../src/interfaces/IJBTerminalStore.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBProjects} from "../../src/interfaces/IJBProjects.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBDirectory} from "../../src/interfaces/IJBDirectory.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBRulesets} from "../../src/interfaces/IJBRulesets.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBSplits} from "../../src/interfaces/IJBSplits.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBTokenUriResolver} from "../../src/interfaces/IJBTokenUriResolver.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBTokens} from "../../src/interfaces/IJBTokens.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBSplitHook} from "../../src/interfaces/IJBSplitHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPayHook} from "../../src/interfaces/IJBPayHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBRulesetDataHook} from "../../src/interfaces/IJBRulesetDataHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBCashOutHook} from "../../src/interfaces/IJBCashOutHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBRulesetDataHook} from "../../src/interfaces/IJBRulesetDataHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBMultiTerminal} from "../../src/interfaces/IJBMultiTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBCashOutTerminal} from "../../src/interfaces/IJBCashOutTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPayoutTerminal} from "../../src/interfaces/IJBPayoutTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPermitTerminal} from "../../src/interfaces/IJBPermitTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBFeeTerminal} from "../../src/interfaces/IJBFeeTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBTerminal} from "../../src/interfaces/IJBTerminal.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPriceFeed} from "../../src/interfaces/IJBPriceFeed.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPermissioned} from "../../src/interfaces/IJBPermissioned.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBProjectUriRegistry} from "../../src/interfaces/IJBProjectUriRegistry.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBRulesetApprovalHook} from "../../src/interfaces/IJBRulesetApprovalHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPrices} from "../../src/interfaces/IJBPrices.sol";

// forge-lint: disable-next-line(unused-import)
import {JBConstants} from "../../src/libraries/JBConstants.sol";
// forge-lint: disable-next-line(unused-import)
import {JBCurrencyIds} from "../../src/libraries/JBCurrencyIds.sol";
// forge-lint: disable-next-line(unused-import)
import {JBRulesetMetadataResolver} from "../../src/libraries/JBRulesetMetadataResolver.sol";
// forge-lint: disable-next-line(unused-import)
import {JBSplitGroupIds} from "../../src/libraries/JBSplitGroupIds.sol";

// forge-lint: disable-next-line(unused-import)
import {IPermit2, IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "@uniswap/permit2/test/utils/DeployPermit2.sol";

import {MetadataResolverHelper} from "./MetadataResolverHelper.sol";
import {JBTest} from "./JBTest.sol";

import {MockERC20} from "./../mock/MockERC20.sol";

// forge-lint: disable-next-line(unused-import)
import {mulDiv} from "@prb/math/src/Common.sol";
// forge-lint: disable-next-line(unused-import)
import {mul as UD60x18mul, wrap as UD60x18wrap, unwrap as UD60x18unwrap} from "@prb/math/src/UD60x18.sol";

// Base contract for Juicebox system tests.
// Provides common functionality, such as deploying contracts on test setup.
contract TestBaseWorkflow is JBTest, DeployPermit2 {
    // Multisig address used for testing.
    address private _multisig = address(123);
    address private _beneficiary = address(69_420);
    address private _trustedForwarder = address(123_456);
    MockERC20 private _usdcToken;
    address private _permit2;
    JBPermissions private _jbPermissions;
    JBProjects private _jbProjects;
    JBPrices private _jbPrices;
    JBDirectory private _jbDirectory;
    JBRulesets private _jbRulesets;
    JBERC20 private _jbErc20;
    JBTokens private _jbTokens;
    JBSplits private _jbSplits;
    JBController private _jbController;
    JBFeelessAddresses private _jbFeelessAddresses;
    JBFundAccessLimits private _jbFundAccessLimits;
    JBTerminalStore private _jbTerminalStore;
    JBMultiTerminal private _jbMultiTerminal;
    MetadataResolverHelper private _metadataHelper;
    JBMultiTerminal private _jbMultiTerminal2;

    function multisig() internal view returns (address) {
        return _multisig;
    }

    function beneficiary() internal view returns (address) {
        return _beneficiary;
    }

    function usdcToken() internal view returns (MockERC20) {
        return _usdcToken;
    }

    function permit2() internal view returns (IPermit2) {
        return IPermit2(_permit2);
    }

    function jbPermissions() internal view returns (JBPermissions) {
        return _jbPermissions;
    }

    function jbProjects() internal view returns (JBProjects) {
        return _jbProjects;
    }

    function jbPrices() internal view returns (JBPrices) {
        return _jbPrices;
    }

    function jbDirectory() internal view returns (JBDirectory) {
        return _jbDirectory;
    }

    function jbRulesets() internal view returns (JBRulesets) {
        return _jbRulesets;
    }

    function jbErc20() internal view returns (JBERC20) {
        return _jbErc20;
    }

    function jbTokens() internal view returns (JBTokens) {
        return _jbTokens;
    }

    function jbSplits() internal view returns (JBSplits) {
        return _jbSplits;
    }

    function jbController() internal view returns (JBController) {
        return _jbController;
    }

    function jbFeelessAddresses() internal view returns (JBFeelessAddresses) {
        return _jbFeelessAddresses;
    }

    function jbAccessConstraintStore() internal view returns (JBFundAccessLimits) {
        return _jbFundAccessLimits;
    }

    function jbTerminalStore() internal view returns (JBTerminalStore) {
        return _jbTerminalStore;
    }

    function jbMultiTerminal() internal view returns (JBMultiTerminal) {
        return _jbMultiTerminal;
    }

    function jbMultiTerminal2() internal view returns (JBMultiTerminal) {
        return _jbMultiTerminal2;
    }

    function trustedForwarder() internal view returns (address) {
        return _trustedForwarder;
    }

    function metadataHelper() internal view returns (MetadataResolverHelper) {
        return _metadataHelper;
    }

    //*********************************************************************//
    // --------------------------- test setup ---------------------------- //
    //*********************************************************************//

    // Deploys and initializes contracts for testing.
    function setUp() public virtual {
        _jbPermissions = new JBPermissions(_trustedForwarder);
        _jbProjects = new JBProjects(_multisig, address(0), _trustedForwarder);
        _jbDirectory = new JBDirectory(_jbPermissions, _jbProjects, _multisig);
        _jbErc20 = new JBERC20(_jbPermissions, _jbProjects);
        _jbTokens = new JBTokens(_jbDirectory, _jbErc20);
        _jbRulesets = new JBRulesets(_jbDirectory);
        _jbPrices = new JBPrices(_jbDirectory, _jbPermissions, _jbProjects, _multisig, _trustedForwarder);
        _jbSplits = new JBSplits(_jbDirectory);
        _jbFundAccessLimits = new JBFundAccessLimits(_jbDirectory);
        _jbFeelessAddresses = new JBFeelessAddresses(_multisig, _jbPermissions, _jbProjects);

        _usdcToken = new MockERC20("USDC", "USDC");

        _jbController = new JBController(
            _jbDirectory,
            _jbFundAccessLimits,
            _jbPermissions,
            _jbPrices,
            _jbProjects,
            _jbRulesets,
            _jbSplits,
            _jbTokens,
            address(0), // omnichainRulesetOperator
            _trustedForwarder
        );

        _metadataHelper = new MetadataResolverHelper();

        vm.prank(_multisig);
        _jbDirectory.setIsAllowedToSetFirstController(address(_jbController), true);

        _jbTerminalStore = new JBTerminalStore(_jbDirectory, _jbPrices, _jbRulesets);

        vm.prank(_multisig);
        _permit2 = deployPermit2();

        _jbMultiTerminal = new JBMultiTerminal(
            _jbFeelessAddresses,
            _jbPermissions,
            _jbProjects,
            _jbSplits,
            _jbTerminalStore,
            _jbTokens,
            IPermit2(_permit2),
            _trustedForwarder
        );

        _jbMultiTerminal2 = new JBMultiTerminal(
            _jbFeelessAddresses,
            _jbPermissions,
            _jbProjects,
            _jbSplits,
            _jbTerminalStore,
            _jbTokens,
            IPermit2(_permit2),
            _trustedForwarder
        );

        vm.label(_multisig, "projectOwner");
        vm.label(_beneficiary, "beneficiary");
        vm.label(address(_jbPrices), "JBPrices");
        vm.label(address(_jbProjects), "JBProjects");
        vm.label(address(_jbRulesets), "JBRulesets");
        vm.label(address(_jbDirectory), "JBDirectory");
        vm.label(address(_usdcToken), "ERC20");
        vm.label(address(_jbPermissions), "JBPermissions");
        vm.label(address(_jbTokens), "JBTokens");
        vm.label(address(_jbFeelessAddresses), "JBFeelessAddresses");
        vm.label(address(_jbFundAccessLimits), "JBFundAccessLimits");
        vm.label(address(_jbSplits), "JBSplits");
        vm.label(address(_jbController), "JBController");
        vm.label(address(_jbTerminalStore), "JBTerminalStore");
        vm.label(address(_jbMultiTerminal2), "JBMultiTerminal2");
        vm.label(address(_jbMultiTerminal), "JBMultiTerminal");
    }

    //https://ethereum.stackexchange.com/questions/24248/how-to-calculate-an-ethereum-contracts-address-during-its-creation-using-the-so
    function addressFrom(address _origin, uint256 _nonce) internal pure returns (address _address) {
        bytes memory data;
        if (_nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _origin, bytes1(0x80));
        } else if (_nonce <= 0x7f) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _origin, uint8(_nonce));
        } else if (_nonce <= 0xff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), _origin, bytes1(0x81), uint8(_nonce));
        } else if (_nonce <= 0xffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), _origin, bytes1(0x82), uint16(_nonce));
        } else if (_nonce <= 0xffffff) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), _origin, bytes1(0x83), uint24(_nonce));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), _origin, bytes1(0x84), uint32(_nonce));
        }
        bytes32 hash = keccak256(data);
        assembly {
            mstore(0, hash)
            _address := mload(0)
        }
    }

    function strEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }
}
