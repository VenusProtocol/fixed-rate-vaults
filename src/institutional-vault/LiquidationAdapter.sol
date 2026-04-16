// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { VaultConfig } from "../interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig } from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionalLoanVault } from "../interfaces/IInstitutionalLoanVault.sol";
import { IInstitutionalVaultController } from "../interfaces/IInstitutionalVaultController.sol";
import { IProtocolShareReserve } from "../interfaces/IProtocolShareReserve.sol";

/**
 * @title LiquidationAdapter
 * @notice Manages whitelisted liquidators/settlers, routes liquidation calls to Institutional Vault vaults,
 *         receives seized collateral, and splits incentive between protocol and caller.
 * @dev Deployed as a transparent proxy (upgradeable). Holds ACM for whitelist and config management.
 */
contract LiquidationAdapter is Initializable, AccessControlledV8, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    uint256 public constant MANTISSA_ONE = 1e18;

    // ──────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────

    /// @notice InstitutionalVaultController address (vaults are validated via controller).
    address public vaultController;

    /// @notice HF-based liquidators — can call liquidate() when LT shortfall > 0.
    mapping(address => bool) public isWhitelistedLiquidator;

    /// @notice Deadline-based settlers — can call liquidateOverdueVault() in SettlementDeadlineExceeded.
    mapping(address => bool) public isWhitelistedSettler;

    /// @notice Fraction of incentive portion to protocol (mantissa).
    uint256 public protocolLiquidationShare;

    /// @notice Max fraction of debt repayable per liquidation (mantissa). Global for all vaults.
    uint256 public closeFactor;

    /// @notice Accrued protocol share per collateral token. Swept to PSR via governance.
    mapping(address => uint256) public protocolShareAccrued;

    /// @dev Reserved storage gap for future upgrades.
    uint256[44] private __gap;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event LiquidatorWhitelistUpdated(address indexed liquidator, bool approved);
    event SettlerWhitelistUpdated(address indexed settler, bool approved);
    event ProtocolLiquidationShareUpdated(uint256 oldShare, uint256 newShare);
    event CloseFactorUpdated(uint256 oldCloseFactor, uint256 newCloseFactor);
    event LiquidationCollateralSplit(uint256 totalSeized, uint256 protocolAmount, uint256 callerAmount);
    event ProtocolShareSweptToReserve(address indexed collateral, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error NotWhitelistedLiquidator();
    error NotWhitelistedSettler();
    error VaultNotRegistered();
    error InvalidShare();
    error InvalidCloseFactor();
    error InvalidAddress();
    error ZeroRepayAmount();
    error OwnershipCannotBeRenounced();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier onlyWhitelistedLiquidator() {
        if (!isWhitelistedLiquidator[msg.sender]) revert NotWhitelistedLiquidator();
        _;
    }

    modifier onlyWhitelistedSettler() {
        if (!isWhitelistedSettler[msg.sender]) revert NotWhitelistedSettler();
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
    // External — ACM-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the adapter proxy.
     * @param vaultController_ VaultController address.
     * @param protocolLiquidationShare_ Initial protocol share of incentive (mantissa).
     * @param closeFactor_ Initial close factor (mantissa).
     * @param acm_ Venus AccessControlManager address.
     */
    function initialize(
        address vaultController_,
        uint256 protocolLiquidationShare_,
        uint256 closeFactor_,
        address acm_
    ) external initializer {
        __AccessControlled_init(acm_);
        __ReentrancyGuard_init();

        if (vaultController_ == address(0)) revert InvalidAddress();

        vaultController = vaultController_;
        if (protocolLiquidationShare_ > MANTISSA_ONE) revert InvalidShare();
        protocolLiquidationShare = protocolLiquidationShare_;
        if (closeFactor_ == 0 || closeFactor_ > MANTISSA_ONE) revert InvalidCloseFactor();
        closeFactor = closeFactor_;
    }

    /**
     * @notice Add or remove a liquidator from the whitelist.
     * @param liquidator Address to update.
     * @param approved Whether to approve or remove.
     * @custom:event LiquidatorWhitelistUpdated
     */
    function setLiquidatorWhitelist(
        address liquidator,
        bool approved
    ) external {
        _checkAccessAllowed("setLiquidatorWhitelist(address,bool)");
        isWhitelistedLiquidator[liquidator] = approved;
        emit LiquidatorWhitelistUpdated(liquidator, approved);
    }

    /**
     * @notice Add or remove a settler from the whitelist.
     * @param settler Address to update.
     * @param approved Whether to approve or remove.
     * @custom:event SettlerWhitelistUpdated
     */
    function setSettlerWhitelist(
        address settler,
        bool approved
    ) external {
        _checkAccessAllowed("setSettlerWhitelist(address,bool)");
        isWhitelistedSettler[settler] = approved;
        emit SettlerWhitelistUpdated(settler, approved);
    }

    /**
     * @notice Set the protocol share of the liquidation incentive (mantissa).
     * @param share New share (0 <= share <= 1e18).
     * @custom:error InvalidShare if share > 1e18.
     * @custom:event ProtocolLiquidationShareUpdated
     */
    function setProtocolLiquidationShare(
        uint256 share
    ) external {
        _checkAccessAllowed("setProtocolLiquidationShare(uint256)");
        if (share > MANTISSA_ONE) revert InvalidShare();
        emit ProtocolLiquidationShareUpdated(protocolLiquidationShare, share);
        protocolLiquidationShare = share;
    }

    /**
     * @notice Set max fraction of debt repayable per liquidation.
     * @param newCF New close factor (0 < newCF <= 1e18).
     * @custom:error InvalidCloseFactor if zero or > 1e18.
     * @custom:event CloseFactorUpdated
     */
    function setCloseFactor(
        uint256 newCF
    ) external {
        _checkAccessAllowed("setCloseFactor(uint256)");
        if (newCF == 0 || newCF > MANTISSA_ONE) revert InvalidCloseFactor();
        emit CloseFactorUpdated(closeFactor, newCF);
        closeFactor = newCF;
    }

    /**
     * @notice Transfer accrued protocol share for the given collateral token to PSR.
     * @param collateral Collateral token address.
     * @custom:event ProtocolShareSweptToReserve
     */
    function sweepProtocolShareToReserve(
        address collateral
    ) external {
        _checkAccessAllowed("sweepProtocolShareToReserve(address)");
        uint256 amount = protocolShareAccrued[collateral];
        if (amount == 0) return;

        protocolShareAccrued[collateral] = 0;
        IInstitutionalVaultController coreController = IInstitutionalVaultController(vaultController);
        address psr = coreController.protocolShareReserve();
        address comptroller = coreController.comptroller();
        IERC20(collateral).safeTransfer(psr, amount);
        IProtocolShareReserve(psr)
            .updateAssetsState(
                comptroller, collateral, IProtocolShareReserve.IncomeType.INSTITUTIONAL_VAULT_LIQUIDATION
            );
        emit ProtocolShareSweptToReserve(collateral, amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Whitelist-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice HF-based liquidation. Whitelisted liquidator only.
     * @param vault Vault address to liquidate.
     * @param repayAmount Amount of supply asset to repay.
     */
    function liquidate(
        address vault,
        uint256 repayAmount
    ) external onlyWhitelistedLiquidator nonReentrant {
        _executeLiquidation(vault, repayAmount, false);
    }

    /**
     * @notice Deadline-based liquidation. Whitelisted settler only.
     * @param vault Vault address to liquidate.
     * @param repayAmount Amount of supply asset to repay.
     */
    function liquidateOverdueVault(
        address vault,
        uint256 repayAmount
    ) external onlyWhitelistedSettler nonReentrant {
        _executeLiquidation(vault, repayAmount, true);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — State-Changing
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Shared liquidation execution logic. Caches config to avoid repeated external calls.
    function _executeLiquidation(
        address vault,
        uint256 repayAmount,
        bool isOverdue
    ) internal {
        if (repayAmount == 0) revert ZeroRepayAmount();
        if (!IInstitutionalVaultController(vaultController).isRegistered(vault)) revert VaultNotRegistered();

        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);
        VaultConfig memory cfg = v.config();
        InstitutionalConfig memory instCfg = v.institutionalConfig();
        IERC20 supplyAsset = IERC20(address(cfg.supplyAsset));
        IERC20 collateralAsset = IERC20(address(instCfg.collateralAsset));

        supplyAsset.safeTransferFrom(msg.sender, address(this), repayAmount);
        supplyAsset.forceApprove(vault, repayAmount);

        uint256 collateralBefore = collateralAsset.balanceOf(address(this));
        uint256 actualRepay = isOverdue ? v.liquidateOverdueVault(repayAmount) : v.liquidate(repayAmount);
        uint256 seized = collateralAsset.balanceOf(address(this)) - collateralBefore;

        // Refund excess supply asset if any
        if (actualRepay < repayAmount) {
            supplyAsset.safeTransfer(msg.sender, repayAmount - actualRepay);
            supplyAsset.forceApprove(vault, 0);
        }

        // Split seized collateral
        RiskConfig memory rc = v.riskConfig();
        uint256 incentive = isOverdue ? rc.latePenaltyRate : rc.liquidationIncentive;
        _splitAndTransferCollateral(collateralAsset, seized, incentive, msg.sender);
    }

    /**
     * @dev Splits seized collateral between protocol and caller.
     *      Protocol takes protocolLiquidationShare of the incentive portion only.
     */
    function _splitAndTransferCollateral(
        IERC20 collateral,
        uint256 totalSeized,
        uint256 incentive,
        address caller
    ) internal {
        if (totalSeized == 0) return;

        // totalSeized = repayEquivalent × incentive / MANTISSA_ONE
        uint256 repayEquivalent = (totalSeized * MANTISSA_ONE) / incentive;
        uint256 incentiveAmount = totalSeized - repayEquivalent;

        uint256 protocolShare = protocolLiquidationShare;
        uint256 protocolAmount = (incentiveAmount * protocolShare) / MANTISSA_ONE;
        uint256 callerAmount = totalSeized - protocolAmount;

        if (protocolAmount > 0) {
            protocolShareAccrued[address(collateral)] += protocolAmount;
        }
        if (callerAmount > 0) {
            collateral.safeTransfer(caller, callerAmount);
        }

        emit LiquidationCollateralSplit(totalSeized, protocolAmount, callerAmount);
    }

    /**
     * @notice Disabled — renouncing ownership would permanently brick ACM-gated liquidation governance.
     * @custom:error OwnershipCannotBeRenounced Always reverts.
     */
    function renounceOwnership() public override {
        revert OwnershipCannotBeRenounced();
    }
}
