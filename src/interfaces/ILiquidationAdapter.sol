// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

/// @title ILiquidationAdapter
/// @notice Interface for the LiquidationAdapter — manages whitelists, routes liquidations, splits incentives.
interface ILiquidationAdapter {
    // ──────────────────────────────────────────────────────────────────────
    // Liquidation
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice HF-based liquidation. Whitelisted liquidator only.
     * @param vault Vault address to liquidate.
     * @param repayAmount Amount of supply asset to repay.
     * @custom:error NotWhitelistedLiquidator If caller is not whitelisted.
     * @custom:error VaultNotRegistered If vault is not in the controller registry.
     * @custom:error ZeroRepayAmount If repayAmount is zero.
     * @custom:event LiquidationCollateralSplit Emitted with seized collateral split.
     */
    function liquidate(
        address vault,
        uint256 repayAmount
    ) external;

    /**
     * @notice Deadline-based liquidation. Whitelisted settler only.
     * @param vault Vault address to liquidate.
     * @param repayAmount Amount of supply asset to repay.
     * @custom:error NotWhitelistedSettler If caller is not whitelisted.
     * @custom:error VaultNotRegistered If vault is not in the controller registry.
     * @custom:error ZeroRepayAmount If repayAmount is zero.
     * @custom:event LiquidationCollateralSplit Emitted with seized collateral split.
     */
    function liquidateOverdueVault(
        address vault,
        uint256 repayAmount
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Whitelist Management (Governance)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Add or remove a liquidator from the whitelist.
     * @param liquidator Liquidator address.
     * @param approved True to add, false to remove.
     */
    function setLiquidatorWhitelist(
        address liquidator,
        bool approved
    ) external;

    /**
     * @notice Add or remove a settler from the whitelist.
     * @param settler Settler address.
     * @param approved True to add, false to remove.
     */
    function setSettlerWhitelist(
        address settler,
        bool approved
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Configuration (Governance)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Set the protocol share of the liquidation incentive (mantissa).
     * @param share Protocol share fraction (mantissa, <= 1e18).
     */
    function setProtocolLiquidationShare(
        uint256 share
    ) external;

    /**
     * @notice Set max fraction of debt repayable per liquidation (global for all vaults).
     * @param newCF New close factor (mantissa).
     */
    function setCloseFactor(
        uint256 newCF
    ) external;

    /**
     * @notice Update ProtocolShareReserve address.
     * @param _psr New ProtocolShareReserve address.
     * @custom:event ProtocolShareReserveUpdated
     */
    function setProtocolShareReserve(
        address _psr
    ) external;

    /**
     * @notice Update comptroller address for PSR.
     * @param _comptroller New comptroller address.
     * @custom:event ComptrollerUpdated
     */
    function setComptroller(
        address _comptroller
    ) external;

    /**
     * @notice Transfer accrued protocol share to PSR.
     * @param collateral Collateral token address to sweep.
     */
    function sweepProtocolShareToReserve(
        address collateral
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Whether address can call liquidate().
     * @param liquidator Address to check.
     * @return True if whitelisted.
     */
    function isWhitelistedLiquidator(
        address liquidator
    ) external view returns (bool);

    /**
     * @notice Whether address can call liquidateOverdueVault().
     * @param settler Address to check.
     * @return True if whitelisted.
     */
    function isWhitelistedSettler(
        address settler
    ) external view returns (bool);

    /// @notice Current protocol share (mantissa).
    function protocolLiquidationShare() external view returns (uint256);

    /// @notice Max fraction of debt repayable per liquidation (global).
    function closeFactor() external view returns (uint256);

    /**
     * @notice Accrued protocol share for a collateral token (pending sweep).
     * @param collateral Collateral token address.
     * @return Accrued amount.
     */
    function protocolShareAccrued(
        address collateral
    ) external view returns (uint256);

    /// @notice VaultController reference.
    function vaultController() external view returns (address);
}
