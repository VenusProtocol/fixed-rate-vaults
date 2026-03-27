// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

import { IInstitutionPositionToken } from "./IInstitutionPositionToken.sol";
import { VaultConfig, VaultRuntime, VaultState, PauseLevel } from "./IVaultTypes.sol";
import { InstitutionalConfig, InstitutionalRuntime, RiskConfig, LiquidationType } from "./IInstitutionalVaultTypes.sol";

/// @title IInstitutionalLoanVault
/// @notice Interface for the Institutional Fixed-Rate Loan Vault (ERC-4626 + collateral + borrowing + liquidation).
interface IInstitutionalLoanVault is IERC4626Upgradeable {
    // ──────────────────────────────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the vault clone. Called once by VaultController at deployment.
     * @param _config Shared vault configuration (asset, rates, caps, timing).
     * @param _instConfig Institutional-specific configuration (collateral, sizing, position identity).
     * @param _riskConfig Risk parameters (LT, LI, latePenaltyRate).
     * @param _positionToken InstitutionPositionToken contract reference.
     * @param _liquidationAdapter LiquidationAdapter contract address.
     */
    function initialize(
        VaultConfig calldata _config,
        InstitutionalConfig calldata _instConfig,
        RiskConfig calldata _riskConfig,
        IInstitutionPositionToken _positionToken,
        address _liquidationAdapter
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Lifecycle (Controller only)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Transitions MarginDeposited -> Open. Sets timestamps and isActive.
     * @custom:error InvalidState If vault is not in MarginDeposited state.
     * @custom:event VaultOpened Emitted with the open end time.
     * @custom:event StateTransition Emitted for MarginDeposited -> Fundraising.
     */
    function openVault() external;

    /**
     * @notice Sets isActive = false. Vault stays in Matured/Failed/Liquidated.
     * @custom:error InvalidState If vault is not in a terminal state.
     * @custom:event VaultClosed Emitted with the terminal state.
     */
    function closeVault() external;

    /**
     * @notice Partial pause — blocks general operations (deposits, collateral, borrowing).
     *         Repay and liquidation remain available.
     * @custom:event PauseLevelSet
     */
    function partialPause() external;

    /**
     * @notice Complete pause — blocks all operations including repay and liquidation.
     * @custom:event PauseLevelSet
     */
    function completePause() external;

    /**
     * @notice Removes all pause restrictions.
     * @custom:event PauseLevelSet
     */
    function unpause() external;

    /**
     * @notice Recovers any tokens stuck in the vault. Full balance is transferred to the treasury.
     * @param token Token address to sweep.
     * @custom:error VaultNotClosed If the vault is still active.
     * @custom:error NothingToSweep If the token balance is zero.
     * @custom:event TokensSwept
     */
    function sweep(
        address token
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Permissionless State Advancement
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Permissionless vault finalizer. Calls _checkAndAdvanceState().
    function updateVaultState() external;

    // ──────────────────────────────────────────────────────────────────────
    // Institution Functions
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposits collateral into the vault. WaitingForMargin, Fundraising, or Lock states.
     * @param amount Amount of collateral tokens to deposit.
     * @custom:error InvalidState If vault is not in WaitingForMargin, Fundraising, or Lock.
     * @custom:error InsufficientCollateral If deposit in WaitingForMargin does not meet margin threshold.
     * @custom:event CollateralDeposited Emitted with actual deposited amount and total collateral.
     * @custom:event StateTransition Emitted if WaitingForMargin -> MarginDeposited.
     */
    function depositCollateral(
        uint256 amount
    ) external;

    /**
     * @notice Withdraws collateral. Lock: floor + LT-checked. Failed: Scenario A/B. Matured: unrestricted.
     *         Liquidated: blocked — collateral recoverable by governance via sweep().
     * @param amount Amount of collateral tokens to withdraw.
     * @custom:error InvalidState If vault is not in Lock, Matured, or Failed.
     * @custom:error InsufficientCollateral If withdrawal would breach floor or exceed available amount.
     * @custom:error WithdrawalWouldBreachLT If withdrawal would cause LT shortfall during Lock.
     * @custom:event CollateralWithdrawn Emitted with withdrawal amount.
     */
    function withdrawCollateral(
        uint256 amount
    ) external;

    /**
     * @notice One-time function. Transfers all raised supply assets to institution operator.
     * @custom:error InvalidState If vault is not in Lock state.
     * @custom:error AlreadyWithdrawn If funds already claimed.
     * @custom:error ClaimWouldBreachLT If post-claim debt would exceed LT cap.
     * @custom:event RaisedFundsClaimed Emitted with claimed amount.
     */
    function claimRaisedFunds() external;

    /**
     * @notice Repays outstanding debt. Not restricted to institution — anyone may repay.
     * @param amount Amount of supply asset to repay (clamped to outstandingDebt).
     * @custom:error InvalidState If vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt If there is no debt to repay.
     * @custom:event Repaid Emitted with repay amount and remaining debt.
     */
    function repay(
        uint256 amount
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Bad-Debt Rescue (Controller only)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Permissionless bad-debt rescue. Anyone may repay to settle a vault where collateralUSD < debtUSD.
     * @param repayAmount Amount to pull from caller.
     * @custom:error InvalidState If vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NotBadDebt If collateral value >= debt value.
     * @custom:error InsufficientRepayment If outstanding debt after repay still exceeds total interest (principal not
     * fully returned).
     * @custom:event StateTransition Emitted for transition to Liquidated.
     * @custom:event VaultLiquidated Emitted with available balance.
     */
    function repayBadDebt(
        uint256 repayAmount
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Liquidation (LiquidationAdapter only)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice HF-based liquidation. Returns actual repay amount (clamped to debt).
     * @param repayAmount Amount of supply asset to repay.
     * @return actualRepay Actual amount repaid after clamping.
     * @custom:error InvalidState If vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt If there is no debt to repay.
     * @custom:error NotLiquidatable If vault has no LT shortfall.
     * @custom:error ExceedsCloseFactor If repay exceeds close factor limit.
     * @custom:error InsufficientCollateralForSeize If seize amount exceeds collateral balance.
     * @custom:event LiquidationExecuted Emitted with liquidator, repay amount, and collateral seized.
     */
    function liquidate(
        uint256 repayAmount
    ) external returns (uint256 actualRepay);

    /**
     * @notice Deadline-based liquidation for overdue vaults. Returns actual repay amount.
     * @param repayAmount Amount of supply asset to repay.
     * @return actualRepay Actual amount repaid after clamping.
     * @custom:error InvalidStateForOverdueLiquidation If not in SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt If there is no debt to repay.
     * @custom:error ExceedsCloseFactor If repay exceeds close factor limit.
     * @custom:error InsufficientCollateralForSeize If seize amount exceeds collateral balance.
     * @custom:event OverdueLiquidationExecuted Emitted with settler, repay amount, and collateral seized.
     */
    function liquidateOverdueVault(
        uint256 repayAmount
    ) external returns (uint256 actualRepay);

    // ──────────────────────────────────────────────────────────────────────
    // Risk Parameter Setters (Controller only)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates liquidation threshold. Validated by controller before calling.
     * @param newLT New liquidation threshold (mantissa).
     * @custom:event LiquidationThresholdUpdated
     */
    function setLiquidationThreshold(
        uint256 newLT
    ) external;

    /**
     * @notice Updates liquidation incentive. Validated by controller before calling.
     * @param newLI New liquidation incentive (mantissa).
     * @custom:event LiquidationIncentiveUpdated
     */
    function setLiquidationIncentive(
        uint256 newLI
    ) external;

    /**
     * @notice Updates late penalty rate. Validated by controller before calling.
     * @param newRate New late penalty rate (mantissa).
     * @custom:event LatePenaltyRateUpdated
     */
    function setLatePenaltyRate(
        uint256 newRate
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Total remaining debt. Decremented by repayments; zero when fully repaid.
    function outstandingDebt() external view returns (uint256);

    /// @notice Current collateral value in USD via oracle.
    function getCollateralValueUSD() external view returns (uint256);

    /// @notice Current outstanding debt value in USD via oracle.
    function getDebtValueUSD() external view returns (uint256);

    /// @notice Current vault state.
    function state() external view returns (VaultState);

    /// @notice Returns the shared vault configuration.
    function config() external view returns (VaultConfig memory);

    /// @notice Returns the institutional-specific configuration.
    function institutionalConfig() external view returns (InstitutionalConfig memory);

    /// @notice Returns the risk configuration.
    function riskConfig() external view returns (RiskConfig memory);

    /// @notice Returns the shared runtime state.
    function runtime() external view returns (VaultRuntime memory);

    /// @notice Returns the institutional-specific runtime state.
    function institutionalRuntime() external view returns (InstitutionalRuntime memory);

    /// @notice VaultController address.
    function vaultController() external view returns (address);

    /// @notice Current pause level (Unpaused, Partial, Complete).
    function pauseLevel() external view returns (PauseLevel);

    // ──────────────────────────────────────────────────────────────────────
    // Vault Liquidity & Seize Previews
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns current liquidity and shortfall for the vault.
    function getVaultLiquidity() external view returns (uint256 liquidity, uint256 shortfall);

    /**
     * @notice Returns hypothetical liquidity/shortfall after a simulated withdrawal and/or debt increase.
     * @param withdrawAmount Collateral amount to simulate withdrawing.
     * @param additionalDebt Additional debt to simulate on top of outstanding.
     * @return liquidity Surplus collateral value above the liquidation threshold.
     * @return shortfall Deficit collateral value below the liquidation threshold.
     */
    function getHypotheticalVaultLiquidity(
        uint256 withdrawAmount,
        uint256 additionalDebt
    ) external view returns (uint256 liquidity, uint256 shortfall);

    /**
     * @notice Preview seize amount for a given repay and liquidation type.
     * @param repayAmount Amount of supply asset being repaid.
     * @param liquidationType HF-based or overdue liquidation type.
     * @return Collateral amount to seize.
     */
    function calculateSeizeAmount(
        uint256 repayAmount,
        LiquidationType liquidationType
    ) external view returns (uint256);
}
