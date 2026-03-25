// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { MathUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { VaultConfig, VaultRuntime, VaultState, PauseLevel } from "./interfaces/IVaultTypes.sol";
import { IVaultController } from "./interfaces/IVaultController.sol";
import { IProtocolShareReserve } from "./interfaces/IProtocolShareReserve.sol";

/**
 * @title BaseVault
 * @notice Abstract base ERC-4626 vault providing shared mechanics for all Venus fixed-rate vault types:
 *         fundraising (time-bounded deposit window), interest computation, settlement (protocol fee waterfall),
 *         and core state machine transitions.
 * @dev Subcontracts (InstitutionalLoanVault, future CeffuVault) inherit this and add type-specific logic.
 *      Deployed as EIP-1167 minimal proxy clones by the respective VaultController.
 */
abstract contract BaseVault is ERC4626Upgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    uint256 public constant BPS = 10_000;
    uint256 public constant MANTISSA = 1e18;
    uint256 public constant YEAR = 365 days;

    // ──────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Immutable vault configuration set at initialization.
    VaultConfig internal _config;

    /// @notice Runtime state that changes during the vault lifecycle.
    VaultRuntime internal _runtime;

    /// @notice VaultController address — set to msg.sender during initialize.
    address public vaultController;

    /// @notice Current pause level (Unpaused, Partial, Complete).
    PauseLevel public pauseLevel;

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
    event PSRNotificationFailed(address indexed psr, bytes reason);
    event RaisedFundsClaimed(uint256 amount);
    event Repaid(uint256 amount, uint256 remainingDebt);
    event PauseLevelSet(PauseLevel oldLevel, PauseLevel newLevel);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidState();
    error BelowMinimumDepositAmount();
    error ExceedsMaxCap();
    error Unauthorized();
    error AlreadyWithdrawn();
    error NoOutstandingDebt();
    error PartiallyPaused();
    error CompletelyPaused();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Reverts if caller is not the VaultController.
    modifier onlyController() {
        if (msg.sender != vaultController) revert Unauthorized();
        _;
    }

    /// @dev Reverts on any pause level (Partial or Complete). Used for general operations.
    modifier whenNotPaused() {
        PauseLevel level = pauseLevel;
        if (level == PauseLevel.Partial) revert PartiallyPaused();
        if (level == PauseLevel.Complete) revert CompletelyPaused();
        _;
    }

    /// @dev Reverts only on Complete pause. Repay and liquidation remain available during Partial pause.
    modifier whenNotCompletelyPaused() {
        if (pauseLevel == PauseLevel.Complete) revert CompletelyPaused();
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Controller-gated (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deactivates vault. Vault stays in terminal state; isActive flag set to false.
     * @custom:error InvalidState If vault is not in a terminal state (Matured/Failed/Liquidated).
     * @custom:event VaultClosed Emitted with the terminal state when the vault is deactivated.
     */
    function closeVault() external onlyController {
        VaultState s = _runtime.state;
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) revert InvalidState();
        _runtime.isActive = false;
        emit VaultClosed(s);
    }

    /**
     * @notice Partial pause — blocks general operations (deposits, collateral, borrowing).
     *         Repay and liquidation remain available so positions can still be defended/resolved.
     * @custom:event PauseLevelSet
     */
    function partialPause() external onlyController {
        PauseLevel old = pauseLevel;
        pauseLevel = PauseLevel.Partial;
        emit PauseLevelSet(old, PauseLevel.Partial);
    }

    /**
     * @notice Complete pause — blocks all operations including repay and liquidation.
     * @custom:event PauseLevelSet
     */
    function completePause() external onlyController {
        PauseLevel old = pauseLevel;
        pauseLevel = PauseLevel.Complete;
        emit PauseLevelSet(old, PauseLevel.Complete);
    }

    /**
     * @notice Removes all pause restrictions.
     * @custom:event PauseLevelSet
     */
    function unpause() external onlyController {
        PauseLevel old = pauseLevel;
        pauseLevel = PauseLevel.Unpaused;
        emit PauseLevelSet(old, PauseLevel.Unpaused);
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

    /**
     * @notice Total remaining debt (totalOwed minus current supply asset balance).
     * @return Outstanding debt in supply asset units. Zero if fully repaid.
     */
    function outstandingDebt() external view returns (uint256) {
        return _outstandingDebt();
    }

    /**
     * @notice Returns the vault configuration.
     * @return Immutable VaultConfig struct set at initialization.
     */
    function config() external view returns (VaultConfig memory) {
        return _config;
    }

    /**
     * @notice Returns the runtime state.
     * @return Mutable VaultRuntime struct tracking lifecycle progress.
     */
    function runtime() external view returns (VaultRuntime memory) {
        return _runtime;
    }

    /**
     * @notice Current vault lifecycle state.
     * @return Current VaultState enum value.
     */
    function state() external view returns (VaultState) {
        return _runtime.state;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Public — ERC-4626 Overrides (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposits supply assets during the Fundraising window.
     *         Clamps to remaining capacity instead of reverting on excess.
     * @param assets Requested deposit amount in supply asset units.
     * @param receiver Address to receive minted shares.
     * @return shares Actual shares minted (may be less than requested if cap approached).
     * @custom:error ExceedsMaxCap If clamped deposit amount is zero (vault at capacity).
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        uint256 maxAllowed = maxDeposit(receiver);
        uint256 assetsClamped = assets > maxAllowed ? maxAllowed : assets;
        if (assetsClamped == 0) revert ExceedsMaxCap();
        shares = previewDeposit(assetsClamped);
        _deposit(_msgSender(), receiver, assetsClamped, shares);
    }

    /**
     * @notice Mints shares during the Fundraising window.
     *         Clamps to remaining capacity instead of reverting on excess.
     * @param shares Requested shares to mint.
     * @param receiver Address to receive minted shares.
     * @return assets Actual supply assets pulled (may be less than requested if cap approached).
     * @custom:error ExceedsMaxCap If clamped share amount is zero (vault at capacity).
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256 assets) {
        uint256 maxSharesAllowed = maxMint(receiver);
        uint256 sharesClamped = shares > maxSharesAllowed ? maxSharesAllowed : shares;
        if (sharesClamped == 0) revert ExceedsMaxCap();
        assets = previewMint(sharesClamped);
        _deposit(_msgSender(), receiver, assets, sharesClamped);
    }

    /**
     * @notice Withdraws supply assets in terminal states.
     *         Advances state before checking max, enabling single-tx withdrawals
     *         when the vault is ready to transition (e.g. PendingSettlement -> Matured).
     * @param assets Amount of supply assets to withdraw.
     * @param receiver Address to receive the assets.
     * @param owner Share holder address.
     * @return shares Shares burned.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        _checkAndAdvanceState();
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) revert ExceedsMaxCap();
        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @notice Redeems shares for supply assets in terminal states.
     *         Advances state before checking max, enabling single-tx redemptions
     *         when the vault is ready to transition (e.g. PendingSettlement -> Matured).
     * @param shares Shares to redeem.
     * @param receiver Address to receive the assets.
     * @param owner Share holder address.
     * @return assets Supply assets returned.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        _checkAndAdvanceState();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ExceedsMaxCap();
        assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Public — ERC-4626 Overrides (view)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice State-dependent total assets backing outstanding shares.
     * @dev Fundraising through SettlementDeadlineExceeded: totalRaised. Terminal (Matured/Failed/Liquidated): balance.
     * @return Total assets in supply asset units.
     */
    function totalAssets() public view override returns (uint256) {
        VaultState s = _runtime.state;

        // During Lock, PendingSettlement, and SettlementDeadlineExceeded the supply
        // balance is zero (institution claimed funds and hasn't repaid yet),
        // so return totalRaised to preserve 1:1 share-to-asset parity for redeems.
        if (
            s == VaultState.Fundraising || s == VaultState.InstitutionConfirmation
                || s == VaultState.Lock || s == VaultState.PendingSettlement
                || s == VaultState.SettlementDeadlineExceeded
        ) {
            return _runtime.totalRaised;
        }

        // WaitingForMargin, MarginDeposited, Matured, Failed, Liquidated
        // — actual balance reflects reality.
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Remaining deposit capacity in supply asset units. Zero outside Open state.
     * @param /*receiver Unused — no per-user limits in base implementation.
     * @return Maximum depositable amount.
     */
    function maxDeposit(
        address /* receiver */
    ) public view override returns (uint256) {
        if (_runtime.state != VaultState.Fundraising) return 0;
        return _config.maxBorrowCap - _runtime.totalRaised;
    }

    /**
     * @notice Share equivalent of maxDeposit.
     * @param receiver Receiver address (passed through to maxDeposit).
     * @return Maximum mintable shares.
     */
    function maxMint(
        address receiver
    ) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), MathUpgradeable.Rounding.Down);
    }

    /**
     * @notice Withdrawable supply asset amount for a supplier. Zero outside terminal states.
     * @param owner Share holder address.
     * @return Maximum withdrawable supply asset amount.
     */
    function maxWithdraw(
        address owner
    ) public view override returns (uint256) {
        VaultState s = _runtime.state;
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            return previewRedeem(balanceOf(owner));
        }
        return 0;
    }

    /**
     * @notice Redeemable share amount for a supplier. Zero outside terminal states.
     * @param owner Share holder address.
     * @return Maximum redeemable share amount.
     */
    function maxRedeem(
        address owner
    ) public view override returns (uint256) {
        VaultState s = _runtime.state;
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            return balanceOf(owner);
        }
        return 0;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Initialization
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Initializes the base vault. Called by subcontract initializers.
     * @param asset_ Supply asset (ERC-4626 underlying).
     * @param name_ Share token name.
     * @param symbol_ Share token symbol.
     * @param vaultController_ VaultController address (msg.sender of the deploy tx).
     */
    function __BaseVault_init(
        IERC20Upgradeable asset_,
        string memory name_,
        string memory symbol_,
        address vaultController_
    ) internal onlyInitializing {
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        vaultController = vaultController_;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — State Machine (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Handles all time-based and condition-based auto-transitions.
     *      Called at the start of every state-changing external function.
     */
    function _checkAndAdvanceState() internal virtual {
        VaultState s = _runtime.state;
        uint256 currentTime = block.timestamp;

        // Fundraising -> next state (vault-type-specific logic)
        if (s == VaultState.Fundraising) {
            _advanceStateFromOpen();
            return;
        }

        uint256 lockEnd = _runtime.lockEndTime;

        // Lock -> PendingSettlement (falls through to check Matured/SettlementDeadlineExceeded)
        if (s == VaultState.Lock && currentTime >= lockEnd) {
            _runtime.state = VaultState.PendingSettlement;
            emit StateTransition(VaultState.Lock, VaultState.PendingSettlement, currentTime);
            s = VaultState.PendingSettlement;
        }

        // PendingSettlement -> Matured (settles protocol share) or SettlementDeadlineExceeded
        if (s == VaultState.PendingSettlement) {
            uint256 debt = _outstandingDebt();
            if (debt == 0 && currentTime >= lockEnd) {
                _runtime.state = VaultState.Matured;
                emit StateTransition(VaultState.PendingSettlement, VaultState.Matured, currentTime);
                _settleProtocolShare();
                return;
            }
            if (currentTime > _runtime.settlementDeadline && debt > 0) {
                _runtime.state = VaultState.SettlementDeadlineExceeded;
                emit StateTransition(VaultState.PendingSettlement, VaultState.SettlementDeadlineExceeded, currentTime);
                return;
            }
        }

        // SettlementDeadlineExceeded -> Matured
        if (s == VaultState.SettlementDeadlineExceeded && _outstandingDebt() == 0 && currentTime >= lockEnd) {
            _runtime.state = VaultState.Matured;
            emit StateTransition(VaultState.SettlementDeadlineExceeded, VaultState.Matured, currentTime);
            _settleProtocolShare();
            return;
        }
    }

    /**
     * @dev Transfers protocol fee and surplus to PSR. Sets settlementAmount.
     *      Called once when transitioning to Matured. Guarded by protocolShareSettled flag.
     */
    function _settleProtocolShare() internal {
        if (_runtime.protocolShareSettled) return;
        _runtime.protocolShareSettled = true;

        IERC20 supplyToken = IERC20(asset());
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
            try IProtocolShareReserve(psr).updateAssetsState(
                comptrollerAddr, asset(), IProtocolShareReserve.IncomeType.INSTITUTIONAL_VAULT_PROTOCOL_FEE
            ) {} catch (bytes memory reason) {
                emit PSRNotificationFailed(psr, reason);
            }
            if (protocolFee > 0) emit ProtocolFeePaid(protocolFee);
            if (surplus > 0) emit SurplusTransferred(surplus);
        }

        _runtime.settlementAmount = available - psrTotal;
        emit SettlementConfirmed(_runtime.settlementAmount, protocolFee);
    }

    /**
     * @dev Internal deposit — state checks, min deposit, cap enforcement via clamping in public wrappers.
     * @custom:error InvalidState If vault is not in Fundraising state.
     * @custom:error BelowMinimumDepositAmount If deposit amount is below the configured minimum.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        if (_runtime.state != VaultState.Fundraising) revert InvalidState();
        if (_config.minSupplierDeposit > 0 && assets < _config.minSupplierDeposit) revert BelowMinimumDepositAmount();

        super._deposit(caller, receiver, assets, shares);
        _runtime.totalRaised += assets;
    }

    /**
     * @dev Internal withdraw — only allowed in terminal states (Matured, Failed, Liquidated).
     *      No pause guard — supplier safety valve. Calls _afterWithdrawHook hook for subcontract extensions.
     * @custom:error InvalidState If vault is not in a terminal state (Matured/Failed/Liquidated).
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override nonReentrant {
        VaultState s = _runtime.state;
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) {
            revert InvalidState();
        }
        super._withdraw(caller, receiver, owner, assets, shares);
        _afterWithdrawHook(receiver, shares);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — View
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Full-term interest for the entire lock duration.
     * @return Total interest amount in supply asset units.
     */
    function _computeTotalInterest() internal view returns (uint256) {
        return (_runtime.totalRaised * _config.fixedAPY * _config.lockDuration) / (BPS * YEAR);
    }

    /**
     * @dev Returns the current outstanding debt (totalOwed minus supply asset balance).
     *      Repayment mechanism differs per vault type, but debt check is universal.
     * @return Outstanding debt in supply asset units. Zero if fully repaid.
     */
    function _outstandingDebt() internal view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 owed = _runtime.totalOwed;
        return balance >= owed ? 0 : owed - balance;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Shared Helpers (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Repays outstanding debt by pulling supply asset from `payer`. Clamped to debt.
     *      Subcontracts wrap this with their own access control.
     * @param payer Address to pull supply asset from.
     * @param amount Requested repay amount (will be clamped to outstanding debt).
     * @custom:error InvalidState if vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt if there is no debt to repay.
     * @custom:event Repaid
     */
    function _repay(
        address payer,
        uint256 amount
    ) internal {
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidState();
        }

        uint256 debt = _outstandingDebt();
        if (debt == 0) revert NoOutstandingDebt();
        uint256 amountClamped = amount > debt ? debt : amount;

        IERC20(asset()).safeTransferFrom(payer, address(this), amountClamped);

        emit Repaid(amountClamped, debt - amountClamped);
        _checkAndAdvanceState();
    }

    /**
     * @dev One-time fund withdrawal. Transfers all raised supply assets to `recipient`.
     *      Subcontracts wrap this with their own access control.
     *      Only callable during Lock — if lockEndTime passes before claiming, the state advances
     *      to PendingSettlement and this function becomes inaccessible. The supply asset stays in the vault
     *      and the institution still owes the interest portion (totalOwed - balance = interest).
     * @param recipient Address to receive the raised funds.
     * @custom:error InvalidState if vault is not in Lock state.
     * @custom:error AlreadyWithdrawn if funds already claimed.
     * @custom:event RaisedFundsClaimed
     */
    function _claimRaisedFunds(
        address recipient
    ) internal {
        _checkAndAdvanceState();
        if (_runtime.state != VaultState.Lock) revert InvalidState();
        if (_runtime.fundsWithdrawn) revert AlreadyWithdrawn();

        IERC20 supplyToken = IERC20(asset());
        uint256 amount = _runtime.totalRaised;
        _runtime.fundsWithdrawn = true;
        supplyToken.safeTransfer(recipient, amount);

        emit RaisedFundsClaimed(amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Virtual Hooks
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Fundraising -> next state. Every vault type must override with its own transition logic.
     *      For institutional vaults, both institution (collateral) and suppliers (deposits) participate
     *      during Fundraising, so the transition evaluates both sides.
     *      For Ceffu vaults, only suppliers are involved during Fundraising.
     */
    function _advanceStateFromOpen() internal virtual { }

    /**
     * @dev Hook called after each supplier withdrawal (shares already burned, supply asset transferred).
     *      Subcontracts override to add vault-type-specific post-withdrawal logic.
     *      Default is a no-op — only vault types that hold collateral on-contract need to override
     *      (e.g. InstitutionalLoanVault distributes confiscated margin compensation here).
     * @param receiver Address that received the supply asset.
     * @param shares Number of shares that were redeemed (already burned).
     */
    function _afterWithdrawHook(
        address receiver,
        uint256 shares
    ) internal virtual { }
}
