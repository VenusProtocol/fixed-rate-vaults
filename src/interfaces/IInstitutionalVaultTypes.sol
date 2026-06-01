// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { VaultState } from "./IVaultTypes.sol";

/// @notice Liquidation type selector — HF-based uses liquidationIncentive, deadline-based uses latePenaltyRate.
enum LiquidationType {
    HF_BASED,
    DEADLINE
}

/// @notice Institutional vault configuration — collateral, sizing, and position identity.
///         Extends the shared VaultConfig with institutional-specific fields.
struct InstitutionalConfig {
    // ── Asset ──
    IERC20 collateralAsset;
    // ── Collateral sizing ──
    uint256 idealCollateralAmount; // total collateral required at full capacity (maxBorrowCap), sized off-chain via CF
    uint256 marginRate; // mantissa (0.01e18 = 1%) — margin percentage relative to idealCollateralAmount
    // ── Position identity ──
    address institutionOperator; // initial position token recipient
    uint256 positionTokenId; // token representing institution position
}

/// @notice Risk parameters — LT/LI/latePenaltyRate mutable via VaultController.
struct RiskConfig {
    uint256 liquidationThreshold; // mantissa (0.85e18 = 85%), mutable
    uint256 liquidationIncentive; // Venus convention: 1.1e18 = 10% incentive, mutable
    uint256 latePenaltyRate; // mantissa — used for liquidateOverdueVault() seize calc, mutable
}

/// @notice Institutional vault runtime — collateral accounting and margin confiscation.
///         Extends the shared VaultRuntime with institutional-specific fields.
struct InstitutionalRuntime {
    // ── Collateral accounting ──
    uint256 totalCollateralDeposited; // cumulative collateral deposited by institution (decremented on withdrawal)
    uint256 minimumCollateralRequired; // locked floor; recalculated at Lock based on totalRaised
    // ── Margin confiscation (Failed scenario B) ──
    uint256 confiscatedMarginRemaining; // margin amount left to distribute to lenders (Scenario B); 0 in Scenario A
    bool institutionDefaulted; // true when Failed due to insufficient collateral (Scenario B)
}

/// @notice Summary info returned by controller registry views.
struct VaultStateInfo {
    address vault;
    VaultState state;
    address institutionOperator;
    uint256 totalRaised;
    uint256 outstandingDebt;
}
