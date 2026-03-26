// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseVault } from "../BaseVault.sol";
import { VaultConfig, VaultState } from "../interfaces/IVaultTypes.sol";
import {
    InstitutionalConfig,
    InstitutionalRuntime,
    RiskConfig,
    LiquidationType
} from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionPositionToken } from "../interfaces/IInstitutionPositionToken.sol";
import { IInstitutionalVaultController } from "../interfaces/IInstitutionalVaultController.sol";
import { ILiquidationAdapter } from "../interfaces/ILiquidationAdapter.sol";
import { IResilientOracle } from "../interfaces/IResilientOracle.sol";

/**
 * @title InstitutionalLoanVault
 * @notice ERC-4626 vault for institutional fixed-rate lending with on-chain collateral,
 *         borrowing, and liquidation support. Deployed as EIP-1167 minimal proxy clones.
 * @dev Inherits BaseVault for shared ERC-4626 mechanics, fundraising, interest, settlement,
 *      and core state machine. Adds: collateral deposit/withdraw, borrowing, risk checks,
 *      liquidation entry points, and pre-fundraising states (WaitingForMargin, MarginDeposited).
 *      No ACM — all governance calls are proxied through VaultController.
 *      Position-holder gated functions (collateral ops, claimRaisedFunds) are restricted to the
 *      current owner of the vault's PositionToken — not the original institution address. The
 *      institution can transfer vault ownership by transferring the token to another address.
 */
