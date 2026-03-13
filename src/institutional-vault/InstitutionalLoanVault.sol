// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { BaseVault } from "../BaseVault.sol";
import { VaultConfig, RiskConfig, VaultState, LiquidationType } from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionPositionToken } from "../interfaces/IInstitutionPositionToken.sol";
import { IInstitutionalVaultController } from "../interfaces/IInstitutionalVaultController.sol";
import { ILiquidationAdapter } from "../interfaces/ILiquidationAdapter.sol";
import { IResilientOracle } from "../interfaces/IResilientOracle.sol";

/// @title InstitutionalLoanVault
/// @notice ERC-4626 vault for institutional fixed-rate lending with on-chain collateral,
///         borrowing, and liquidation support. Deployed as EIP-1167 minimal proxy clones.
/// @dev Inherits BaseVault for shared ERC-4626 mechanics, fundraising, interest, settlement,
///      and core state machine. Adds: collateral deposit/withdraw, borrowing, risk checks,
///      liquidation entry points, and pre-fundraising states (WaitingForCollateral, CollateralDeposited).
///      No ACM — all governance calls are proxied through VaultController.
///      Position-holder gated functions (collateral ops, claimRaisedFunds) are restricted to the
///      current owner of the vault's PositionToken — not the original institution address. The
///      institution can transfer vault ownership by transferring the token to another address.
contract InstitutionalLoanVault is BaseVault {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Storage (extends BaseVault)
    // ──────────────────────────────────────────────────────────────────────

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

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InsufficientCollateral();
    error NotPositionHolder();
    error PositionTokenIdNotSet();
    error InvalidStateForOverdueLiquidation();
    error NotBadDebt();
    error InsufficientRepayment();
    error NotLiquidatable();
    error ExceedsCloseFactor();
    error InsufficientCollateralForSeize(uint256 seizeAmount, uint256 availableCollateral);
    error WithdrawalWouldBreachLT();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Restricts to the current owner of the vault's PositionToken. Ownership is transferable —
    ///      if the institution transfers the token, the new holder gains access to position-holder gated functions.
    modifier onlyPositionHolder() {
        if (_config.positionTokenId == 0) revert PositionTokenIdNotSet();
        if (positionToken.ownerOf(_config.positionTokenId) != msg.sender) revert NotPositionHolder();
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

    /// @notice Initializes the vault clone. Called once by VaultController.
    /// @param config_ Vault configuration.
    /// @param riskConfig_ Risk parameters.
    /// @param positionToken_ InstitutionPositionToken contract reference.
    /// @param liquidationAdapter_ LiquidationAdapter contract address.
    function initialize(
        VaultConfig calldata config_,
        RiskConfig calldata riskConfig_,
        IInstitutionPositionToken positionToken_,
        address liquidationAdapter_
    ) external initializer {
        __BaseVault_init(
            IERC20Upgradeable(address(config_.supplyAsset)),
            "Venus Institutional Loan Vault Share",
            "vILV",
            msg.sender
        );

        _config = config_;
        _riskConfig = riskConfig_;
        positionToken = positionToken_;
        liquidationAdapter = liquidationAdapter_;
        _runtime.state = VaultState.WaitingForCollateral;
    }

    /// @notice Transitions CollateralDeposited -> Open. Controller only.
    /// @custom:event VaultOpened, StateTransition
    function openVault() external onlyController {
        if (_runtime.state != VaultState.CollateralDeposited) revert InvalidState();

        uint40 ts = uint40(block.timestamp);
        uint40 openEnd = ts + _config.openDuration;
        uint40 lockEnd = openEnd + _config.lockDuration;
        _runtime.openStartTime = ts;
        _runtime.openEndTime = openEnd;
        _runtime.lockStartTime = openEnd;
        _runtime.lockEndTime = lockEnd;
        _runtime.settlementDeadline = lockEnd + _config.settlementWindow;
        _runtime.state = VaultState.Fundraising;
        _runtime.isActive = true;

        emit VaultOpened(openEnd);
        emit StateTransition(VaultState.CollateralDeposited, VaultState.Fundraising, block.timestamp);
    }

    /// @notice Governance bad-debt rescue. Pulls funds from controller and settles if sufficient.
    /// @param repayAmount Amount of supply asset to pull from controller.
    /// @custom:error NotBadDebt if collateral value >= debt value.
    /// @custom:event StateTransition, VaultLiquidated if total balance covers totalRaised.
    function repayBadDebt(uint256 repayAmount) external onlyController nonReentrant {
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidState();
        }

        if (_getCollateralValueUSD() >= _getDebtValueUSD()) revert NotBadDebt();

        IERC20 supplyToken = IERC20(address(_config.supplyAsset));

        if (repayAmount > 0) {
            supplyToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        }

        uint256 available = supplyToken.balanceOf(address(this));
        if (available < _runtime.totalRaised) revert InsufficientRepayment();

        VaultState from = _runtime.state;
        _runtime.state = VaultState.Liquidated;
        emit StateTransition(from, VaultState.Liquidated, block.timestamp);
        emit VaultLiquidated(available);
        _settleProtocolShare();
    }

    /// @notice Updates liquidation threshold. Controller only.
    /// @param newLT New liquidation threshold (mantissa).
    function setLiquidationThreshold(uint256 newLT) external onlyController {
        _riskConfig.liquidationThreshold = newLT;
    }

    /// @notice Updates liquidation incentive. Controller only.
    /// @param newLI New liquidation incentive (mantissa).
    function setLiquidationIncentive(uint256 newLI) external onlyController {
        _riskConfig.liquidationIncentive = newLI;
    }

    /// @notice Updates late penalty rate. Controller only.
    /// @param newRate New late penalty rate (mantissa).
    function setLatePenaltyRate(uint256 newRate) external onlyController {
        _riskConfig.latePenaltyRate = newRate;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Adapter-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice HF-based liquidation. LiquidationAdapter only.
     * @param repayAmount Amount of supply asset to repay.
     * @return actualRepay Actual amount repaid after clamping to outstanding debt.
     * @custom:error NoOutstandingDebt if there is no debt to repay.
     * @custom:error NotLiquidatable if vault has no LT shortfall.
     * @custom:error ExceedsCloseFactor if repay exceeds close factor limit.
     * @custom:error InsufficientCollateralForSeize if seize amount exceeds collateral balance.
     * @custom:event LiquidationExecuted
     */
    function liquidate(uint256 repayAmount) external onlyLiquidationAdapter nonReentrant returns (uint256 actualRepay) {
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
     * @custom:error NoOutstandingDebt if there is no debt to repay.
     * @custom:error InvalidStateForOverdueLiquidation if not in SettlementDeadlineExceeded.
     * @custom:error ExceedsCloseFactor if repay exceeds close factor limit.
     * @custom:error InsufficientCollateralForSeize if seize amount exceeds collateral balance.
     * @custom:event OverdueLiquidationExecuted
     */
    function liquidateOverdueVault(
        uint256 repayAmount
    ) external onlyLiquidationAdapter nonReentrant returns (uint256 actualRepay) {
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

    /// @notice Deposits collateral. WaitingForCollateral: must meet initialCollateralRequired. Lock: top-up.
    /// @param amount Amount of collateral tokens to deposit.
    /// @custom:error InsufficientCollateral if total collateral < initialCollateralRequired in WaitingForCollateral.
    /// @custom:event CollateralDeposited, StateTransition (if WaitingForCollateral -> CollateralDeposited)
    function depositCollateral(uint256 amount) external onlyPositionHolder nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.WaitingForCollateral && s != VaultState.Lock) revert InvalidState();

        IERC20 collateralToken = IERC20(address(_config.collateralAsset));
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 totalCollateral = collateralToken.balanceOf(address(this));
        uint256 actual = totalCollateral - balanceBefore;

        _runtime.totalCollateralDeposited += actual;
        emit CollateralDeposited(actual, totalCollateral);

        if (s == VaultState.WaitingForCollateral) {
            if (actual < _config.initialCollateralRequired) revert InsufficientCollateral();

            _runtime.minimumCollateralRequired = _config.initialCollateralRequired;
            _runtime.initialCollateralRequiredValuation = _getCollateralValueUSD();

            _runtime.state = VaultState.CollateralDeposited;
            emit StateTransition(VaultState.WaitingForCollateral, VaultState.CollateralDeposited, block.timestamp);
        }
    }

    /// @notice Withdraws collateral. Lock: floor-checked + LT-checked. Matured: capped at totalCollateralDeposited.
    /// @param amount Amount of collateral tokens to withdraw.
    /// @custom:error InsufficientCollateral if withdrawal would breach minimumCollateralRequired floor or exceed deposited amount.
    /// @custom:event CollateralWithdrawn
    function withdrawCollateral(uint256 amount) external onlyPositionHolder nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.Matured) revert InvalidState();

        IERC20 collateralToken = IERC20(address(_config.collateralAsset));

        if (s == VaultState.Lock) {
            uint256 collateralBalance = collateralToken.balanceOf(address(this));
            if (amount > collateralBalance - _runtime.minimumCollateralRequired) revert InsufficientCollateral();

            // LT check — skip if no debt outstanding
            if (_outstandingDebt() > 0) {
                (, uint256 shortfall) = _getHypotheticalVaultLiquidity(amount);
                if (shortfall > 0) revert WithdrawalWouldBreachLT();
            }
        }

        if (amount > _runtime.totalCollateralDeposited) revert InsufficientCollateral();
        _runtime.totalCollateralDeposited -= amount;

        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(amount);
    }

    /// @notice One-time fund withdrawal. Transfers all raised supply assets to institution.
    /// @custom:error AlreadyWithdrawn if funds already claimed.
    /// @custom:event RaisedFundsClaimed
    function claimRaisedFunds() external onlyPositionHolder nonReentrant whenNotPaused {
        _claimRaisedFunds(msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Permissionless (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Repays outstanding debt. Anyone may call. Clamped to outstandingDebt.
    /// @param amount Amount of supply asset to repay.
    /// @custom:error NoOutstandingDebt if there is no debt to repay.
    /// @custom:event Repaid
    function repay(uint256 amount) external nonReentrant whenNotPaused {
        _repay(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — View
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Current collateral value in USD via oracle.
    /// @return Collateral value in 18-decimal USD.
    function getCollateralValueUSD() external view returns (uint256) {
        return _getCollateralValueUSD();
    }

    /// @notice Current outstanding debt value in USD via oracle.
    /// @return Debt value in 18-decimal USD.
    function getDebtValueUSD() external view returns (uint256) {
        return _getDebtValueUSD();
    }

    /// @notice Returns the risk configuration.
    /// @return Risk parameters struct.
    function riskConfig() external view returns (RiskConfig memory) {
        return _riskConfig;
    }

    /// @notice Returns current liquidity and shortfall for the vault.
    /// @return liquidity Excess liquidity (0 if shortfall).
    /// @return shortfall LT shortfall (0 if healthy).
    function getVaultLiquidity() external view returns (uint256 liquidity, uint256 shortfall) {
        return _getHypotheticalVaultLiquidity(0);
    }

    /// @notice Returns hypothetical liquidity/shortfall after a simulated withdrawal.
    /// @param withdrawAmount Simulated collateral withdrawal amount.
    /// @return liquidity Excess liquidity (0 if shortfall).
    /// @return shortfall LT shortfall (0 if healthy).
    function getHypotheticalVaultLiquidity(
        uint256 withdrawAmount
    ) external view returns (uint256 liquidity, uint256 shortfall) {
        return _getHypotheticalVaultLiquidity(withdrawAmount);
    }

    /// @notice Preview seize amount for a given repay and liquidation type.
    /// @param repayAmount Amount being repaid.
    /// @param liquidationType HF_BASED or DEADLINE.
    /// @return Collateral seize amount.
    function calculateSeizeAmount(
        uint256 repayAmount,
        LiquidationType liquidationType
    ) external view returns (uint256) {
        return _calculateSeizeAmount(repayAmount, liquidationType);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — State-Changing
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Fundraising -> Lock or Failed transitions (only when fundraising window expires).
    function _advanceFromOpen() internal override {
        if (block.timestamp < _runtime.openEndTime) return;

        if (_runtime.totalRaised >= _config.minBorrowCap) {
            _runtime.state = VaultState.Lock;
            _runtime.totalOwed = _runtime.totalRaised + _computeTotalInterest();
            _runtime.minimumCollateralRequired =
                (_config.initialCollateralRequired * _runtime.totalRaised) / _config.maxBorrowCap;
            emit StateTransition(VaultState.Fundraising, VaultState.Lock, block.timestamp);
            emit VaultLocked(_runtime.totalRaised, _runtime.lockEndTime);
        } else {
            _runtime.state = VaultState.Failed;
            emit StateTransition(VaultState.Fundraising, VaultState.Failed, block.timestamp);
            emit VaultFailed(_runtime.totalRaised, _config.minBorrowCap);
        }
    }

    /**
     * @dev Shared liquidation execution: close factor check, seize calculation, token transfers.
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
        uint256 cf = ILiquidationAdapter(liquidationAdapter).closeFactor();
        uint256 maxRepay = (debt * cf) / MANTISSA;
        if (actualRepay > maxRepay) revert ExceedsCloseFactor();

        seizeAmount = _calculateSeizeAmount(actualRepay, liqType);
        IERC20 collateralToken = IERC20(address(_config.collateralAsset));
        uint256 collateralBalance = collateralToken.balanceOf(address(this));
        if (seizeAmount > collateralBalance) revert InsufficientCollateralForSeize(seizeAmount, collateralBalance);

        IERC20(address(_config.supplyAsset)).safeTransferFrom(msg.sender, address(this), actualRepay);
        _runtime.totalCollateralDeposited -= seizeAmount;
        collateralToken.safeTransfer(msg.sender, seizeAmount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — View
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Internal collateral USD valuation. Caches oracle and collateral address.
    function _getCollateralValueUSD() internal view returns (uint256) {
        address collateral = address(_config.collateralAsset);
        IResilientOracle oracleRef = IResilientOracle(IInstitutionalVaultController(vaultController).oracle());
        uint256 price = oracleRef.getPrice(collateral);
        uint8 decimals = IERC20Metadata(collateral).decimals();
        return (IERC20(collateral).balanceOf(address(this)) * price) / (10 ** decimals);
    }

    /// @dev Internal debt USD valuation. Caches oracle and supply address.
    function _getDebtValueUSD() internal view returns (uint256) {
        uint256 debt = _outstandingDebt();
        if (debt == 0) return 0;
        address supply = address(_config.supplyAsset);
        IResilientOracle oracleRef = IResilientOracle(IInstitutionalVaultController(vaultController).oracle());
        uint256 price = oracleRef.getPrice(supply);
        uint8 decimals = IERC20Metadata(supply).decimals();
        return (debt * price) / (10 ** decimals);
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
            uint256 collateralBalance = IERC20(address(_config.collateralAsset)).balanceOf(address(this));
            if (collateralBalance > 0) {
                withdrawValueUSD = (withdrawAmount * collateralUSD) / collateralBalance;
            }
        }

        uint256 collateralAfterWithdraw = collateralUSD > withdrawValueUSD ? collateralUSD - withdrawValueUSD : 0;
        uint256 ltCap = (collateralAfterWithdraw * lt) / MANTISSA;

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
        uint256 incentive = liqType == LiquidationType.HF_BASED
            ? rc.liquidationIncentive
            : rc.latePenaltyRate;

        address supplyAsset = address(_config.supplyAsset);
        address collateralAsset = address(_config.collateralAsset);
        IResilientOracle oracleRef = IResilientOracle(IInstitutionalVaultController(vaultController).oracle());

        uint256 supplyPrice = oracleRef.getPrice(supplyAsset);
        uint256 collateralPrice = oracleRef.getPrice(collateralAsset);

        if (collateralPrice == 0) return 0;

        uint8 supplyDecimals = IERC20Metadata(supplyAsset).decimals();
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();

        uint256 repayValueUSD = (repayAmount * supplyPrice) / (10 ** supplyDecimals);
        uint256 seizeValueUSD = (repayValueUSD * incentive) / MANTISSA;
        seizeAmount = (seizeValueUSD * (10 ** collateralDecimals)) / collateralPrice;
    }
}
