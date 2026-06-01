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

### 9. Settlement via \_checkAndAdvanceState (Not Separate Function)

**Decision:** `transferProtocolShare()` is called inline from `_checkAndAdvanceState()` when transitioning to Matured. The `protocolShareSettled` flag prevents double execution.
**Why:** Atomic — state transition and settlement happen in the same transaction. No window between state change and fund distribution.

### 10. Margin Deposit Mechanism (v1.6 — replaces full upfront collateral)

**Decision:** Institution deposits only a margin (x% of `idealCollateralAmount`) upfront to enter `MarginDeposited`. During the Open period, the institution deposits the remaining collateral alongside lender fundraising. Full collateral (`idealCollateralAmount`) must be reached by Open end to enter Lock.
**Why:** Full upfront collateral caused high capital lockup and participation barriers. Margin reduces the entry barrier while a confiscation mechanism protects lenders if the institution defaults.
**State renames:** `WaitingForCollateral` → `WaitingForMargin`, `CollateralDeposited` → `MarginDeposited`.
**Config changes:** `initialCollateralRequired` → `idealCollateralAmount`, added `marginRate` (mantissa).
**Margin amount:** `idealCollateralAmount × marginRate / 1e18`. Cumulative deposits in `WaitingForMargin` must reach this threshold.

### 11. Collateral Naming & Dynamic Floor (idealCollateralAmount / minimumCollateralRequired)

**Decision:** `VaultConfig.idealCollateralAmount` (immutable) is the CF-based collateral amount sized for `maxBorrowCap`, pre-calculated at deployment. `VaultRuntime.minimumCollateralRequired` (mutable) is the locked collateral floor — recalculated proportionally at Lock: `idealCollateralAmount × totalRaised / maxBorrowCap`. This frees excess collateral when less than max is raised.
**Why:** If the fundraising only raises 60% of max, locking 100% of ideal collateral is unnecessarily punitive. Proportional recalculation uses the CF implicitly (baked into `idealCollateralAmount`) without needing oracle calls at Lock time.
**Withdrawal rules during Lock:**

