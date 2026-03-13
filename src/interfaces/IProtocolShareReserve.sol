// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

/// @notice Minimal interface for Venus ProtocolShareReserve.
interface IProtocolShareReserve {
    enum IncomeType {
        SPREAD,
        LIQUIDATION,
        INSTITUTIONAL_VAULT_PROTOCOL_FEE,
        INSTITUTIONAL_VAULT_LIQUIDATION
    }

    /// @notice Updates accounting state after an asset transfer to PSR.
    function updateAssetsState(address comptroller, address asset, IncomeType incomeType) external;
}
