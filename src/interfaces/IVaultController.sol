// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

/// @title IVaultController
/// @notice Minimal shared interface for vault controllers.
///         Exposes PSR and comptroller references needed by BaseVault settlement logic.
/// @dev Both InstitutionalVaultController and future CeffuVaultController implement this.
interface IVaultController {
    /// @notice Venus ProtocolShareReserve address.
    function protocolShareReserve() external view returns (address);

    /// @notice Comptroller address for PSR integration.
    function comptroller() external view returns (address);
}
