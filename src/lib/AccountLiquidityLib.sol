// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IInstitutionalLoanVault } from "../interfaces/IInstitutionalLoanVault.sol";
import { IInstitutionalVaultController } from "../interfaces/IInstitutionalVaultController.sol";
import { IResilientOracle } from "../interfaces/IResilientOracle.sol";

/// @title AccountLiquidityLib
/// @notice Stateless library for FRIV risk math — liquidity/shortfall and seize calculations.
/// @dev Used by InstitutionalVaultController. No storage, no state — pure computation.
///      Fetches all data directly from the vault.
library AccountLiquidityLib {
    uint256 internal constant MANTISSA = 1e18;

    /// @notice Computes liquidity (excess buffer) and shortfall (deficit) for a vault,
    ///         optionally simulating a collateral withdrawal.
    /// @param vault Vault address — lib fetches collateralUSD, debtUSD, LT from vault.
    /// @param withdrawAmount Collateral token amount to simulate withdrawing (use 0 for current state).
    /// @return liquidity Excess buffer when safe; 0 when shortfall > 0.
    /// @return shortfall Deficit when liquidatable; 0 when liquidity > 0.
    function getHypotheticalAccountLiquidity(
        address vault,
        uint256 withdrawAmount
    ) internal view returns (uint256 liquidity, uint256 shortfall) {
        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);

        uint256 collateralUSD = v.getCollateralValueUSD();
        uint256 debtUSD = v.getDebtValueUSD();
        uint256 lt = v.riskConfig().liquidationThreshold;

        uint256 withdrawValueUSD;
        if (withdrawAmount > 0) {
            uint256 collateralBalance = IERC20(address(v.config().collateralAsset)).balanceOf(vault);
            if (collateralBalance > 0) {
                withdrawValueUSD = (withdrawAmount * collateralUSD) / collateralBalance;
            }
        }

        uint256 collateralAfterWithdraw = collateralUSD > withdrawValueUSD ? collateralUSD - withdrawValueUSD : 0;
        uint256 ltCap = (collateralAfterWithdraw * lt) / MANTISSA;

        if (debtUSD <= ltCap) {
            return (ltCap - debtUSD, 0);
        } else {
            return (0, debtUSD - ltCap);
        }
    }

    /// @notice Computes the collateral amount to seize for a given repay amount.
    /// @param vault Vault address — lib fetches config, resolves oracle via vault.vaultController().
    /// @param repayAmount Amount of supply asset being repaid.
    /// @param incentive Multiplier (e.g. 1.1e18). Use liquidationIncentive for HF-based,
    ///                  latePenaltyRate for overdue.
    /// @return seizeAmount Collateral amount to transfer to liquidator/settler.
    function calculateSeizeAmount(
        address vault,
        uint256 repayAmount,
        uint256 incentive
    ) internal view returns (uint256 seizeAmount) {
        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);
        address supplyAsset = address(v.config().supplyAsset);
        address collateralAsset = address(v.config().collateralAsset);
        address oracleAddr = IInstitutionalVaultController(v.vaultController()).oracle();

        uint256 supplyPrice = IResilientOracle(oracleAddr).getPrice(supplyAsset);
        uint256 collateralPrice = IResilientOracle(oracleAddr).getPrice(collateralAsset);

        if (collateralPrice == 0) return 0;

        uint8 supplyDecimals = IERC20Metadata(supplyAsset).decimals();
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();

        uint256 repayValueUSD = (repayAmount * supplyPrice) / (10 ** supplyDecimals);
        uint256 seizeValueUSD = (repayValueUSD * incentive) / MANTISSA;
        seizeAmount = (seizeValueUSD * (10 ** collateralDecimals)) / collateralPrice;
    }
}
