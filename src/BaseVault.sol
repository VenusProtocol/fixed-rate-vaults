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
    uint256 public constant MANTISSA_ONE = 1e18;
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
    event VaultClosed(VaultState state);
    event SettlementConfirmed(uint256 settlementAmount, uint256 protocolFee, uint256 surplus);
    event ShortfallDetected(uint256 totalOwed, uint256 available);
    event PSRNotificationFailed(address indexed psr, bytes reason);
    event RaisedFundsClaimed(uint256 amount);
    event Repaid(uint256 amount, uint256 remainingDebt);
    event PauseLevelSet(PauseLevel oldLevel, PauseLevel newLevel);
    event TokensSwept(address indexed token, address indexed recipient, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidState();
    error SameStateTransition();
    error BelowMinimumDepositAmount();
    error ExceedsMaxCap();
    error Unauthorized();
    error AlreadyWithdrawn();
    error NoOutstandingDebt();
    error ZeroRepayAmount();
    error NothingToSweep();
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
     * @notice Transitions vault to Closed state. All operations are blocked after this point.
     *         Governance should only call this once all suppliers have withdrawn their funds.
     * @custom:error InvalidState If vault is not in a terminal state (Matured/Failed/Liquidated).
     * @custom:event StateTransition Emitted for the terminal state -> Closed transition.
     * @custom:event VaultClosed Emitted with the previous terminal state.
     */
    function closeVault() external onlyController {
        VaultState s = _runtime.state;
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) revert InvalidState();
        _stateTransition(VaultState.Closed);
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

    /**
     * @notice Recovers any tokens stuck in the vault. Full balance is transferred.
     * @param token Token address to sweep.
     * @custom:error NothingToSweep If the token balance is zero.
     * @custom:event TokensSwept
     */
    function sweep(
        address token
    ) external onlyController {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        address recipient = IVaultController(vaultController).treasury();
        IERC20(token).safeTransfer(recipient, amount);
        emit TokensSwept(token, recipient, amount);
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
     * @notice Total remaining debt. Decremented by repayments; zero when fully repaid.
     * @return Outstanding debt in supply asset units.
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
     * @custom:error InvalidState If vault is not in Fundraising state.
     * @custom:error ExceedsMaxCap If clamped deposit amount is zero (vault at capacity).
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        VaultState s = _checkAndAdvanceState();
        if (s != VaultState.Fundraising) revert InvalidState();
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
     * @custom:error InvalidState If vault is not in Fundraising state.
     * @custom:error ExceedsMaxCap If clamped share amount is zero (vault at capacity).
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256 assets) {
        VaultState s = _checkAndAdvanceState();
        if (s != VaultState.Fundraising) revert InvalidState();
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
     * @custom:error InvalidState If vault is not in a terminal state (Matured/Failed/Liquidated).
     * @custom:error ExceedsMaxCap If requested assets exceed the caller's withdrawable balance.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        VaultState s = _checkAndAdvanceState();
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) revert InvalidState();
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
     * @custom:error InvalidState If vault is not in a terminal state (Matured/Failed/Liquidated).
     * @custom:error ExceedsMaxCap If requested shares exceed the caller's redeemable balance.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        VaultState s = _checkAndAdvanceState();
        if (s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) revert InvalidState();
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
     * @dev Matured/Failed/Liquidated: settlementAmount (decremented on each withdrawal). All other states: totalRaised.
     * @return Total assets in supply asset units.
     */
    function totalAssets() public view override returns (uint256) {
        VaultState s = _runtime.state;

        // Matured/Failed/Liquidated: use settlementAmount so the redeemable total tracks correctly
        // as users withdraw (settlementAmount is decremented in _withdraw for these states).
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            return _runtime.settlementAmount;
        }

        // All other states: totalRaised (0 pre-fundraising, deposited amount otherwise).
        return _runtime.totalRaised;
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
     * @dev Hook for time-based and condition-based auto-transitions. Called at the start of every
     *      state-changing external function. No-op in base — subcontracts own their state machine.
     * @return Current vault state after any transitions are applied.
     */
    function _checkAndAdvanceState() internal virtual returns (VaultState) { }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — State Entry Functions (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Writes `to` as the new state and emits StateTransition. Captures current state as `from`.
    function _stateTransition(
        VaultState to
    ) internal {
        VaultState from = _runtime.state;
        if (from == to) revert SameStateTransition();
        _runtime.state = to;
        emit StateTransition(from, to, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Settlement (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Computes protocol fee and surplus, transfers both to PSR, and sets settlementAmount.
     *      Called once on Matured/Liquidated transition; guarded by protocolShareSettled flag.
     *      Three branches based on available balance vs expectedRepayment (principal + interest):
     *        1. Full repayment (available >= expectedRepayment): fee on full interest + any surplus to PSR.
     *        2. Partial repayment (available > totalRaised): fee on partial interest only; emits ShortfallDetected.
     *        3. Principal shortfall (available <= totalRaised): no fee; emits ShortfallDetected.
     */
    function _settleProtocolShare() internal {
        if (_runtime.protocolShareSettled) return;
        _runtime.protocolShareSettled = true;

        IERC20 supplyToken = IERC20(asset());
        uint256 available = supplyToken.balanceOf(address(this));
        address psr = IVaultController(vaultController).protocolShareReserve();
        address comptrollerAddr = IVaultController(vaultController).comptroller();
        uint256 totalInterest = _computeTotalInterest();
        uint256 expectedRepayment = _runtime.totalRaised + totalInterest;
        uint256 protocolFee;
        uint256 surplus;

        if (available >= expectedRepayment) {
            protocolFee = (totalInterest * _config.reserveFactor) / MANTISSA_ONE;
            surplus = available - expectedRepayment;
        } else if (available > _runtime.totalRaised) {
            uint256 interestAvailable = available - _runtime.totalRaised;
            protocolFee = (interestAvailable * _config.reserveFactor) / MANTISSA_ONE;
            emit ShortfallDetected(expectedRepayment, available);
        } else {
            protocolFee = 0;
            emit ShortfallDetected(expectedRepayment, available);
        }

        uint256 psrTotal = protocolFee + surplus;
        if (psrTotal > 0) {
            supplyToken.safeTransfer(psr, psrTotal);
            try IProtocolShareReserve(psr)
                .updateAssetsState(
                    comptrollerAddr, asset(), IProtocolShareReserve.IncomeType.INSTITUTIONAL_VAULT_PROTOCOL_FEE
                ) { }
            catch (bytes memory reason) {
                emit PSRNotificationFailed(psr, reason);
            }
        }

        _runtime.settlementAmount = available - psrTotal;
        emit SettlementConfirmed(_runtime.settlementAmount, protocolFee, surplus);
    }

    /**
     * @dev Internal deposit — min deposit check, share minting, totalRaised update.
     *      State check and advance are handled by the public wrappers (deposit/mint).
     *      The minimum-deposit floor is waived for the final residual tail
     *      (`assets == maxBorrowCap - totalRaised`) so a sub-minimum leftover capacity
     *      can still be filled and the cap can actually be reached.
     * @custom:error BelowMinimumDepositAmount If deposit amount is below the configured
     *               minimum and is not the final residual tail.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        uint256 floor = _config.minSupplierDeposit;
        if (floor > 0 && assets < floor) {
            uint256 remaining = _config.maxBorrowCap - _runtime.totalRaised;
            if (assets < remaining) revert BelowMinimumDepositAmount();
        }
        super._deposit(caller, receiver, assets, shares);
        _runtime.totalRaised += assets;
    }

    /**
     * @dev Internal withdraw — settlement amount accounting, asset transfer, after-hook.
     *      State check and advance are handled by the public wrappers (withdraw/redeem).
     *      No pause guard — supplier safety valve.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override nonReentrant whenNotCompletelyPaused {
        super._withdraw(caller, receiver, owner, assets, shares);
        _runtime.settlementAmount -= assets;
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
     * @dev Returns the current outstanding debt.
     *      Initialised to interest at Lock, increased by claimRaisedFunds, decremented by repayments.
     * @return Outstanding debt in supply asset units. Zero if fully repaid.
     */
    function _outstandingDebt() internal view returns (uint256) {
        return _runtime.totalDebt;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Shared Helpers (state-changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Pulls supply asset from `payer`, clamped to outstanding debt, decrements totalDebt, emits Repaid.
     *      Single entry point for all supply token inflows after fundraising.
     * @param payer Address to pull supply asset from.
     * @param amount Requested amount; clamped to outstanding debt.
     * @custom:event Repaid
     */
    function _receiveRepayment(
        address payer,
        uint256 amount
    ) internal {
        uint256 debt = _outstandingDebt();
        uint256 actual = amount > debt ? debt : amount;
        if (actual == 0) return;
        _runtime.totalDebt -= actual;
        IERC20(asset()).safeTransferFrom(payer, address(this), actual);
        emit Repaid(actual, _outstandingDebt());
    }

    /**
     * @dev Repays outstanding debt by pulling supply asset from `payer`. Clamped to debt.
     *      Subcontracts wrap this with their own access control.
     * @param payer Address to pull supply asset from.
     * @param amount Requested repay amount (will be clamped to outstanding debt).
     * @custom:error ZeroRepayAmount if amount is zero.
     * @custom:error InvalidState if vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt if there is no debt to repay.
     * @custom:event Repaid
     */
    function _repay(
        address payer,
        uint256 amount
    ) internal {
        if (amount == 0) revert ZeroRepayAmount();

        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidState();
        }

        if (_outstandingDebt() == 0) revert NoOutstandingDebt();
        _receiveRepayment(payer, amount);
        _checkAndAdvanceState();
    }

    /**
     * @dev One-time fund withdrawal. Transfers all raised supply assets to `recipient`.
     *      Increments totalDebt by totalRaised — principal is now owed on top of interest.
     *      Subcontracts wrap this with their own access control.
     *      Only callable during Lock — if lockEndTime passes before claiming, the state advances
     *      to PendingSettlement and this function becomes inaccessible. The supply asset stays in the vault
     *      and the institution still owes only the interest portion (totalDebt = interest, unchanged).
     * @param recipient Address to receive the raised funds.
     * @custom:error InvalidState From _beforeClaimRaisedFunds: if the state check fails.
     * @custom:error AlreadyWithdrawn if funds already claimed.
     * @custom:event RaisedFundsClaimed
     */
    function _claimRaisedFunds(
        address recipient
    ) internal {
        _beforeClaimRaisedFunds();
        if (_runtime.fundsWithdrawn) revert AlreadyWithdrawn();

        IERC20 supplyToken = IERC20(asset());
        uint256 amount = _runtime.totalRaised;
        _runtime.fundsWithdrawn = true;
        _runtime.totalDebt += amount;
        supplyToken.safeTransfer(recipient, amount);
        _checkAndAdvanceState();

        emit RaisedFundsClaimed(amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Virtual Hooks
    // ──────────────────────────────────────────────────────────────────────

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

    /**
     * @dev Hook called at the start of _claimRaisedFunds to validate vault state.
     *      Default implementation requires Lock state and that block.timestamp lies inside
     *      [lockStartTime, lockEndTime).
     *      Override in subcontracts to enforce a different state requirement.
     * @custom:error InvalidState If the vault is not in Lock or block.timestamp is outside
     *               the [lockStartTime, lockEndTime) window.
     */
    function _beforeClaimRaisedFunds() internal virtual {
        if (_runtime.state != VaultState.Lock) revert InvalidState();
        uint256 nowTs = block.timestamp;
        if (nowTs < _runtime.lockStartTime || nowTs >= _runtime.lockEndTime) revert InvalidState();
    }
}
