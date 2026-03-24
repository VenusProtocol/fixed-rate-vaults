// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultConfig } from "./IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig, VaultStateInfo } from "./IInstitutionalVaultTypes.sol";
import { IVaultController } from "./IVaultController.sol";

/// @title IInstitutionalVaultController
/// @notice Interface for the Institutional Vault controller: clone deployer, registry, ACM gateway.
interface IInstitutionalVaultController is IVaultController {
    // ──────────────────────────────────────────────────────────────────────
    // Vault Deployment
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploys a new vault clone. ACM-gated.
     * @param _config Shared vault configuration (asset, rates, caps, timing).
     * @param _instConfig Institutional-specific configuration (collateral, sizing, position identity).
     * @param _riskConfig Risk parameters.
     * @return vault Deployed vault address.
     * @custom:error InvalidConfig If any config validation fails.
     * @custom:event VaultCreated Emitted with vault and institution addresses.
     */
    function createVault(
        VaultConfig calldata _config,
        InstitutionalConfig calldata _instConfig,
        RiskConfig calldata _riskConfig
    ) external returns (address vault);

    /// @notice Predicts the next vault address for a given institution.
    function predictVaultAddress(
        address institution
    ) external view returns (address);

    // ──────────────────────────────────────────────────────────────────────
    // Governance-Proxied Vault Lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Transitions MarginDeposited -> Open.
    function openVault(
        address vault
    ) external;

    /// @notice Sets isActive = false on vault.
    function closeVault(
        address vault
    ) external;

    /// @notice Emergency pause on vault.
    function pauseVault(
        address vault
    ) external;

    /// @notice Unpause vault.
    function unpauseVault(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Institution Position Token Governance
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Approves transfer of the vault's position token.
    function approvePositionTransfer(
        address vault
    ) external;

    /// @notice Revokes a previously granted approval.
    function revokePositionTransfer(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Risk Parameter Setters
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Updates liquidation threshold on a vault.
    function setLiquidationThreshold(
        address vault,
        uint256 newLT
    ) external;

    /// @notice Updates liquidation incentive on a vault.
    function setLiquidationIncentive(
        address vault,
        uint256 newLI
    ) external;

    /// @notice Updates late penalty rate on a vault.
    function setLatePenaltyRate(
        address vault,
        uint256 newRate
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Bad-Debt Rescue
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Bad-debt rescue. Pulls funds from caller and repays vault debt.
    function repayBadDebt(
        address vault,
        uint256 repayAmount
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Registry & Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Whether a vault is registered.
    function isRegistered(
        address vault
    ) external view returns (bool);

    /// @notice Returns state summary for all registered vaults.
    function getAggregatedVaultStates() external view returns (VaultStateInfo[] memory);

    /// @notice Venus ResilientOracle address.
    function oracle() external view returns (address);

    // ──────────────────────────────────────────────────────────────────────
    // Admin Setters
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Update clone source. Only affects future vaults.
    function setVaultImplementation(
        address impl
    ) external;

    /// @notice Update LiquidationAdapter address.
    function setLiquidationAdapter(
        address adapter
    ) external;

    /// @notice Update ResilientOracle reference.
    function setOracle(
        address _oracle
    ) external;

    /// @notice Update ProtocolShareReserve address.
    function setProtocolShareReserve(
        address _psr
    ) external;

    /// @notice Update comptroller address for PSR.
    function setComptroller(
        address _comptroller
    ) external;
}
