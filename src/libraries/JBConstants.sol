// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Protocol-wide constants. These define the boundaries for economic parameters throughout Juicebox.
library JBConstants {
    /// @notice The sentinel address used to represent each chain's native token (ETH on mainnet, etc.).
    address public constant NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    /// @notice The maximum reserved token percentage (basis points). 10,000 = 100% of minted tokens go to reserves.
    uint16 public constant MAX_RESERVED_PERCENT = 10_000;

    /// @notice The maximum cash-out tax rate (basis points). 10,000 = 100% tax, meaning token holders reclaim nothing.
    uint16 public constant MAX_CASH_OUT_TAX_RATE = 10_000;

    /// @notice The maximum weight cut percent (9-decimal precision). 1,000,000,000 = 100% cut per cycle (no issuance).
    uint32 public constant MAX_WEIGHT_CUT_PERCENT = 1_000_000_000;

    /// @notice The denominator for split percentages (9-decimal precision). A split of 1,000,000,000 = 100%.
    uint32 public constant SPLITS_TOTAL_PERCENT = 1_000_000_000;

    /// @notice The fee denominator. The protocol fee is `FEE / MAX_FEE` (currently 25/1000 = 2.5%).
    uint16 public constant MAX_FEE = 1000;

    /// @notice The fee numerator. The protocol fee is `FEE / MAX_FEE` = 25/1000 = 2.5%, charged on outflows.
    uint16 public constant FEE = 25;

    /// @notice The project ID that receives protocol fees. Should be the first project launched at deployment.
    uint256 public constant FEE_BENEFICIARY_PROJECT_ID = 1;
}
