// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared vault lifecycle states — single enum for all vault types (Institutional Vault, Ceffu).
///         Each vault type uses a subset; unused states are simply skipped in transitions.
enum VaultState {
    WaitingForMargin, // 0 — Institutional Vault: awaiting institution margin deposit; Ceffu: skipped
    MarginDeposited, // 1 — Institutional Vault: margin in, awaiting open; Ceffu: skipped
    Fundraising, // 2 — suppliers deposit supply asset (both)
    InstitutionConfirmation, // 3 — reserved for subcontract use (e.g. Ceffu PendingFill)
    Lock, // 4 — funds committed, interest accruing (both)
    PendingSettlement, // 5 — maturity reached, awaiting repayment (both)
    SettlementDeadlineExceeded, // 6 — settlement deadline passed with outstanding debt (both)
    Matured, // 7 — settlement complete, shares redeemable (both)
    Failed, // 8 — fundraising below min cap OR institution default (both; Ceffu: Cancelled)
    Liquidated, // 9 — Institutional Vault: bad-debt rescue; Ceffu: N/A
    Closed // 10 — governance delisted; Ceffu uses this; Institutional Vault uses isActive flag
}

/// @notice Shared immutable configuration set once at vault initialization.
///         Fields grouped by domain: asset, rates, caps, timing.
struct VaultConfig {
    // ── Asset ──
    IERC20 supplyAsset;
    // ── Rates ──
    uint256 fixedAPY; // basis points (800 = 8%)
    uint256 reserveFactor; // mantissa (0.1e18 = 10%)
    // ── Caps ──
    uint256 minBorrowCap;
    uint256 maxBorrowCap;
    uint256 minSupplierDeposit; // minimum deposit in supply asset units; 0 = disable
    // ── Timing ──
    uint40 openDuration;
    uint40 lockDuration;
    uint40 settlementWindow;
}

/// @notice Shared runtime state that changes as the vault progresses through its lifecycle.
///         Fields grouped by domain: lifecycle, timing, accounting, flags.
struct VaultRuntime {
    // ── Lifecycle ──
    VaultState state;
    bool isActive;
    // ── Timing ──
    uint40 openStartTime;
    uint40 openEndTime;
    uint40 lockStartTime;
    uint40 lockEndTime;
    uint40 settlementDeadline;
    // ── Accounting ──
    uint256 totalRaised;
    uint256 totalOwed; // totalRaised + totalInterest, set at lock start
    uint256 settlementAmount;
    // ── Flags ──
    bool fundsWithdrawn; // true after claimRaisedFunds()
    bool protocolShareSettled; // true after _settleProtocolShare()
}
