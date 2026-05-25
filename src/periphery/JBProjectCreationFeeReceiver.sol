// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "../interfaces/IJBDirectory.sol";
import {IJBTerminal} from "../interfaces/IJBTerminal.sol";
import {JBConstants} from "../libraries/JBConstants.sol";

/// @notice Routes native-token project creation fees into a Juicebox project balance.
/// @dev Configure `JBProjects.creationFeeReceiver` to this contract to send creation fees to project 1's primary
/// native-token terminal while keeping `JBProjects` independent from `JBDirectory`.
contract JBProjectCreationFeeReceiver {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBProjectCreationFeeReceiver_NoPrimaryTerminal(uint256 projectId);
    error JBProjectCreationFeeReceiver_ZeroDirectory();
    error JBProjectCreationFeeReceiver_ZeroProjectId();

    //*********************************************************************//
    // --------------------------- events -------------------------------- //
    //*********************************************************************//

    /// @notice A project creation fee was routed to the target project.
    /// @param projectId The project that received the fee.
    /// @param terminal The terminal that received the fee.
    /// @param amount The native-token amount routed.
    /// @param caller The address that sent the fee.
    event RouteProjectCreationFee(
        uint256 indexed projectId, IJBTerminal indexed terminal, uint256 amount, address caller
    );

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The directory used to resolve the target project's primary native-token terminal.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The project that receives creation fees.
    uint256 public immutable PROJECT_ID;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory used to resolve the target project's primary native-token terminal.
    /// @param projectId The project that receives creation fees.
    constructor(IJBDirectory directory, uint256 projectId) {
        if (directory == IJBDirectory(address(0))) revert JBProjectCreationFeeReceiver_ZeroDirectory();
        if (projectId == 0) revert JBProjectCreationFeeReceiver_ZeroProjectId();

        DIRECTORY = directory;
        PROJECT_ID = projectId;
    }

    //*********************************************************************//
    // --------------------------- receive ------------------------------- //
    //*********************************************************************//

    /// @notice Route received native tokens into the target project's primary native-token terminal.
    receive() external payable {
        // Ignore no-op transfers.
        if (msg.value == 0) return;

        // Resolve the target project's current primary native-token terminal.
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf({projectId: PROJECT_ID, token: JBConstants.NATIVE_TOKEN});
        if (terminal == IJBTerminal(address(0))) {
            revert JBProjectCreationFeeReceiver_NoPrimaryTerminal({projectId: PROJECT_ID});
        }

        // Add the fee to the project's balance without minting project tokens or returning held fees.
        terminal.addToBalanceOf{value: msg.value}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: msg.value,
            shouldReturnHeldFees: false,
            memo: "Project creation fee",
            metadata: bytes("")
        });

        emit RouteProjectCreationFee({projectId: PROJECT_ID, terminal: terminal, amount: msg.value, caller: msg.sender});
    }
}
