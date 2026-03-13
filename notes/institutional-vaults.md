# Institutional Vaults — Decision Log

## Summary
On-chain collateral, fixed-rate institutional lending via ERC-4626 vaults deployed as EIP-1167 clones.

## Key Design Decisions

### 1. BaseVault Extracted — InstitutionalLoanVault Inherits BaseVault
**Decision:** `BaseVault` (`src/BaseVault.sol`) is an abstract contract providing shared ERC-4626 mechanics, fundraising, interest, settlement (protocol fee waterfall), and core state machine. `InstitutionalLoanVault` inherits it and adds collateral, borrowing, risk checks, and liquidation.
**Why:** Per the Unified Vault Architecture, the fundraising process is identical across vault types. Extracting BaseVault now enables the future CeffuVault to reuse the same base without duplication. `IVaultController` provides the minimal shared interface (PSR, comptroller) that BaseVault needs; `IInstitutionalVaultController` extends it with FRIV-specific methods.
**What lives where:**
- BaseVault: `_checkAndAdvanceState()` (Open→Lock/Failed, Lock→PendingSettlement, PendingSettlement→Matured/SDE, SDE→Matured, Lock→Matured), `_settleProtocolShare()`, `_computeTotalInterest()`, `totalAssets()`, deposit/mint clamping, `_withdraw()`, `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem`, `closeVault()`, `pause()`/`unpause()`, `updateVaultState()`, `config()`/`runtime()`/`state()` views. Storage: `_config`, `_runtime`, `vaultController`.
- InstitutionalLoanVault: `_outstandingDebt()` override (balance-based), `depositCollateral()`/`withdrawCollateral()`, `claimRaisedFunds()`, `repay()`, `repayBadDebt()`, `liquidate()`/`liquidateOverdueVault()`, `openVault()`, risk setters, oracle helpers. Storage: `_riskConfig`, `positionNFT`, `liquidationAdapter`.
- `_outstandingDebt()` is `internal view virtual` in BaseVault — each vault type defines its own debt derivation.

### 2. OZ v4.9 (Not v5)
**Decision:** Using OpenZeppelin v4.9 contracts (ERC4626Upgradeable, ERC721, Ownable2Step, ReentrancyGuardUpgradeable, PausableUpgradeable).
**Why:** The submodules in lib/ are v4.9. ERC721 uses `_beforeTokenTransfer` (not `_update`), Ownable has no constructor args.

### 3. InstitutionPositionNFT is Non-Upgradeable
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

### 8. Settlement via _checkAndAdvanceState (Not Separate Function)
**Decision:** `transferProtocolShare()` is called inline from `_checkAndAdvanceState()` when transitioning to Matured. The `protocolShareSettled` flag prevents double execution.
**Why:** Atomic — state transition and settlement happen in the same transaction. No window between state change and fund distribution.

## Gotchas
- **OZ v4.9 ERC4626Upgradeable uses IERC20Upgradeable** — not IERC20. The vault wraps IERC20 from OZ non-upgradeable for SafeERC20 operations on config assets.
- **Two-tier collateral**: initial collateral locked until Matured, top-up collateral LT-gated during Lock.
- **Outstanding debt uses balance-based derivation**: `totalOwed - balanceOf(supplyAsset)`. No cumulative borrow/repay tracking.
- **Shares are freely transferable** during Lock — no transfer restriction.
