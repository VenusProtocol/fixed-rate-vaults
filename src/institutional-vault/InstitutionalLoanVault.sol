// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { BaseVault } from "../BaseVault.sol";
import { VaultConfig, RiskConfig, VaultState } from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionPositionToken } from "../interfaces/IInstitutionPositionToken.sol";
import { IInstitutionalVaultController } from "../interfaces/IInstitutionalVaultController.sol";
import { IResilientOracle } from "../interfaces/IResilientOracle.sol";

/// @title InstitutionalLoanVault
/// @notice ERC-4626 vault for institutional fixed-rate lending with on-chain collateral,
///         borrowing, and liquidation support. Deployed as EIP-1167 minimal proxy clones.
/// @dev Inherits BaseVault for shared ERC-4626 mechanics, fundraising, interest, settlement,
///      and core state machine. Adds: collateral deposit/withdraw, borrowing, risk checks,
///      liquidation entry points, and pre-fundraising states (WaitingForCollateral, CollateralDeposited).
///      No ACM — all governance calls are proxied through VaultController.
contract InstitutionalLoanVault is BaseVault {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Storage (extends BaseVault)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Risk parameters — CF immutable, LT/LI/latePenaltyRate mutable via controller.
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
    event RaisedFundsClaimed(uint256 amount);
    event Repaid(uint256 amount, uint256 remainingDebt);
    event LiquidationExecuted(address indexed liquidator, uint256 repayAmount, uint256 collateralSeized);
    event OverdueLiquidationExecuted(address indexed settler, uint256 repayAmount, uint256 collateralSeized);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InsufficientCollateral();
    error NotPositionHolder();
    error AlreadyWithdrawn();
    error PositionTokenIdNotSet();
    error InvalidStateForOverdueLiquidation();
    error NotBadDebt();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier onlyInstitution() {
        if (_config.positionTokenId == 0) revert PositionTokenIdNotSet();
        if (positionToken.ownerOf(_config.positionTokenId) != msg.sender) revert NotPositionHolder();
        _;
    }

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
        if (repayAmount == 0) return;

        IERC20 supplyToken = IERC20(address(_config.supplyAsset));
        supplyToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        uint256 available = supplyToken.balanceOf(address(this));
        if (available >= _runtime.totalRaised) {
            VaultState from = _runtime.state;
            _runtime.state = VaultState.Liquidated;
            emit StateTransition(from, VaultState.Liquidated, block.timestamp);
            _settleProtocolShare();
            emit VaultLiquidated(available);
        }
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

    /// @notice HF-based liquidation. LiquidationAdapter only.
    /// @param repayAmount Amount of supply asset to repay.
    /// @return actualRepay Actual amount repaid after clamping to outstanding debt.
    /// @custom:event LiquidationExecuted
    function liquidate(uint256 repayAmount) external onlyLiquidationAdapter nonReentrant returns (uint256 actualRepay) {
        uint256 debt = _outstandingDebt();
        actualRepay = repayAmount > debt ? debt : repayAmount;
        if (actualRepay == 0) return 0;

        address controller = vaultController;
        uint256 seizeAmount = IInstitutionalVaultController(controller).liquidateAllowed(
            address(this), actualRepay
        );

        IERC20(address(_config.supplyAsset)).safeTransferFrom(msg.sender, address(this), actualRepay);
        IERC20(address(_config.collateralAsset)).safeTransfer(msg.sender, seizeAmount);

        emit LiquidationExecuted(msg.sender, actualRepay, seizeAmount);
    }

    /// @notice Deadline-based liquidation. LiquidationAdapter only.
    /// @param repayAmount Amount of supply asset to repay.
    /// @return actualRepay Actual amount repaid after clamping to outstanding debt.
    /// @custom:error InvalidStateForOverdueLiquidation if not in SettlementDeadlineExceeded.
    /// @custom:event OverdueLiquidationExecuted
    function liquidateOverdueVault(
        uint256 repayAmount
    ) external onlyLiquidationAdapter nonReentrant returns (uint256 actualRepay) {
        _checkAndAdvanceState();
        if (_runtime.state != VaultState.SettlementDeadlineExceeded) revert InvalidStateForOverdueLiquidation();

        uint256 debt = _outstandingDebt();
        actualRepay = repayAmount > debt ? debt : repayAmount;
        if (actualRepay == 0) return 0;

        address controller = vaultController;
        uint256 seizeAmount = IInstitutionalVaultController(controller).liquidateOverdueAllowed(
            address(this), actualRepay
        );

        IERC20(address(_config.supplyAsset)).safeTransferFrom(msg.sender, address(this), actualRepay);
        IERC20(address(_config.collateralAsset)).safeTransfer(msg.sender, seizeAmount);

        emit OverdueLiquidationExecuted(msg.sender, actualRepay, seizeAmount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Institution-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Deposits collateral. WaitingForCollateral: must meet requiredCollateral. Lock: top-up.
    /// @param amount Amount of collateral tokens to deposit.
    /// @custom:error InsufficientCollateral if total collateral < requiredCollateral in WaitingForCollateral.
    /// @custom:event CollateralDeposited, StateTransition (if WaitingForCollateral -> CollateralDeposited)
    function depositCollateral(uint256 amount) external onlyInstitution nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.WaitingForCollateral && s != VaultState.Lock) revert InvalidState();

        IERC20 collateralToken = IERC20(address(_config.collateralAsset));
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 totalCollateral = collateralToken.balanceOf(address(this));
        uint256 actual = totalCollateral - balanceBefore;

        emit CollateralDeposited(actual, totalCollateral);

        if (s == VaultState.WaitingForCollateral) {
            if (totalCollateral < _config.requiredCollateral) revert InsufficientCollateral();

            _runtime.initialCollateralSupplied = totalCollateral;
            _runtime.initialCollateralValuation = _getCollateralValueUSD();

            _runtime.state = VaultState.CollateralDeposited;
            emit StateTransition(VaultState.WaitingForCollateral, VaultState.CollateralDeposited, block.timestamp);
        }
    }

    /// @notice Withdraws collateral. Lock: top-up only, LT-checked. Matured: all, unrestricted.
    /// @param amount Amount of collateral tokens to withdraw.
    /// @custom:error InsufficientCollateral if withdrawing more than top-up during Lock.
    /// @custom:event CollateralWithdrawn
    function withdrawCollateral(uint256 amount) external onlyInstitution nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.Matured) revert InvalidState();

        IERC20 collateralToken = IERC20(address(_config.collateralAsset));

        if (s == VaultState.Lock) {
            uint256 collateralBalance = collateralToken.balanceOf(address(this));
            if (amount > collateralBalance - _runtime.initialCollateralSupplied) revert InsufficientCollateral();
            IInstitutionalVaultController(vaultController).withdrawAllowed(address(this), amount);
        }

        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(amount);
    }

    /// @notice One-time fund withdrawal. Transfers all raised supply assets to institution.
    /// @custom:error AlreadyWithdrawn if funds already claimed.
    /// @custom:event RaisedFundsClaimed
    function claimRaisedFunds() external onlyInstitution nonReentrant whenNotPaused {
        _checkAndAdvanceState();
        if (_runtime.state != VaultState.Lock) revert InvalidState();
        if (_runtime.fundsWithdrawn) revert AlreadyWithdrawn();

        IERC20 supplyToken = IERC20(address(_config.supplyAsset));
        uint256 amount = supplyToken.balanceOf(address(this));
        _runtime.fundsWithdrawn = true;
        supplyToken.safeTransfer(msg.sender, amount);

        emit RaisedFundsClaimed(amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Permissionless (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Repays outstanding debt. Anyone may call. Clamped to outstandingDebt.
    /// @param amount Amount of supply asset to repay.
    /// @custom:event Repaid
    function repay(uint256 amount) external nonReentrant whenNotPaused {
        VaultState s = _runtime.state;
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidState();
        }

        uint256 debt = _outstandingDebt();
        uint256 amountClamped = amount > debt ? debt : amount;
        if (amountClamped == 0) return;

        IERC20(address(_config.supplyAsset)).safeTransferFrom(msg.sender, address(this), amountClamped);

        emit Repaid(amountClamped, _outstandingDebt());
        _checkAndAdvanceState();
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
}
