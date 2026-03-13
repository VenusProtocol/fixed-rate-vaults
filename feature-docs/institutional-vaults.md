# Institutional Vaults — Decision Log

## Summary
On-chain collateral, fixed-rate institutional lending via ERC-4626 vaults deployed as EIP-1167 clones.

## Key Design Decisions

### 1. BaseVault Extracted — InstitutionalLoanVault Inherits BaseVault
**Decision:** `BaseVault` (`src/BaseVault.sol`) is an abstract contract providing shared ERC-4626 mechanics, fundraising, interest, settlement (protocol fee waterfall), and core state machine. `InstitutionalLoanVault` inherits it and adds collateral, borrowing, risk checks, and liquidation.
**Why:** Per the Unified Vault Architecture, the fundraising process is identical across vault types. Extracting BaseVault now enables the future CeffuVault to reuse the same base without duplication. `IVaultController` provides the minimal shared interface (PSR, comptroller) that BaseVault needs; `IInstitutionalVaultController` extends it with Institutional Vault-specific methods.
**What lives where:**
- BaseVault: `_checkAndAdvanceState()` (Fundraising→Lock/Failed, Lock→PendingSettlement, PendingSettlement→Matured/SDE, SDE→Matured, Lock→Matured), `_advanceFromOpen()`, `_settleProtocolShare()`, `_computeTotalInterest()`, `_outstandingDebt()`, `outstandingDebt()`, `totalAssets()`, deposit/mint clamping, `_withdraw()`, `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem`, `closeVault()`, `pause()`/`unpause()`, `updateVaultState()`, `config()`/`runtime()`/`state()` views. Storage: `_config`, `_runtime`, `vaultController`.
- InstitutionalLoanVault: `depositCollateral()`/`withdrawCollateral()`, `claimRaisedFunds()`, `repay()`, `repayBadDebt()`, `liquidate()`/`liquidateOverdueVault()`, `openVault()` (pre-calculates all timeline values), risk setters, oracle helpers. Storage: `_riskConfig`, `positionToken`, `liquidationAdapter`.
- `_outstandingDebt()` is concrete in BaseVault (balance-based: `totalOwed - balanceOf(supplyAsset)`) — universal across vault types.

### 2. OZ v4.9 (Not v5)
**Decision:** Using OpenZeppelin v4.9 contracts (ERC4626Upgradeable, ERC721, Ownable2Step, ReentrancyGuardUpgradeable, PausableUpgradeable).
**Why:** The submodules in lib/ are v4.9. ERC721 uses `_beforeTokenTransfer` (not `_update`), Ownable has no constructor args.

### 3. InstitutionPositionToken is Non-Upgradeable
**Decision:** Plain ERC721 + Ownable2Step, deployed once. Ownership transferred to VaultController after deployment.
**Why:** Logic is minimal (mint, transfer control). No upgrade path needed. Reduces attack surface.

### 4. ACM Centralized in Controller + LiquidationAdapter
**Decision:** Vaults have no ACM. All governance-gated vault operations proxied through VaultController (which holds AccessControlledV8). LiquidationAdapter also holds ACM for whitelist and config management.
**Why:** Per-vault ACM configuration overhead eliminated. Single governance surface per vault type.

### 5. closeFactor is Global (in LiquidationAdapter, not per-vault)
**Decision:** `closeFactor` lives in LiquidationAdapter, not in per-vault RiskConfig.
**Why:** Simplifies per-vault config. All vaults share the same close factor. Controller reads it from adapter during liquidateAllowed/liquidateOverdueAllowed.

### 6. Two Liquidation Paths (HF-Based + Deadline-Based)
**Decision:** Separate `liquidate()` (uses liquidationIncentive) and `liquidateOverdueVault()` (uses latePenaltyRate) entry points on the vault. Independent whitelists on the adapter.
**Why:** Different penalty rates for different scenarios. Both can run in parallel when SettlementDeadlineExceeded + LT shortfall.