1. Floor check: `amount ≤ balance − minimumCollateralRequired` (can't touch locked portion)
2. LT-based HF check via `_getHypotheticalVaultLiquidity()` on remaining excess — ensures withdrawal doesn't make vault liquidatable

### 12. CF Only for Sizing, LT Only for Liquidation/Withdrawal Checks

**Decision:** `collateralFactor` is used exclusively for sizing `idealCollateralAmount` (at deployment) and `minimumCollateralRequired` (at Lock). It is NOT used in runtime HF checks. `liquidationThreshold` is the sole parameter for liquidation eligibility and withdrawal health checks. `setLiquidationThreshold` no longer validates `LT > CF`.
**Why:** With `minimumCollateralRequired` properly encoding the CF-based floor, a separate CF-gated HF check is redundant. LT handles the "is this vault safe to withdraw from / eligible for liquidation" question independently.

### 13. Two Failure Scenarios with Margin Confiscation (v1.6)

**Decision:** Failed state now has two scenarios:

- **Scenario A** (Raised < minCap): Full refund to lenders, institution gets all collateral back (no confiscation).
- **Scenario B** (Raised ≥ minCap but collateral < idealCollateral): Institution's margin is confiscated and distributed pro-rata to lenders. Institution can withdraw remaining non-margin collateral.
  **Why:** If fundraising succeeds but the institution fails to deliver collateral, lenders should be compensated for the opportunity cost. If fundraising itself fails, the institution is not at fault.
  **Implementation:** `VaultRuntime.institutionDefaulted` flag distinguishes the scenarios. `confiscatedMarginRemaining` tracks margin left for lender distribution. Compensation is distributed via `_afterWithdraw` hook — each lender receives `confiscatedMarginRemaining × sharesRedeemed / totalSupplyBeforeBurn` of collateral asset alongside their supply asset refund.

### 12. Vault Ownership is Transferable via PositionToken (Not Tied to Institution Address)

**Decision:** Position-holder gated functions (`depositCollateral`, `withdrawCollateral`, `claimRaisedFunds`) check `positionToken.ownerOf(positionTokenId)` — the current NFT owner — not the institution address stored at deployment. The modifier is named `onlyPositionHolder` to reflect this.
**Why:** The institution address is used for deployment and vault association, but the PositionToken is the actual ownership credential. If the institution transfers the token, the new holder gains full control of position-gated operations. This enables institutional vault ownership to be delegated or transferred without redeployment.

### 14. Struct Split — Logical Domain Grouping (BaseVault / Extension)

**Decision:** Split the monolithic `VaultConfig` and `VaultRuntime` into shared base structs (`IVaultTypes.sol`) and vault-type-specific extension structs (`IInstitutionalVaultTypes.sol`, future `ICeffuVaultTypes.sol`). Fields are grouped by logical domain within each struct.
**Why:** The original structs mixed shared and vault-type-specific fields. CeffuVault would carry 10 dead fields (5 config + 5 runtime) per clone. Splitting by domain makes each struct self-documenting and eliminates dead storage in future vault types.
**Shared types (`IVaultTypes.sol`):**

- `VaultState` enum — single enum for all vault types; unused states are skipped in transitions
- `VaultConfig` — asset, rates (fixedAPY, reserveFactor), caps (minBorrowCap, maxBorrowCap, minSupplierDeposit), timing (openDuration, lockDuration, settlementWindow)
- `VaultRuntime` — lifecycle (state, isActive), timing (openStartTime…settlementDeadline), accounting (totalRaised, totalOwed, settlementAmount), flags (fundsWithdrawn, protocolShareSettled)

**Institutional extension (`IInstitutionalVaultTypes.sol`):**

- `InstitutionalConfig` — asset (collateralAsset), collateral sizing (idealCollateralAmount, marginRate), position identity (institutionOperator, positionTokenId)
- `InstitutionalRuntime` — collateral accounting (totalCollateralDeposited, minimumCollateralRequired, idealCollateralValuation), margin confiscation (confiscatedMarginRemaining, institutionDefaulted)
- `RiskConfig`, `LiquidationType` — unchanged, institutional-only

**Storage layout:**

- `BaseVault`: `VaultConfig _config`, `VaultRuntime _runtime`, `address vaultController`
- `InstitutionalLoanVault` (extends BaseVault): adds `InstitutionalConfig _instConfig`, `InstitutionalRuntime _instRuntime`, `RiskConfig _riskConfig`, plus `positionToken` and `liquidationAdapter`

**Impact:** BaseVault logic is unchanged — every `_config.*` / `_runtime.*` reference already only touches base-eligible fields. InstitutionalLoanVault changes are mechanical renames (`_config.collateralAsset` → `_instConfig.collateralAsset`, etc.). View getters: BaseVault exposes `config()` / `runtime()` returning base structs; InstitutionalLoanVault adds `institutionalConfig()` / `institutionalRuntime()`.

### 15. Future CeffuVault — Architecture Notes

**Planned extension structs (`ICeffuVaultTypes.sol`):**

- `CeffuConfig` — Ceffu integration (ceffuRequestId, fundRouter, gracePeriod)
- `CeffuRuntime` — order lifecycle (orderFilled, etc.)

**Storage layout:** `CeffuVault` inherits `_config` / `_runtime` from BaseVault, adds only `CeffuConfig _ceffuConfig` and `CeffuRuntime _ceffuRuntime`. Zero dead fields.

**Lifecycle differences:**

- Skips `WaitingForMargin` / `MarginDeposited` — starts at `Fundraising`
- `_advanceFromOpen()` override: Fundraising → `InstitutionConfirmation` (PendingFill) if minCap met, else Failed
- `confirmOrderFill()` — controller-gated, transitions InstitutionConfirmation → Lock, calls `_claimRaisedFunds(fundRouter)`
- `receiveRepayment()` — FundRouter pushes repayment, wraps `_repay()`
- No collateral, no liquidation, no risk config, no oracle
- No `_afterWithdraw` override needed — empty default is correct

**What it reuses from BaseVault (zero changes):** ERC-4626 deposit/mint/withdraw/redeem, fundraising clamping, `_checkAndAdvanceState()` (Lock→PendingSettlement→Matured/SDE), `_settleProtocolShare()`, `_computeTotalInterest()`, `_outstandingDebt()`, `_repay()`, `_claimRaisedFunds()`, `closeVault()`/`pause()`/`unpause()`.

## Gotchas

- **OZ v4.9 ERC4626Upgradeable uses IERC20Upgradeable** — not IERC20. The vault wraps IERC20 from OZ non-upgradeable for SafeERC20 operations on config assets.
- **Collateral floor recalculated at Lock**: `minimumCollateralRequired` may differ from the ideal amount if `totalRaised < maxBorrowCap`. Institution can withdraw the freed excess (subject to LT check).
- **Outstanding debt uses balance-based derivation**: `totalOwed - balanceOf(supplyAsset)`. No cumulative borrow/repay tracking.
- **Shares are freely transferable** during Lock — no transfer restriction.
- **PositionToken transfer changes vault control**: `onlyPositionHolder` follows token ownership, not the stored institution address. If the token is transferred, the original institution loses access to collateral ops and fund claims.
- **Margin compensation is in collateral asset**: When lenders redeem in Failed Scenario B, they receive supply asset (refund) + collateral asset (margin compensation) in the same transaction. The ERC-4626 share pricing only reflects the supply asset — margin compensation is an additional bonus.
- **Margin compensation rounding**: Last lender to redeem may receive slightly less collateral due to integer division rounding. The dust amount is negligible.
- **Institution must deposit full idealCollateralAmount by Open end** regardless of how much was raised. Excess can be withdrawn after Lock entry.
