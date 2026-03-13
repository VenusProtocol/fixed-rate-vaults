// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { MathUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { VaultConfig, VaultRuntime, VaultState } from "./interfaces/IInstitutionalVaultTypes.sol";
import { IVaultController } from "./interfaces/IVaultController.sol";
import { IProtocolShareReserve } from "./interfaces/IProtocolShareReserve.sol";

/// @title BaseVault
/// @notice Abstract base ERC-4626 vault providing shared mechanics for all Venus fixed-rate vault types:
///         fundraising (time-bounded deposit window), interest computation, settlement (protocol fee waterfall),
///         and core state machine transitions.
/// @dev Subcontracts (InstitutionalLoanVault, future CeffuVault) inherit this and add type-specific logic.
///      Deployed as EIP-1167 minimal proxy clones by the respective VaultController.
abstract contract BaseVault is ERC4626Upgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MANTISSA = 1e18;
    uint256 internal constant YEAR = 365 days;

    // ──────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Immutable vault configuration set at initialization.
    VaultConfig internal _config;

    /// @notice Runtime state that changes during the vault lifecycle.
    VaultRuntime internal _runtime;

    /// @notice VaultController address — set to msg.sender during initialize.
    address public vaultController;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event StateTransition(VaultState indexed from, VaultState indexed to, uint256 timestamp);
    event VaultLocked(uint256 totalRaised, uint256 lockEndTime);
    event VaultFailed(uint256 totalRaised, uint256 minBorrowCap);
    event VaultClosed(VaultState state);
    event SettlementConfirmed(uint256 settlementAmount, uint256 protocolFee);
    event ShortfallDetected(uint256 totalOwed, uint256 available);
    event ProtocolFeePaid(uint256 amount);
    event SurplusTransferred(uint256 amount);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidState();
    error BelowMinimumDeposit();
    error ExceedsMaxCap();
    error Unauthorized();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier onlyController() {
        if (msg.sender != vaultController) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Controller-gated (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Deactivates vault. Vault stays in terminal state; isActive flag set to false.
    /// @custom:error InvalidState If vault is not in a terminal state (Matured/Failed/Liquidated).
    function closeVault() external onlyController {
        VaultState s = _runtime.state;
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) revert InvalidState();
        _runtime.isActive = false;
        emit VaultClosed(s);
    }

    /// @notice Emergency pause — blocks deposits and collateral operations.
    function pause() external onlyController {
        _pause();
    }

    /// @notice Removes emergency pause.
    function unpause() external onlyController {
        _unpause();
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Permissionless (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Permissionless vault finalizer. Triggers state transitions and settlement.
    function updateVaultState() external {
        _checkAndAdvanceState();
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — View
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns the vault configuration.
    /// @return Immutable VaultConfig struct set at initialization.
    function config() external view returns (VaultConfig memory) {
        return _config;
    }

    /// @notice Returns the runtime state.
    /// @return Mutable VaultRuntime struct tracking lifecycle progress.
    function runtime() external view returns (VaultRuntime memory) {
        return _runtime;
    }

    /// @notice Current vault lifecycle state.
    /// @return Current VaultState enum value.
    function state() external view returns (VaultState) {
        return _runtime.state;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Public — ERC-4626 Overrides (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Deposits supply assets. Clamps to remaining capacity instead of reverting on excess.
    /// @param assets Requested deposit amount in supply asset units.
    /// @param receiver Address to receive minted shares.
    /// @return shares Actual shares minted (may be less than requested if cap approached).
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        uint256 maxAllowed = maxDeposit(receiver);
        uint256 assetsClamped = assets > maxAllowed ? maxAllowed : assets;
        if (assetsClamped == 0) revert ExceedsMaxCap();
        shares = previewDeposit(assetsClamped);
        _deposit(_msgSender(), receiver, assetsClamped, shares);
    }

    /// @notice Mints shares. Clamps to remaining capacity instead of reverting on excess.
    /// @param shares Requested shares to mint.
    /// @param receiver Address to receive minted shares.
    /// @return assets Actual supply assets pulled (may be less than requested if cap approached).
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        uint256 maxSharesAllowed = maxMint(receiver);
        uint256 sharesClamped = shares > maxSharesAllowed ? maxSharesAllowed : shares;
        if (sharesClamped == 0) revert ExceedsMaxCap();
        assets = previewMint(sharesClamped);
        _deposit(_msgSender(), receiver, assets, sharesClamped);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Public — ERC-4626 Overrides (view)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice State-dependent total assets backing outstanding shares.
    /// @dev Before Lock: actual balance. During Lock: totalRaised. Post-lock/terminal: balance.
    /// @return Total assets in supply asset units.
    function totalAssets() public view override returns (uint256) {
        VaultState s = _runtime.state;

        if (s == VaultState.Lock) {
            return _runtime.totalRaised;
        }

        // WaitingForCollateral, CollateralDeposited, Open, PendingSettlement,
        // SettlementDeadlineExceeded, Matured, Failed, Liquidated
        return IERC20(address(_config.supplyAsset)).balanceOf(address(this));
    }

    /// @notice Remaining deposit capacity in supply asset units. Zero outside Open state.
    /// @param  /*receiver*/ Unused (no per-user limits).
    /// @return Maximum depositable amount.
    function maxDeposit(address) public view override returns (uint256) {
        if (_runtime.state != VaultState.Open) return 0;
        return _config.maxBorrowCap - _runtime.totalRaised;
    }

    /// @notice Share equivalent of maxDeposit.
    /// @param receiver Receiver address (passed through to maxDeposit).
    /// @return Maximum mintable shares.
    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), MathUpgradeable.Rounding.Down);
    }

    /// @notice Withdrawable supply asset amount for a supplier. Zero outside terminal states.
    /// @param owner Share holder address.
    /// @return Maximum withdrawable supply asset amount.
    function maxWithdraw(address owner) public view override returns (uint256) {
        VaultState s = _runtime.state;
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            return previewRedeem(balanceOf(owner));
        }
        return 0;
    }

    /// @notice Redeemable share amount for a supplier. Zero outside terminal states.
    /// @param owner Share holder address.
    /// @return Maximum redeemable share amount.
    function maxRedeem(address owner) public view override returns (uint256) {
        VaultState s = _runtime.state;
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            return balanceOf(owner);
        }
        return 0;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Initialization
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Initializes the base vault. Called by subcontract initializers.
    /// @param asset_ Supply asset (ERC-4626 underlying).
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    /// @param vaultController_ VaultController address (msg.sender of the deploy tx).
    function __BaseVault_init(
        IERC20Upgradeable asset_,
        string memory name_,
        string memory symbol_,
        address vaultController_
    ) internal onlyInitializing {
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        __Pausable_init();
        vaultController = vaultController_;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — State Machine (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Handles all time-based and condition-based auto-transitions.
    ///      Called at the start of every state-changing external function.
    ///      Subcontracts may override to extend with type-specific transitions.
    function _checkAndAdvanceState() internal virtual {
        VaultState s = _runtime.state;

        // Open -> Lock or Failed
        if (s == VaultState.Open) {
            _advanceFromOpen();
            return;
        }

        // Lock -> PendingSettlement (fall through to PS check)
        if (s == VaultState.Lock && block.timestamp >= _runtime.lockEndTime) {
            _runtime.state = VaultState.PendingSettlement;
            _runtime.settlementDeadline = uint40(block.timestamp) + _config.settlementWindow;
            emit StateTransition(VaultState.Lock, VaultState.PendingSettlement, block.timestamp);
            s = VaultState.PendingSettlement;
        }

        // PendingSettlement -> Matured or SettlementDeadlineExceeded
        if (s == VaultState.PendingSettlement) {
            uint256 debt = _outstandingDebt();
            if (debt == 0 && block.timestamp >= _runtime.lockEndTime) {
                _runtime.state = VaultState.Matured;
                emit StateTransition(VaultState.PendingSettlement, VaultState.Matured, block.timestamp);
                _settleProtocolShare();
                return;
            }
            if (block.timestamp > _runtime.settlementDeadline && debt > 0) {
                _runtime.state = VaultState.SettlementDeadlineExceeded;
                emit StateTransition(
                    VaultState.PendingSettlement, VaultState.SettlementDeadlineExceeded, block.timestamp
                );
                return;
            }
        }

        // SettlementDeadlineExceeded -> Matured
        if (
            s == VaultState.SettlementDeadlineExceeded && _outstandingDebt() == 0
                && block.timestamp >= _runtime.lockEndTime
        ) {
            _runtime.state = VaultState.Matured;
            emit StateTransition(VaultState.SettlementDeadlineExceeded, VaultState.Matured, block.timestamp);
            _settleProtocolShare();
            return;
        }

        // Lock -> Matured (early repayment — debt cleared and lock passed)
        if (s == VaultState.Lock && _outstandingDebt() == 0 && block.timestamp >= _runtime.lockEndTime) {
            _runtime.state = VaultState.Matured;
            emit StateTransition(VaultState.Lock, VaultState.Matured, block.timestamp);
            _settleProtocolShare();
            return;
        }
    }

    /// @dev Open -> Lock or Failed transitions. Extracted to reduce _checkAndAdvanceState complexity.
    function _advanceFromOpen() internal {
        bool timeReached = block.timestamp >= _runtime.openEndTime;
        bool minMet = _runtime.totalRaised >= _config.minBorrowCap;
        bool maxReached = _runtime.totalRaised >= _config.maxBorrowCap;

        if (timeReached && !minMet) {
            _runtime.state = VaultState.Failed;
            emit StateTransition(VaultState.Open, VaultState.Failed, block.timestamp);
            emit VaultFailed(_runtime.totalRaised, _config.minBorrowCap);
            return;
        }
        if ((timeReached && minMet) || maxReached) {
            _runtime.lockStartTime = uint40(block.timestamp);
            _runtime.lockEndTime = uint40(block.timestamp) + _config.lockDuration;
            _runtime.totalOwed = _runtime.totalRaised + _computeTotalInterest();
            _runtime.state = VaultState.Lock;
            emit StateTransition(VaultState.Open, VaultState.Lock, block.timestamp);
            emit VaultLocked(_runtime.totalRaised, _runtime.lockEndTime);
        }
    }

    /// @dev Transfers protocol fee and surplus to PSR. Sets settlementAmount.
    ///      Called once when transitioning to Matured. Guarded by protocolShareSettled flag.
    function _settleProtocolShare() internal {
        if (_runtime.protocolShareSettled) return;
        _runtime.protocolShareSettled = true;

        IERC20 supplyToken = IERC20(address(_config.supplyAsset));
        uint256 available = supplyToken.balanceOf(address(this));
        address psr = IVaultController(vaultController).protocolShareReserve();
        address comptrollerAddr = IVaultController(vaultController).comptroller();
        uint256 totalInterest = _computeTotalInterest();
        uint256 protocolFee;
        uint256 surplus;

        if (available >= _runtime.totalOwed) {
            protocolFee = (totalInterest * _config.reserveFactor) / MANTISSA;
            surplus = available - _runtime.totalOwed;
        } else if (available > _runtime.totalRaised) {
            uint256 interestAvailable = available - _runtime.totalRaised;
            protocolFee = (interestAvailable * _config.reserveFactor) / MANTISSA;
            emit ShortfallDetected(_runtime.totalOwed, available);
        } else {
            protocolFee = 0;
            emit ShortfallDetected(_runtime.totalOwed, available);
        }

        uint256 psrTotal = protocolFee + surplus;
        if (psrTotal > 0) {
            supplyToken.safeTransfer(psr, psrTotal);
            IProtocolShareReserve(psr).updateAssetsState(
                comptrollerAddr,
                address(_config.supplyAsset),
                IProtocolShareReserve.IncomeType.INSTITUTIONAL_VAULT_PROTOCOL_FEE
            );
            if (protocolFee > 0) emit ProtocolFeePaid(protocolFee);
            if (surplus > 0) emit SurplusTransferred(surplus);
        }

        _runtime.settlementAmount = available - psrTotal;
        emit SettlementConfirmed(_runtime.settlementAmount, protocolFee);
    }

    /// @dev Internal deposit — state checks, min deposit, cap enforcement via clamping in public wrappers.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        if (_runtime.state != VaultState.Open) revert InvalidState();
        if (_config.minSupplierDeposit > 0 && assets < _config.minSupplierDeposit) revert BelowMinimumDeposit();

        super._deposit(caller, receiver, assets, shares);
        _runtime.totalRaised += assets;

        _checkAndAdvanceState();
    }

    /// @dev Internal withdraw — only allowed in terminal states (Matured, Failed, Liquidated).
    ///      No pause guard — supplier safety valve.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) {
            revert InvalidState();
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — View
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Full-term interest for the entire lock duration.
    /// @return Total interest amount in supply asset units.
    function _computeTotalInterest() internal view returns (uint256) {
        return (_runtime.totalRaised * _config.fixedAPY * _config.lockDuration) / (BPS * YEAR);
    }

    /// @dev Returns the current outstanding debt. Subcontracts define derivation logic.
    ///      InstitutionalLoanVault: balance-based (totalOwed - balanceOf(supplyAsset)).
    ///      CeffuVault (future): repayment-receipt-based.
    function _outstandingDebt() internal view virtual returns (uint256);
}