### 7. Protocol Share Accrued in Adapter (Not Per-Liquidation PSR Transfer)
**Decision:** LiquidationAdapter accrues protocol share and governance sweeps to PSR via `sweepProtocolShareToReserve()`.
**Why:** Batches PSR transfers for gas efficiency. Each liquidation only updates internal accounting.

### 8. No Intermediate State on Early Cap Fill — Predictable Lock Timing
**Decision:** When max cap is reached before the fundraising window expires, the vault stays in `Fundraising` — no intermediate state. `maxDeposit()` returns 0, blocking further deposits. Lock only starts when `openEndTime` is reached via `_advanceFromOpen()`. All timeline values (`lockStartTime`, `lockEndTime`, `settlementDeadline`) are pre-calculated in `openVault()`.
**Why:** Predictability for suppliers — the fundraising window always runs its full duration. The `InstitutionConfirmation` enum value (formerly `FundraisingClosed`) is reserved for subcontract use (e.g. Ceffu PendingFill) but not used by BaseVault or InstitutionalLoanVault.
**Transitions:**
- `Fundraising → Lock`: `timeReached && minMet` (via `_advanceFromOpen`)
- `Fundraising → Failed`: `timeReached && !minMet`

### 9. Settlement via _checkAndAdvanceState (Not Separate Function)
**Decision:** `transferProtocolShare()` is called inline from `_checkAndAdvanceState()` when transitioning to Matured. The `protocolShareSettled` flag prevents double execution.
**Why:** Atomic — state transition and settlement happen in the same transaction. No window between state change and fund distribution.

### 10. Collateral Naming & Dynamic Floor (initialCollateral / minimumCollateralRequired)
**Decision:** `VaultConfig.initialCollateral` (immutable) is the CF-based collateral amount sized for `maxBorrowCap`, pre-calculated at deployment. `VaultRuntime.minimumCollateralRequired` (mutable) is the locked collateral floor — starts equal to `initialCollateral` at first deposit, then recalculated proportionally at Lock: `initialCollateral × totalRaised / maxBorrowCap`. This frees excess collateral when less than max is raised.
**Why:** If the fundraising only raises 60% of max, locking 100% of initial collateral is unnecessarily punitive. Proportional recalculation uses the CF implicitly (baked into `initialCollateral`) without needing oracle calls at Lock time.
**Withdrawal rules during Lock:**
1. Floor check: `amount ≤ balance − minimumCollateralRequired` (can't touch locked portion)
2. LT-based HF check via `withdrawAllowed()` on remaining excess — ensures withdrawal doesn't make vault liquidatable

### 11. CF Only for Sizing, LT Only for Liquidation/Withdrawal Checks
**Decision:** `collateralFactor` is used exclusively for sizing `initialCollateral` (at deployment) and `minimumCollateralRequired` (at Lock). It is NOT used in runtime HF checks. `liquidationThreshold` is the sole parameter for liquidation eligibility and withdrawal health checks. `setLiquidationThreshold` no longer validates `LT > CF`.
**Why:** With `minimumCollateralRequired` properly encoding the CF-based floor, a separate CF-gated HF check is redundant. LT handles the "is this vault safe to withdraw from / eligible for liquidation" question independently.

## Gotchas
- **OZ v4.9 ERC4626Upgradeable uses IERC20Upgradeable** — not IERC20. The vault wraps IERC20 from OZ non-upgradeable for SafeERC20 operations on config assets.
- **Collateral floor recalculated at Lock**: `minimumCollateralRequired` may differ from the initially deposited amount if `totalRaised < maxBorrowCap`. Institution can withdraw the freed excess (subject to LT check).
- **Outstanding debt uses balance-based derivation**: `totalOwed - balanceOf(supplyAsset)`. No cumulative borrow/repay tracking.
- **Shares are freely transferable** during Lock — no transfer restriction.
