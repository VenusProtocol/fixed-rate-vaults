// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

import { IInstitutionPositionToken } from "./IInstitutionPositionToken.sol";
import { VaultConfig, RiskConfig, VaultRuntime, VaultState, LiquidationType } from "./IInstitutionalVaultTypes.sol";

/// @title IInstitutionalLoanVault
/// @notice Interface for the Institutional Fixed-Rate Loan Vault (ERC-4626 + collateral + borrowing + liquidation).
interface IInstitutionalLoanVault is IERC4626Upgradeable {
    // ──────────────────────────────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Initializes the vault clone. Called once by VaultController at deployment.
    /// @param _config Vault configuration (assets, caps, durations, etc.).
    /// @param _riskConfig Risk parameters (LT, LI, latePenaltyRate).
    /// @param _positionToken InstitutionPositionToken contract reference.
    /// @param _liquidationAdapter LiquidationAdapter contract address.
    function initialize(
        VaultConfig calldata _config,
        RiskConfig calldata _riskConfig,
        IInstitutionPositionToken _positionToken,
        address _liquidationAdapter
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Lifecycle (Controller only)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Transitions CollateralDeposited -> Open. Sets timestamps and isActive.
    function openVault() external;

    /// @notice Sets isActive = false. Vault stays in Matured/Failed/Liquidated.
    function closeVault() external;

    /// @notice Emergency pause — blocks deposits, collateral ops, and borrowing.
    function pause() external;

    /// @notice Unpause.
    function unpause() external;

    // ──────────────────────────────────────────────────────────────────────
    // Permissionless State Advancement
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Permissionless vault finalizer. Calls _checkAndAdvanceState().
    function updateVaultState() external;

    // ──────────────────────────────────────────────────────────────────────
    // Institution Functions
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Deposits collateral into the vault. WaitingForCollateral or Lock states.
    /// @param amount Amount of collateral tokens to deposit.
    function depositCollateral(uint256 amount) external;

    /// @notice Withdraws collateral. Lock: top-up only, LT-checked. Matured: all, unrestricted.
    /// @param amount Amount of collateral tokens to withdraw.
    function withdrawCollateral(uint256 amount) external;

    /// @notice One-time function. Transfers all raised supply assets to institution operator.
    function claimRaisedFunds() external;

    /// @notice Repays outstanding debt. Not restricted to institution — anyone may repay.
    /// @param amount Amount of supply asset to repay (clamped to outstandingDebt).
    function repay(uint256 amount) external;

    // ──────────────────────────────────────────────────────────────────────
    // Bad-Debt Rescue (Controller only)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Governance bad-debt rescue. Requires collateralUSD < debtUSD.
    /// @param repayAmount Amount to pull from controller.
    function repayBadDebt(uint256 repayAmount) external;

    // ──────────────────────────────────────────────────────────────────────
    // Liquidation (LiquidationAdapter only)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice HF-based liquidation. Returns actual repay amount (clamped to debt).
    /// @param repayAmount Amount of supply asset to repay.
    /// @return actualRepay Actual amount repaid after clamping.
    function liquidate(uint256 repayAmount) external returns (uint256 actualRepay);

    /// @notice Deadline-based liquidation for overdue vaults. Returns actual repay amount.
    /// @param repayAmount Amount of supply asset to repay.
    /// @return actualRepay Actual amount repaid after clamping.
    function liquidateOverdueVault(uint256 repayAmount) external returns (uint256 actualRepay);

    // ──────────────────────────────────────────────────────────────────────
    // Risk Parameter Setters (Controller only)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Updates liquidation threshold. Validated by controller before calling.
    function setLiquidationThreshold(uint256 newLT) external;

    /// @notice Updates liquidation incentive. Validated by controller before calling.
    function setLiquidationIncentive(uint256 newLI) external;

    /// @notice Updates late penalty rate. Validated by controller before calling.
    function setLatePenaltyRate(uint256 newRate) external;

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Total remaining debt: totalOwed - balanceOf(supplyAsset), floored at 0.
    function outstandingDebt() external view returns (uint256);

    /// @notice Current collateral value in USD via oracle.
    function getCollateralValueUSD() external view returns (uint256);

    /// @notice Current outstanding debt value in USD via oracle.
    function getDebtValueUSD() external view returns (uint256);

    /// @notice Current vault state.
    function state() external view returns (VaultState);

    /// @notice Returns the vault configuration.
    function config() external view returns (VaultConfig memory);

    /// @notice Returns the risk configuration.
    function riskConfig() external view returns (RiskConfig memory);

    /// @notice Returns the runtime state.
    function runtime() external view returns (VaultRuntime memory);

    /// @notice VaultController address.
    function vaultController() external view returns (address);

    // ──────────────────────────────────────────────────────────────────────
    // Vault Liquidity & Seize Previews
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns current liquidity and shortfall for the vault.
    function getVaultLiquidity() external view returns (uint256 liquidity, uint256 shortfall);

    /// @notice Returns hypothetical liquidity/shortfall after a simulated withdrawal.
    function getHypotheticalVaultLiquidity(
        uint256 withdrawAmount
    ) external view returns (uint256 liquidity, uint256 shortfall);

    /// @notice Preview seize amount for a given repay and liquidation type.
    function calculateSeizeAmount(
        uint256 repayAmount,
        LiquidationType liquidationType
    ) external view returns (uint256);
}
