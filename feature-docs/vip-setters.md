# VIP Configuration — Setter Functions

All access-controlled setters across the institutional vault contracts that need values set in a VIP.

---

## InstitutionalVaultController

**File:** `src/institutional-vault/InstitutionalVaultController.sol`

### Initialization (one-time)

| Function | Parameters | Notes |
|----------|-----------|-------|
| `initialize(...)` | `vaultImplementation`, `oracle`, `protocolShareReserve`, `comptroller`, `treasury`, `positionToken`, `acm` | One-time proxy setup |
| `acceptPositionTokenOwnership()` | — | Must be called after PositionToken transfers ownership |
| `setLiquidationAdapter(address)` | Liquidation adapter address | Required before any liquidations can happen |

### Address Setters (only if changing post-init)

| Function | Parameters |
|----------|-----------|
| `setVaultImplementation(address)` | Vault implementation address |
| `setOracle(address)` | ResilientOracle address |
| `setProtocolShareReserve(address)` | PSR address |
| `setComptroller(address)` | Comptroller address |
| `setTreasury(address)` | Treasury address |

### Per-Vault Risk Setters (called via controller, forwarded to vault)

| Function | Parameters | Constraints |
|----------|-----------|-------------|
| `setLiquidationThreshold(vault, newLT)` | vault address, threshold mantissa | `0 < newLT <= 1e18` |
| `setLiquidationIncentive(vault, newLI)` | vault address, incentive mantissa | `1e18 < newLI <= 1.5e18` |
| `setLatePenaltyRate(vault, newRate)` | vault address, penalty rate mantissa | `1e18 < newRate <= 1.5e18` |

> Risk params are passed in the config struct at `createVault()`. These setters are only for post-creation adjustments.

---

## LiquidationAdapter

**File:** `src/institutional-vault/LiquidationAdapter.sol`

### Initialization (one-time)

| Function | Parameters | Constraints |
|----------|-----------|-------------|
| `initialize(...)` | `vaultController`, `protocolLiquidationShare`, `closeFactor`, `acm` | One-time proxy setup |

### Post-Init Setters

| Function | Parameters | Constraints |
|----------|-----------|-------------|
| `setProtocolLiquidationShare(uint256)` | Share mantissa | `<= 1e18` |
| `setCloseFactor(uint256)` | Close factor mantissa | `0 < cf <= 1e18` |
| `setLiquidatorWhitelist(address, bool)` | Liquidator address, approved flag | Can batch multiple calls |
| `setSettlerWhitelist(address, bool)` | Settler address, approved flag | Can batch multiple calls |

---

## Typical VIP Execution Order

1. **Deploy** — PositionToken, Controller (proxy), LiquidationAdapter (proxy), Vault implementation
2. **Initialize** — `controller.initialize(...)`, `liquidationAdapter.initialize(...)`
3. **Wire up** — `controller.acceptPositionTokenOwnership()`, `controller.setLiquidationAdapter(adapter)`
4. **Whitelist** — `adapter.setLiquidatorWhitelist(...)`, `adapter.setSettlerWhitelist(...)`
5. **ACM permissions** — Grant roles for `createVault`, `openVault`, risk setters, pause/close, sweep, etc.
6. **Per-vault** — `createVault(...)` (risk params passed in config struct; setters only needed for later adjustments)
