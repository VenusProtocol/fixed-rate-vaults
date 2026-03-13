// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared vault lifecycle states — single enum for all vault types (Institutional Vault, Ceffu).
///         Each vault type uses a subset; unused states are simply skipped in transitions.
enum VaultState {
    WaitingForCollateral, // 0 — Institutional Vault: awaiting institution collateral; Ceffu: skipped
    CollateralDeposited, // 1 — Institutional Vault: collateral in, awaiting open; Ceffu: skipped
    Fundraising, // 2 — suppliers deposit supply asset (both)
    InstitutionConfirmation, // 3 — reserved for subcontract use (e.g. Ceffu PendingFill)
    Lock, // 4 — funds committed, interest accruing (both)
    PendingSettlement, // 5 — maturity reached, awaiting repayment (both)
    SettlementDeadlineExceeded, // 6 — settlement deadline passed with outstanding debt (both)
    Matured, // 7 — settlement complete, shares redeemable (both)
    Failed, // 8 — fundraising below min cap (both; Ceffu: Cancelled)
    Liquidated, // 9 — Institutional Vault: bad-debt rescue; Ceffu: N/A
    Closed // 10 — governance delisted; Ceffu uses this; Institutional Vault uses isActive flag
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
    uint256 initialCollateralRequired; // sized for maxBorrowCap at deployment (off-chain via CF); institution must deposit >= this
    uint256 fixedAPY; // basis points (800 = 8%)
    uint256 minBorrowCap;
    uint256 maxBorrowCap;
    uint40 openDuration;
    uint40 lockDuration;
    uint40 settlementWindow;
    uint256 reserveFactor; // mantissa (0.1e18 = 10%)
    address institutionOperator; // initial position token recipient
    uint256 positionTokenId; // token representing institution position
    uint256 minSupplierDeposit; // minimum deposit in supply asset units; 0 = disable
}

/// @notice Risk parameters — LT/LI/latePenaltyRate mutable via VaultController.
struct RiskConfig {
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
    uint256 minimumCollateralRequired; // locked floor; initially = initialCollateralRequired, recalculated at Lock based on totalRaised
    uint256 totalCollateralDeposited; // cumulative collateral deposited by institution (decremented on withdrawal)
    uint256 initialCollateralRequiredValuation; // USD snapshot at first deposit
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