contract InstitutionalLoanVault is BaseVault {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Storage (extends BaseVault)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Institutional-specific configuration — collateral, sizing, position identity.
    InstitutionalConfig internal _instConfig;

    /// @notice Institutional-specific runtime — collateral accounting, margin confiscation.
    InstitutionalRuntime internal _instRuntime;

    /// @notice Risk parameters — LT/LI/latePenaltyRate mutable via controller.
    RiskConfig internal _riskConfig;

    /// @notice InstitutionPositionToken contract — from controller storage.
    IInstitutionPositionToken public positionToken;

    /// @notice LiquidationAdapter address — from controller storage.
    address public liquidationAdapter;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event VaultOpened(uint256 openEndTime);
    event VaultLiquidated(uint256 available);
    event CollateralDeposited(uint256 amount, uint256 totalCollateral);
    event CollateralWithdrawn(uint256 amount);
    event LiquidationExecuted(address indexed liquidator, uint256 repayAmount, uint256 collateralSeized);
    event OverdueLiquidationExecuted(address indexed settler, uint256 repayAmount, uint256 collateralSeized);
    event MarginConfiscated(uint256 marginAmount);
    event MarginCompensationClaimed(address indexed receiver, uint256 amount);
    event LiquidationThresholdUpdated(uint256 oldLT, uint256 newLT);
    event LiquidationIncentiveUpdated(uint256 oldLI, uint256 newLI);
    event LatePenaltyRateUpdated(uint256 oldRate, uint256 newRate);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InsufficientCollateral();
    error InsufficientMarginCollateral();
    error NotPositionHolder();
    error PositionTokenIdNotSet();
    error InvalidStateForOverdueLiquidation();
    error NotBadDebt();
    error InsufficientRepayment();
    error NotLiquidatable();
    error ExceedsCloseFactor();
    error InsufficientCollateralForSeize(uint256 seizeAmount, uint256 availableCollateral);
    error WithdrawalWouldBreachLT();
    error InvalidOraclePrice();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Restricts to the current owner of the vault's PositionToken. Ownership is transferable —
     *      if the institution transfers the token, the new holder gains access to position-holder gated functions.
     */
    modifier onlyPositionHolder() {
        if (_instConfig.positionTokenId == 0) revert PositionTokenIdNotSet();
        if (positionToken.ownerOf(_instConfig.positionTokenId) != msg.sender) revert NotPositionHolder();
        _;
    }

    /// @dev Restricts to the LiquidationAdapter contract set during initialization.
    modifier onlyLiquidationAdapter() {
        if (msg.sender != liquidationAdapter) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Controller-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the vault clone. Called once by VaultController.
     * @param config_ Shared vault configuration (asset, rates, caps, timing).
     * @param instConfig_ Institutional-specific configuration (collateral, sizing, position identity).
     * @param riskConfig_ Risk parameters.
     * @param positionToken_ InstitutionPositionToken contract reference.
     * @param liquidationAdapter_ LiquidationAdapter contract address.
     */
    function initialize(
        VaultConfig calldata config_,
        InstitutionalConfig calldata instConfig_,
        RiskConfig calldata riskConfig_,
        IInstitutionPositionToken positionToken_,
        address liquidationAdapter_
    ) external initializer {
        __BaseVault_init(
            IERC20Upgradeable(address(config_.supplyAsset)), "Venus Institutional Loan Vault Share", "vILV", msg.sender
        );

        _config = config_;
        _instConfig = instConfig_;
        _riskConfig = riskConfig_;
        positionToken = positionToken_;
        liquidationAdapter = liquidationAdapter_;
        _runtime.state = VaultState.WaitingForMargin;
    }

    /**
     * @notice Transitions MarginDeposited -> Open. Controller only.
     * @custom:error InvalidState If vault is not in MarginDeposited state.
     * @custom:event VaultOpened Emitted with the open end time.
     * @custom:event StateTransition Emitted for MarginDeposited -> Fundraising.
     */
    function openVault() external onlyController {
        if (_runtime.state != VaultState.MarginDeposited) revert InvalidState();

        uint40 ts = uint40(block.timestamp);
        uint40 openEnd = ts + _config.openDuration;
        uint40 lockEnd = openEnd + _config.lockDuration;
        _runtime.openStartTime = ts;
        _runtime.openEndTime = openEnd;
        _runtime.lockStartTime = openEnd;
        _runtime.lockEndTime = lockEnd;
        _runtime.settlementDeadline = lockEnd + _config.settlementWindow;
        _enterFundraising(openEnd);
    }

    /**
     * @notice Permissionless bad-debt rescue. Anyone may repay to settle a vault where collateral < debt.
     * @param repayAmount Amount of supply asset to pull from caller.
     * @custom:error InvalidState If vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NotBadDebt If collateral value >= debt value.
     * @custom:error InsufficientRepayment If outstanding debt after repay still exceeds total interest (principal not
     * fully returned).
     * @custom:event StateTransition Emitted for transition to Liquidated.
     * @custom:event VaultLiquidated Emitted with available balance.
     */
    function repayBadDebt(
        uint256 repayAmount
    ) external nonReentrant {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidState();
        }

        if (repayAmount == 0) revert ZeroRepayAmount();
        if (_outstandingDebt() == 0) revert NoOutstandingDebt();
        if (_getCollateralValueUSD() >= _getDebtValueUSD()) revert NotBadDebt();

        _receiveRepayment(msg.sender, repayAmount);

        if (_runtime.totalDebt > _computeTotalInterest()) revert InsufficientRepayment();
        _enterLiquidated(s);
    }

    /**
     * @notice Updates liquidation threshold. Controller only.
     * @param newLT New liquidation threshold (mantissa).
     */
    function setLiquidationThreshold(
        uint256 newLT
    ) external onlyController {
        emit LiquidationThresholdUpdated(_riskConfig.liquidationThreshold, newLT);
        _riskConfig.liquidationThreshold = newLT;
    }

    /**
     * @notice Updates liquidation incentive. Controller only.
     * @param newLI New liquidation incentive (mantissa).
     */
    function setLiquidationIncentive(
        uint256 newLI
    ) external onlyController {
        emit LiquidationIncentiveUpdated(_riskConfig.liquidationIncentive, newLI);
        _riskConfig.liquidationIncentive = newLI;
    }

    /**
     * @notice Updates late penalty rate. Controller only.
     * @param newRate New late penalty rate (mantissa).
     */
    function setLatePenaltyRate(
        uint256 newRate
    ) external onlyController {
        emit LatePenaltyRateUpdated(_riskConfig.latePenaltyRate, newRate);
        _riskConfig.latePenaltyRate = newRate;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Adapter-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice HF-based liquidation. LiquidationAdapter only.
     * @param repayAmount Amount of supply asset to repay.
     * @return actualRepay Actual amount repaid after clamping to outstanding debt.
     * @custom:error InvalidState If vault is not in Lock, PendingSettlement, or SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt If there is no debt to repay.
     * @custom:error NotLiquidatable If vault has no LT shortfall.
     * @custom:event LiquidationExecuted Emitted with liquidator, repay amount, and collateral seized.
     */
    function liquidate(
        uint256 repayAmount
    ) external onlyLiquidationAdapter nonReentrant whenNotCompletelyPaused returns (uint256 actualRepay) {
        if (repayAmount == 0) revert ZeroRepayAmount();
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidState();
        }

        uint256 debt = _outstandingDebt();
        if (debt == 0) revert NoOutstandingDebt();
        actualRepay = repayAmount > debt ? debt : repayAmount;

        (, uint256 shortfall) = _getHypotheticalVaultLiquidity(0);
        if (shortfall == 0) revert NotLiquidatable();

        uint256 seizeAmount = _executeLiquidation(debt, actualRepay, LiquidationType.HF_BASED);
        emit LiquidationExecuted(msg.sender, actualRepay, seizeAmount);
    }

    /**
     * @notice Deadline-based liquidation. LiquidationAdapter only.
     * @param repayAmount Amount of supply asset to repay.
     * @return actualRepay Actual amount repaid after clamping to outstanding debt.
     * @custom:error InvalidStateForOverdueLiquidation If not in SettlementDeadlineExceeded.
     * @custom:error NoOutstandingDebt If there is no debt to repay.
     * @custom:event OverdueLiquidationExecuted Emitted with settler, repay amount, and collateral seized.
     */
    function liquidateOverdueVault(
        uint256 repayAmount
    ) external onlyLiquidationAdapter nonReentrant whenNotCompletelyPaused returns (uint256 actualRepay) {
        if (repayAmount == 0) revert ZeroRepayAmount();
        _checkAndAdvanceState();
        if (_runtime.state != VaultState.SettlementDeadlineExceeded) revert InvalidStateForOverdueLiquidation();

        uint256 debt = _outstandingDebt();
        if (debt == 0) revert NoOutstandingDebt();
        actualRepay = repayAmount > debt ? debt : repayAmount;

        uint256 seizeAmount = _executeLiquidation(debt, actualRepay, LiquidationType.DEADLINE);
        emit OverdueLiquidationExecuted(msg.sender, actualRepay, seizeAmount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — PositionHolder-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposits collateral into the vault.
     *         - WaitingForMargin: cumulative deposits must reach margin amount to transition to MarginDeposited.
     *         - Fundraising: institution deposits remaining collateral alongside lender fundraising.
     *         - Lock: top-up collateral.
     * @param amount Amount of collateral tokens to deposit.
     * @custom:error InsufficientCollateral if deposit in WaitingForMargin does not meet margin threshold.
     * @custom:event CollateralDeposited, StateTransition (if WaitingForMargin -> MarginDeposited)
     */
    function depositCollateral(
        uint256 amount
    ) external onlyPositionHolder nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.WaitingForMargin && s != VaultState.Fundraising && s != VaultState.Lock) {
            revert InvalidState();
        }

        IERC20 collateralToken = IERC20(address(_instConfig.collateralAsset));
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actual = collateralToken.balanceOf(address(this)) - balanceBefore;

        _instRuntime.totalCollateralDeposited += actual;
        emit CollateralDeposited(actual, _instRuntime.totalCollateralDeposited);

        if (s == VaultState.WaitingForMargin) {
            uint256 marginAmount = (_instConfig.idealCollateralAmount * _instConfig.marginRate) / MANTISSA_ONE;
            if (_instRuntime.totalCollateralDeposited < marginAmount) revert InsufficientCollateral();
            _enterMarginDeposited();
        }
    }

    /**
     * @notice Withdraws collateral.
     *         - Lock: floor-checked (minimumCollateralRequired) + LT-checked.
     *         - Failed (Scenario A — raised < minCap): withdraw all deposited collateral.
     *         - Failed (Scenario B — institution default): withdraw deposited minus confiscated margin.
     *         - Matured / Liquidated: capped at totalCollateralDeposited, unrestricted.
     * @param amount Amount of collateral tokens to withdraw.
     * @custom:error InvalidState If vault is not in Lock, Matured, Failed, or Liquidated.
     * @custom:error InsufficientCollateral If withdrawal would breach floor or exceed available amount.
     * @custom:error WithdrawalWouldBreachLT If withdrawal would cause LT shortfall during Lock.
     * @custom:event CollateralWithdrawn Emitted with withdrawal amount.
     */
    function withdrawCollateral(
        uint256 amount
    ) external onlyPositionHolder nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.Matured && s != VaultState.Failed && s != VaultState.Liquidated) {
            revert InvalidState();
        }

        IERC20 collateralToken = IERC20(address(_instConfig.collateralAsset));

        // Lock: withdrawal must preserve the minimum collateral floor and pass LT health check.
        if (s == VaultState.Lock) {
            uint256 collateralBalance = _instRuntime.totalCollateralDeposited;
            if (collateralBalance < _instRuntime.minimumCollateralRequired + amount) revert InsufficientCollateral();

            if (_outstandingDebt() > 0) {
                (, uint256 shortfall) = _getHypotheticalVaultLiquidity(amount);
                if (shortfall > 0) revert WithdrawalWouldBreachLT();
            }
        }

        // Failed (Institution default): confiscated margin is reserved
        // for lender compensation, institution can only withdraw the remainder.
        if (s == VaultState.Failed && _instRuntime.institutionDefaulted) {
            uint256 available = _instRuntime.totalCollateralDeposited - _instRuntime.confiscatedMarginRemaining;
            if (amount > available) revert InsufficientCollateral();
        }

        // Failed (insufficient raise), Matured, Liquidated: unrestricted withdrawal
        // up to totalCollateralDeposited.
        if (amount > _instRuntime.totalCollateralDeposited) revert InsufficientCollateral();
        _instRuntime.totalCollateralDeposited -= amount;

        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(amount);
    }

    /**
     * @notice One-time fund withdrawal. Transfers all raised supply assets to institution.
     * @custom:error AlreadyWithdrawn if funds already claimed.
     * @custom:event RaisedFundsClaimed
     */
    function claimRaisedFunds() external onlyPositionHolder nonReentrant whenNotPaused {
        _claimRaisedFunds(msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Permissionless (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Repays outstanding debt. Anyone may call. Clamped to outstandingDebt.
     * @param amount Amount of supply asset to repay.
     * @custom:error ZeroRepayAmount if amount is zero.
     * @custom:error NoOutstandingDebt if there is no debt to repay.
     * @custom:event Repaid
     */
    function repay(
        uint256 amount
    ) external nonReentrant whenNotCompletelyPaused {
        _repay(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — View
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Current collateral value in USD via oracle.
     * @return Collateral value in 18-decimal USD.
     */
    function getCollateralValueUSD() external view returns (uint256) {
        return _getCollateralValueUSD();
    }

    /**
     * @notice Current outstanding debt value in USD via oracle.
     * @return Debt value in 18-decimal USD.
     */
    function getDebtValueUSD() external view returns (uint256) {
        return _getDebtValueUSD();
    }

    /**
     * @notice Returns the institutional-specific configuration.
     * @return Institutional config struct.
     */
    function institutionalConfig() external view returns (InstitutionalConfig memory) {
        return _instConfig;
    }

    /**
     * @notice Returns the risk configuration.
     * @return Risk parameters struct.
     */
    function riskConfig() external view returns (RiskConfig memory) {
        return _riskConfig;
    }

    /**
     * @notice Returns the institutional-specific runtime state.
     * @return Institutional runtime struct.
     */
    function institutionalRuntime() external view returns (InstitutionalRuntime memory) {
        return _instRuntime;
    }

    /**
     * @notice Returns current liquidity and shortfall for the vault.
     * @return liquidity Excess liquidity (0 if shortfall).
     * @return shortfall LT shortfall (0 if healthy).
     */
    function getVaultLiquidity() external view returns (uint256 liquidity, uint256 shortfall) {
        return _getHypotheticalVaultLiquidity(0);
    }

    /**
     * @notice Returns hypothetical liquidity/shortfall after a simulated withdrawal.
     * @param withdrawAmount Simulated collateral withdrawal amount.
     * @return liquidity Excess liquidity (0 if shortfall).
     * @return shortfall LT shortfall (0 if healthy).
     */
    function getHypotheticalVaultLiquidity(
        uint256 withdrawAmount
    ) external view returns (uint256 liquidity, uint256 shortfall) {
        return _getHypotheticalVaultLiquidity(withdrawAmount);
    }

    /**
     * @notice Preview seize amount for a given repay and liquidation type.
     * @param repayAmount Amount being repaid.
     * @param liquidationType HF_BASED or DEADLINE.
     * @return Collateral seize amount.
     */
    function calculateSeizeAmount(
        uint256 repayAmount,
        LiquidationType liquidationType
    ) external view returns (uint256) {
        return _calculateSeizeAmount(repayAmount, liquidationType);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — State-Changing
    // ──────────────────────────────────────────────────────────────────────

    /// @dev WaitingForMargin -> MarginDeposited.
    function _enterMarginDeposited() internal {
        _runtime.state = VaultState.MarginDeposited;
        emit StateTransition(VaultState.WaitingForMargin, VaultState.MarginDeposited, block.timestamp);
    }

    /**
     * @dev MarginDeposited -> Fundraising. Activates the vault and emits opening events.
     * @param openEnd Timestamp when the fundraising window closes.
     */
    function _enterFundraising(
        uint40 openEnd
    ) internal {
        _runtime.state = VaultState.Fundraising;
        _runtime.isActive = true;
        emit VaultOpened(openEnd);
        emit StateTransition(VaultState.MarginDeposited, VaultState.Fundraising, block.timestamp);
    }

    /**
     * @dev Fundraising -> Lock. Gates on collateral sufficiency — if collateral < idealCollateralAmount,
     *      falls through to _enterFailed (institution default). Otherwise initialises totalDebt,
     *      collateral floor, and valuation snapshot.
     * @param totalRaised Total supply assets raised during fundraising.
     */
    function _enterLock(
        uint256 totalRaised
    ) internal override {
        if (_instRuntime.totalCollateralDeposited < _instConfig.idealCollateralAmount) {
            _enterFailed(totalRaised);
            return;
        }
        super._enterLock(totalRaised);
        uint256 idealCollateral = _instConfig.idealCollateralAmount;
        _instRuntime.minimumCollateralRequired = (idealCollateral * totalRaised) / _config.maxBorrowCap;
        _instRuntime.idealCollateralValuation = _getCollateralValueUSD();
    }

    /**
     * @dev Fundraising -> Failed. Sets settlementAmount and confiscates margin on institution default.
     * @param totalRaised Total supply assets raised during fundraising.
     */
    function _enterFailed(
        uint256 totalRaised
    ) internal override {
        super._enterFailed(totalRaised);
        if (totalRaised >= _config.minBorrowCap) {
            uint256 marginAmount = (_instConfig.idealCollateralAmount * _instConfig.marginRate) / MANTISSA_ONE;
            _instRuntime.institutionDefaulted = true;
            _instRuntime.confiscatedMarginRemaining = marginAmount;
            emit MarginConfiscated(marginAmount);
        }
    }

    /**
     * @dev Transitions to Liquidated. Emits VaultLiquidated with pre-settlement balance
     *      and triggers protocol fee settlement.
     * @param from Source state.
     */
    function _enterLiquidated(
        VaultState from
    ) internal {
        _runtime.state = VaultState.Liquidated;
        emit StateTransition(from, VaultState.Liquidated, block.timestamp);
        emit VaultLiquidated(IERC20(asset()).balanceOf(address(this)));
        _settleProtocolShare();
    }

    /**
     * @dev Hook called after each supplier withdrawal. In institution-default Failed state (Scenario B),
     *      distributes pro-rata collateral margin compensation to the withdrawing lender.
     * @param receiver Address that received the supply asset refund.
     * @param shares Number of shares that were redeemed (already burned at this point).
     */
    function _afterWithdrawHook(
        address receiver,
        uint256 shares
    ) internal override {
        if (!_instRuntime.institutionDefaulted || _instRuntime.confiscatedMarginRemaining == 0) return;

        // totalSupply() is post-burn; reconstruct pre-burn total for pro-rata calculation
        uint256 totalSharesBeforeBurn = totalSupply() + shares;
        uint256 compensation = (_instRuntime.confiscatedMarginRemaining * shares) / totalSharesBeforeBurn;

        if (compensation > 0) {
            _instRuntime.confiscatedMarginRemaining -= compensation;
            _instRuntime.totalCollateralDeposited -= compensation;
            IERC20(address(_instConfig.collateralAsset)).safeTransfer(receiver, compensation);
            emit MarginCompensationClaimed(receiver, compensation);
        }
    }

    /**
     * @dev Shared liquidation execution: close factor check, seize calculation, token transfers.
     *      Fee-on-transfer collateral tokens are NOT supported: totalCollateralDeposited is decremented
     *      by the oracle-computed seizeAmount, not the actual tokens transferred.
     * @param debt Current outstanding debt.
     * @param actualRepay Clamped repay amount.
     * @param liqType HF_BASED or DEADLINE — determines incentive multiplier.
     * @return seizeAmount Collateral seized.
     * @custom:error ExceedsCloseFactor if actualRepay exceeds close factor limit.
     * @custom:error InsufficientCollateralForSeize if seize amount exceeds collateral balance.
     */
    function _executeLiquidation(
        uint256 debt,
        uint256 actualRepay,
        LiquidationType liqType
    ) internal returns (uint256 seizeAmount) {
        uint256 closeFactor = ILiquidationAdapter(liquidationAdapter).closeFactor();
        uint256 maxRepay = (debt * closeFactor) / MANTISSA_ONE;
        if (actualRepay > maxRepay) revert ExceedsCloseFactor();

        seizeAmount = _calculateSeizeAmount(actualRepay, liqType);
        IERC20 collateralToken = IERC20(address(_instConfig.collateralAsset));
        uint256 collateralBalance = _instRuntime.totalCollateralDeposited;
        if (seizeAmount > collateralBalance) revert InsufficientCollateralForSeize(seizeAmount, collateralBalance);

        _receiveRepayment(msg.sender, actualRepay);
        collateralToken.safeTransfer(msg.sender, seizeAmount);
        _instRuntime.totalCollateralDeposited -= seizeAmount;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — View
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Internal collateral USD valuation. Caches oracle and collateral address.
    function _getCollateralValueUSD() internal view returns (uint256) {
        uint256 deposited = _instRuntime.totalCollateralDeposited;
        if (deposited == 0) return 0;
        address collateral = address(_instConfig.collateralAsset);
        IResilientOracle oracleRef = IResilientOracle(IInstitutionalVaultController(vaultController).oracle());
        uint256 price = oracleRef.getPrice(collateral);
        if (price == 0) revert InvalidOraclePrice();
        return (deposited * price) / MANTISSA_ONE;
    }

    /// @dev Internal debt USD valuation. Caches oracle and supply address.
    function _getDebtValueUSD() internal view returns (uint256) {
        uint256 debt = _outstandingDebt();
        if (debt == 0) return 0;
        address supply = address(_config.supplyAsset);
        IResilientOracle oracleRef = IResilientOracle(IInstitutionalVaultController(vaultController).oracle());
        uint256 price = oracleRef.getPrice(supply);
        if (price == 0) revert InvalidOraclePrice();
        return (debt * price) / MANTISSA_ONE;
    }

    /**
     * @dev Computes liquidity (excess buffer) and shortfall (deficit) for the vault,
     *      optionally simulating a collateral withdrawal.
     * @param withdrawAmount Collateral token amount to simulate withdrawing (0 for current state).
     * @return liquidity Excess buffer when safe; 0 when shortfall > 0.
     * @return shortfall Deficit when liquidatable; 0 when liquidity > 0.
     */
    function _getHypotheticalVaultLiquidity(
        uint256 withdrawAmount
    ) internal view returns (uint256 liquidity, uint256 shortfall) {
        uint256 collateralUSD = _getCollateralValueUSD();
        uint256 debtUSD = _getDebtValueUSD();
        uint256 lt = _riskConfig.liquidationThreshold;

        uint256 withdrawValueUSD;
        if (withdrawAmount > 0) {
            uint256 collateralBalance = _instRuntime.totalCollateralDeposited;
            if (collateralBalance > 0) {
                withdrawValueUSD = (withdrawAmount * collateralUSD) / collateralBalance;
            }
        }

        uint256 collateralAfterWithdraw = collateralUSD > withdrawValueUSD ? collateralUSD - withdrawValueUSD : 0;
        uint256 ltCap = (collateralAfterWithdraw * lt) / MANTISSA_ONE;

        if (debtUSD <= ltCap) {
            return (ltCap - debtUSD, 0);
        } else {
            return (0, debtUSD - ltCap);
        }
    }

    /**
     * @dev Computes the collateral amount to seize for a given repay amount.
     * @param repayAmount Amount of supply asset being repaid.
     * @param liqType HF_BASED uses liquidationIncentive, DEADLINE uses latePenaltyRate.
     * @return seizeAmount Collateral amount to transfer to liquidator/settler.
     */
    function _calculateSeizeAmount(
        uint256 repayAmount,
        LiquidationType liqType
    ) internal view returns (uint256 seizeAmount) {
        RiskConfig memory rc = _riskConfig;
        uint256 incentive = liqType == LiquidationType.HF_BASED ? rc.liquidationIncentive : rc.latePenaltyRate;

        address supplyAsset = address(_config.supplyAsset);
        address collateralAsset = address(_instConfig.collateralAsset);
        IResilientOracle oracleRef = IResilientOracle(IInstitutionalVaultController(vaultController).oracle());

        uint256 supplyPrice = oracleRef.getPrice(supplyAsset);
        uint256 collateralPrice = oracleRef.getPrice(collateralAsset);

        if (supplyPrice == 0 || collateralPrice == 0) revert InvalidOraclePrice();

        uint256 repayValueUSD = (repayAmount * supplyPrice) / MANTISSA_ONE;
        uint256 seizeValueUSD = (repayValueUSD * incentive) / MANTISSA_ONE;
        seizeAmount = (seizeValueUSD * MANTISSA_ONE) / collateralPrice;
    }
}
