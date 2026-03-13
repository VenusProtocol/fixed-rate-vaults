// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Vault lifecycle states for the Institutional Fixed-Rate Vault system.
enum VaultState {
    WaitingForCollateral, // 0 — deployed, awaiting institution collateral
    CollateralDeposited, // 1 — collateral received, awaiting open trigger
    Open, // 2 — fundraising: suppliers deposit supply asset
    Lock, // 3 — borrowing active, interest accruing
    PendingSettlement, // 4 — maturity reached, awaiting repayment within settlement window
    SettlementDeadlineExceeded, // 5 — settlement deadline passed with outstanding debt
    Matured, // 6 — debt repaid + lock period passed; suppliers and institution can withdraw
    Failed, // 7 — fundraising failed (below min cap); suppliers can refund
    Liquidated // 8 — bad-debt rescue; suppliers can redeem; institution cannot withdraw collateral
}

/// @notice Liquidation type selector — HF-based uses liquidationIncentive, deadline-based uses latePenaltyRate.
enum LiquidationType {
    HF_BASED,
    DEADLINE
}

/// @notice Immutable configuration set once at vault initialization.
struct VaultConfig {
    IERC20 supplyAsset;
    IERC20 collateralAsset;
    uint256 requiredCollateral;
    uint256 fixedAPY; // basis points (800 = 8%)
    uint256 minBorrowCap;
    uint256 maxBorrowCap;
    uint40 openDuration;
    uint40 lockDuration;
    uint40 settlementWindow;
    uint256 reserveFactor; // mantissa (0.1e18 = 10%)
    address institutionOperator; // initial NFT recipient
    uint256 positionTokenId; // NFT representing institution position
    uint256 minSupplierDeposit; // minimum deposit in supply asset units; 0 = disable
}

/// @notice Risk parameters — CF immutable, LT/LI/latePenaltyRate mutable via VaultController.
struct RiskConfig {
    uint256 collateralFactor; // mantissa, immutable — used at creation only for requiredCollateral sizing
    uint256 liquidationThreshold; // mantissa (0.85e18 = 85%), mutable
    uint256 liquidationIncentive; // Venus convention: 1.1e18 = 10% incentive, mutable
    uint256 latePenaltyRate; // mantissa — used for liquidateOverdueVault() seize calc, mutable
}

/// @notice Runtime state that changes as the vault progresses through its lifecycle.
struct VaultRuntime {
    VaultState state;
    // Timestamps
    uint40 openStartTime;
    uint40 openEndTime;
    uint40 lockStartTime;
    uint40 lockEndTime;
    uint40 settlementDeadline;
    // Accounting
    uint256 totalRaised;
    uint256 totalOwed; // totalRaised + totalInterest, set at lock start
    uint256 initialCollateralSupplied;
    uint256 initialCollateralValuation; // USD snapshot at first deposit
    uint256 settlementAmount;
    // One-time flags
    bool fundsWithdrawn; // true after claimRaisedFunds()
    bool protocolShareSettled; // true after transferProtocolShare()
    bool isActive; // true when openVault() called; false when closeVault() called
}

/// @notice Summary info returned by controller registry views.
struct VaultStateInfo {
    address vault;
    VaultState state;
    address institutionOperator;
    uint256 totalRaised;
    uint256 outstandingDebt;
}
