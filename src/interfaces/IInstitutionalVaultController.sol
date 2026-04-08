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

    /**
     * @notice Predicts the next vault address for a given institution.
     * @param institution Institution operator address.
     * @return Predicted vault address.
     */
    function predictVaultAddress(
        address institution
    ) external view returns (address);

    // ──────────────────────────────────────────────────────────────────────
    // Governance-Proxied Vault Lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Transitions MarginDeposited -> Fundraising.
     * @param vault Vault address to open.
     */
    function openVault(
        address vault
    ) external;

    /**
     * @notice Sets isActive = false on vault.
     * @param vault Vault address to close.
     */
    function closeVault(
        address vault
    ) external;

    /**
     * @notice Recovers stuck tokens from a vault to treasury.
     * @param vault Vault address.
     * @param token Token address to sweep.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function sweep(
        address vault,
        address token
    ) external;

    /**
     * @notice Partial pause — blocks general operations; repay and liquidation remain available.
     * @param vault Vault address to pause.
     */
    function partialPauseVault(
        address vault
    ) external;

    /**
     * @notice Complete pause — blocks all operations including repay and liquidation.
     * @param vault Vault address to pause.
     */
    function completePauseVault(
        address vault
    ) external;

    /**
     * @notice Unpause vault — removes all pause restrictions.
     * @param vault Vault address to unpause.
     */
    function unpauseVault(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Institution Position Token Governance
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Approves transfer of the vault's position token.
     * @param vault Vault address whose position token transfer is approved.
     */
    function approvePositionTransfer(
        address vault
    ) external;

    /**
     * @notice Revokes a previously granted approval.
     * @param vault Vault address whose position token transfer approval is revoked.
     */
    function revokePositionTransfer(
        address vault
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Risk Parameter Setters
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates liquidation threshold on a vault.
     * @param vault Vault address to update.
     * @param newLT New liquidation threshold (mantissa).
     * @custom:event LiquidationThresholdUpdated
     */
    function setLiquidationThreshold(
        address vault,
        uint256 newLT
    ) external;

    /**
     * @notice Updates liquidation incentive on a vault.
     * @param vault Vault address to update.
     * @param newLI New liquidation incentive (mantissa). Must be in range (MANTISSA_ONE, MANTISSA_ONE_AND_HALF].
     * @custom:error InvalidLiquidationIncentive If newLI <= MANTISSA_ONE or newLI > MANTISSA_ONE_AND_HALF.
     * @custom:event LiquidationIncentiveUpdated
     */
    function setLiquidationIncentive(
        address vault,
        uint256 newLI
    ) external;

    /**
     * @notice Updates late penalty rate on a vault.
     * @param vault Vault address to update.
     * @param newRate New late penalty rate (mantissa). Must be in range (MANTISSA_ONE, MANTISSA_ONE_AND_HALF].
     * @custom:error InvalidLatePenaltyRate If newRate <= MANTISSA_ONE or newRate > MANTISSA_ONE_AND_HALF.
     * @custom:event LatePenaltyRateUpdated
     */
    function setLatePenaltyRate(
        address vault,
        uint256 newRate
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Registry & Views
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Whether a vault is registered.
     * @param vault Vault address to check.
     * @return True if the vault is registered.
     */
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

    /**
     * @notice Update clone source. Only affects future vaults.
     * @param impl New vault implementation address.
     */
    function setVaultImplementation(
        address impl
    ) external;

    /**
     * @notice Update LiquidationAdapter address.
     * @param adapter New LiquidationAdapter address.
     */
    function setLiquidationAdapter(
        address adapter
    ) external;

    /**
     * @notice Update ResilientOracle reference.
     * @param _oracle New oracle address.
     */
    function setOracle(
        address _oracle
    ) external;

    /**
     * @notice Update ProtocolShareReserve address.
     * @param _psr New ProtocolShareReserve address.
     */
    function setProtocolShareReserve(
        address _psr
    ) external;

    /**
     * @notice Update comptroller address for PSR.
     * @param _comptroller New comptroller address.
     */
    function setComptroller(
        address _comptroller
    ) external;

    /**
     * @notice Update treasury address for swept tokens.
     * @param treasury_ New treasury address.
     */
    function setTreasury(
        address treasury_
    ) external;
}
