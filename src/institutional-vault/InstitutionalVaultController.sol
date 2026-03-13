// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { VaultConfig, RiskConfig, VaultState, VaultStateInfo, LiquidationType } from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionalLoanVault } from "../interfaces/IInstitutionalLoanVault.sol";
import { IInstitutionPositionToken } from "../interfaces/IInstitutionPositionToken.sol";
import { ILiquidationAdapter } from "../interfaces/ILiquidationAdapter.sol";
import { AccountLiquidityLib } from "../lib/AccountLiquidityLib.sol";

/// @title InstitutionalVaultController
/// @notice Central orchestrator for the Institutional Vault system. Deploys vault clones, maintains the registry,
///         holds the Venus ACM reference, and contains all risk validation logic.
/// @dev Deployed as a transparent proxy (upgradeable via ProxyAdmin).
contract InstitutionalVaultController is Initializable, AccessControlledV8 {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    uint256 internal constant MANTISSA = 1e18;

    // ──────────────────────────────────────────────────────────────────────
    // Storage — Core Configuration
    // ──────────────────────────────────────────────────────────────────────

    /// @notice InstitutionalLoanVault implementation address for cloning.
    address public vaultImplementation;

    /// @notice LiquidationAdapter contract address.
    address public liquidationAdapter;

    /// @notice Venus ResilientOracle address.
    address public oracle;

    /// @notice Venus ProtocolShareReserve (PSR) address.
    address public protocolShareReserve;

    /// @notice Comptroller address for PSR integration.
    address public comptroller;

    /// @notice InstitutionPositionToken contract address.
    IInstitutionPositionToken public positionToken;

    // ──────────────────────────────────────────────────────────────────────
    // Storage — Registry
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Array of all deployed vault addresses.
    address[] public allVaults;

    /// @notice Whether a vault is registered.
    mapping(address => bool) public isRegistered;

    /// @notice Per-institution deploy counter (for CREATE2 salt).
    mapping(address => uint256) public institutionNonce;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event VaultCreated(address indexed vault, address indexed institution);
    event VaultImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event LiquidationAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ProtocolShareReserveUpdated(address indexed oldPSR, address indexed newPSR);
    event ComptrollerUpdated(address indexed oldComptroller, address indexed newComptroller);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error VaultNotRegistered();
    error InvalidConfig();
    error InvalidLiquidationThreshold();
    error InvalidLiquidationIncentive();
    error InvalidLatePenaltyRate();
    error WithdrawalWouldBreachLT();
    error InvalidStateForLiquidation();
    error NotLiquidatable();
    error NotSettlementDeadlineExceeded();
    error ExceedsCloseFactor();
    error InsufficientCollateral(uint256 seizeAmount, uint256 availableCollateral);
    error InvalidAddress();

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Validates vault is registered AND is the direct caller.
    modifier onlyRegisteredVault(address vault) {
        if (!isRegistered[vault] || vault != msg.sender) revert VaultNotRegistered();
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

    /// @notice Initializes the controller proxy.
    /// @param vaultImplementation_ InstitutionalLoanVault implementation for cloning.
    /// @param liquidationAdapter_ LiquidationAdapter address.
    /// @param oracle_ Venus ResilientOracle address.
    /// @param protocolShareReserve_ PSR address.
    /// @param comptroller_ Comptroller address for PSR.
    /// @param positionToken_ InstitutionPositionToken address.
    /// @param acm_ Venus AccessControlManager address.
    function initialize(
        address vaultImplementation_,
        address liquidationAdapter_,
        address oracle_,
        address protocolShareReserve_,
        address comptroller_,
        address positionToken_,
        address acm_
    ) external initializer {
        __AccessControlled_init(acm_);

        vaultImplementation = vaultImplementation_;
        liquidationAdapter = liquidationAdapter_;
        oracle = oracle_;
        protocolShareReserve = protocolShareReserve_;
        comptroller = comptroller_;
        positionToken = IInstitutionPositionToken(positionToken_);
    }

    /// @notice Deploys a new vault clone via deterministic CREATE2.
    /// @param _config Vault configuration.
    /// @param _riskConfig Risk parameters.
    /// @return vault Deployed vault address.
    /// @custom:event VaultCreated
    function createVault(
        VaultConfig calldata _config,
        RiskConfig calldata _riskConfig
    ) external returns (address vault) {
        _checkAccessAllowed("createVault(VaultConfig,RiskConfig)");
        _validateVaultConfig(_config, _riskConfig);

        address institution = _config.institutionOperator;
        bytes32 salt = keccak256(abi.encode(institution, institutionNonce[institution]));

        // Mint position token first (predict address for vault mapping)
        vault = Clones.predictDeterministicAddress(vaultImplementation, salt);
        uint256 tokenId = positionToken.mint(institution, vault);

        // Deploy clone
        vault = Clones.cloneDeterministic(vaultImplementation, salt);

        // Assemble config with tokenId and initialize
        VaultConfig memory assembledConfig = _assembleVaultConfig(_config, tokenId);
        IInstitutionalLoanVault(vault).initialize(
            assembledConfig, _riskConfig, positionToken, liquidationAdapter
        );

        // Register
        institutionNonce[institution]++;
        allVaults.push(vault);
        isRegistered[vault] = true;

        emit VaultCreated(vault, institution);
    }

    /// @notice Transitions CollateralDeposited -> Open on a vault.
    /// @param vault Vault address.
    function openVault(address vault) external {
        _checkAccessAllowed("openVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).openVault();
    }

    /// @notice Emergency pause on vault.
    /// @param vault Vault address.
    function pauseVault(address vault) external {
        _checkAccessAllowed("pauseVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).pause();
    }

    /// @notice Unpause vault.
    /// @param vault Vault address.
    function unpauseVault(address vault) external {
        _checkAccessAllowed("unpauseVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).unpause();
    }

    /// @notice Sets isActive = false on vault.
    /// @param vault Vault address.
    function closeVault(address vault) external {
        _checkAccessAllowed("closeVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).closeVault();
    }

    /// @notice Bad-debt rescue. Pulls funds from caller and repays vault debt.
    /// @param vault Vault address.
    /// @param repayAmount Amount to pull from caller.
    function repayBadDebt(address vault, uint256 repayAmount) external {
        _checkAccessAllowed("repayBadDebt(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (repayAmount == 0) return;

        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);
        IERC20 supplyAsset = IERC20(address(v.config().supplyAsset));
        supplyAsset.safeTransferFrom(msg.sender, address(this), repayAmount);
        supplyAsset.forceApprove(vault, repayAmount);
        v.repayBadDebt(repayAmount);
        supplyAsset.forceApprove(vault, 0);
    }

    /// @notice Approves transfer of the vault's position token.
    /// @param vault Vault address.
    function approvePositionTransfer(address vault) external {
        _checkAccessAllowed("approvePositionTransfer(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        uint256 tokenId = positionToken.vaultToTokenId(vault);
        positionToken.approveTransfer(tokenId);
    }

    /// @notice Revokes a previously granted approval.
    /// @param vault Vault address.
    function revokePositionTransfer(address vault) external {
        _checkAccessAllowed("revokePositionTransfer(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        uint256 tokenId = positionToken.vaultToTokenId(vault);
        positionToken.revokeTransferApproval(tokenId);
    }

    /// @notice Updates liquidation threshold on a vault.
    /// @param vault Vault address.
    /// @param newLT New liquidation threshold (mantissa).
    /// @custom:error InvalidLiquidationThreshold if newLT <= CF or newLT > MANTISSA.
    function setLiquidationThreshold(address vault, uint256 newLT) external {
        _checkAccessAllowed("setLiquidationThreshold(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        uint256 cf = IInstitutionalLoanVault(vault).riskConfig().collateralFactor;
        if (newLT <= cf || newLT > MANTISSA) revert InvalidLiquidationThreshold();
        IInstitutionalLoanVault(vault).setLiquidationThreshold(newLT);
    }

    /// @notice Updates liquidation incentive on a vault.
    /// @param vault Vault address.
    /// @param newLI New liquidation incentive (mantissa).
    /// @custom:error InvalidLiquidationIncentive if outside (1e18, 1.3e18] range.
    function setLiquidationIncentive(address vault, uint256 newLI) external {
        _checkAccessAllowed("setLiquidationIncentive(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newLI <= 1e18 || newLI > 1.3e18) revert InvalidLiquidationIncentive();
        IInstitutionalLoanVault(vault).setLiquidationIncentive(newLI);
    }

    /// @notice Updates late penalty rate on a vault.
    /// @param vault Vault address.
    /// @param newRate New late penalty rate (mantissa).
    /// @custom:error InvalidLatePenaltyRate if newRate <= 1e18.
    function setLatePenaltyRate(address vault, uint256 newRate) external {
        _checkAccessAllowed("setLatePenaltyRate(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newRate <= 1e18) revert InvalidLatePenaltyRate();
        IInstitutionalLoanVault(vault).setLatePenaltyRate(newRate);
    }

    /// @notice Update clone source. Only affects future vaults.
    /// @param impl New implementation address.
    /// @custom:error InvalidAddress if zero address.
    /// @custom:event VaultImplementationUpdated
    function setVaultImplementation(address impl) external {
        _checkAccessAllowed("setVaultImplementation(address)");
        if (impl == address(0)) revert InvalidAddress();
        emit VaultImplementationUpdated(vaultImplementation, impl);
        vaultImplementation = impl;
    }

    /// @notice Update LiquidationAdapter address.
    /// @param adapter New adapter address.
    /// @custom:error InvalidAddress if zero address.
    /// @custom:event LiquidationAdapterUpdated
    function setLiquidationAdapter(address adapter) external {
        _checkAccessAllowed("setLiquidationAdapter(address)");
        if (adapter == address(0)) revert InvalidAddress();
        emit LiquidationAdapterUpdated(liquidationAdapter, adapter);
        liquidationAdapter = adapter;
    }

    /// @notice Update ResilientOracle reference.
    /// @param oracle_ New oracle address.
    /// @custom:error InvalidAddress if zero address.
    /// @custom:event OracleUpdated
    function setOracle(address oracle_) external {
        _checkAccessAllowed("setOracle(address)");
        if (oracle_ == address(0)) revert InvalidAddress();
        emit OracleUpdated(oracle, oracle_);
        oracle = oracle_;
    }

    /// @notice Update ProtocolShareReserve address.
    /// @param psr New PSR address.
    /// @custom:error InvalidAddress if zero address.
    /// @custom:event ProtocolShareReserveUpdated
    function setProtocolShareReserve(address psr) external {
        _checkAccessAllowed("setProtocolShareReserve(address)");
        if (psr == address(0)) revert InvalidAddress();
        emit ProtocolShareReserveUpdated(protocolShareReserve, psr);
        protocolShareReserve = psr;
    }

    /// @notice Update comptroller address for PSR.
    /// @param comptroller_ New comptroller address.
    /// @custom:error InvalidAddress if zero address.
    /// @custom:event ComptrollerUpdated
    function setComptroller(address comptroller_) external {
        _checkAccessAllowed("setComptroller(address)");
        if (comptroller_ == address(0)) revert InvalidAddress();
        emit ComptrollerUpdated(comptroller, comptroller_);
        comptroller = comptroller_;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Vault-Gated (View) — Risk Hooks
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Validates that collateral withdrawal does not breach LT.
    /// @param vault Vault address (must be msg.sender).
    /// @param withdrawAmount Amount of collateral tokens to withdraw.
    /// @custom:error WithdrawalWouldBreachLT if shortfall > 0 after hypothetical withdrawal.
    function withdrawAllowed(address vault, uint256 withdrawAmount) external view onlyRegisteredVault(vault) {
        if (IInstitutionalLoanVault(vault).outstandingDebt() == 0) return;

        (, uint256 shortfall) = AccountLiquidityLib.getHypotheticalAccountLiquidity(vault, withdrawAmount);
        if (shortfall > 0) revert WithdrawalWouldBreachLT();
    }

    /// @notice Validates HF-based liquidation and returns seize amount.
    /// @param vault Vault address (must be msg.sender).
    /// @param repayAmount Amount being repaid.
    /// @return seizeAmount Collateral to seize.
    /// @custom:error InvalidStateForLiquidation, NotLiquidatable, ExceedsCloseFactor, InsufficientCollateral.
    function liquidateAllowed(
        address vault,
        uint256 repayAmount
    ) external view onlyRegisteredVault(vault) returns (uint256 seizeAmount) {
        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);
        VaultState s = v.state();
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            revert InvalidStateForLiquidation();
        }

        (, uint256 shortfall) = AccountLiquidityLib.getHypotheticalAccountLiquidity(vault, 0);
        if (shortfall == 0) revert NotLiquidatable();

        uint256 debt = v.outstandingDebt();
        uint256 cf = ILiquidationAdapter(liquidationAdapter).closeFactor();
        uint256 maxRepay = (debt * cf) / MANTISSA;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor();

        seizeAmount = _calculateSeizeAmountInternal(vault, repayAmount, LiquidationType.HF_BASED);
        uint256 collateralBalance = IERC20(address(v.config().collateralAsset)).balanceOf(vault);
        if (seizeAmount > collateralBalance) revert InsufficientCollateral(seizeAmount, collateralBalance);
    }

    /// @notice Validates deadline-based liquidation and returns seize amount.
    /// @param vault Vault address (must be msg.sender).
    /// @param repayAmount Amount being repaid.
    /// @return seizeAmount Collateral to seize.
    /// @custom:error NotSettlementDeadlineExceeded, ExceedsCloseFactor, InsufficientCollateral.
    function liquidateOverdueAllowed(
        address vault,
        uint256 repayAmount
    ) external view onlyRegisteredVault(vault) returns (uint256 seizeAmount) {
        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);
        if (v.state() != VaultState.SettlementDeadlineExceeded) {
            revert NotSettlementDeadlineExceeded();
        }

        uint256 debt = v.outstandingDebt();
        uint256 cf = ILiquidationAdapter(liquidationAdapter).closeFactor();
        uint256 maxRepay = (debt * cf) / MANTISSA;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor();

        seizeAmount = _calculateSeizeAmountInternal(vault, repayAmount, LiquidationType.DEADLINE);
        uint256 collateralBalance = IERC20(address(v.config().collateralAsset)).balanceOf(vault);
        if (seizeAmount > collateralBalance) revert InsufficientCollateral(seizeAmount, collateralBalance);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — View
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Predicts the next vault address for a given institution.
    /// @param institution Institution operator address.
    /// @return Predicted vault address.
    function predictVaultAddress(address institution) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(institution, institutionNonce[institution]));
        return Clones.predictDeterministicAddress(vaultImplementation, salt);
    }

    /// @notice Returns current liquidity and shortfall for a vault.
    /// @param vault Vault address.
    /// @return liquidity Excess liquidity (0 if shortfall).
    /// @return shortfall LT shortfall (0 if healthy).
    function getAccountLiquidity(address vault) external view returns (uint256 liquidity, uint256 shortfall) {
        return AccountLiquidityLib.getHypotheticalAccountLiquidity(vault, 0);
    }

    /// @notice Returns hypothetical liquidity/shortfall after a simulated withdrawal.
    /// @param vault Vault address.
    /// @param withdrawAmount Simulated collateral withdrawal amount.
    /// @return liquidity Excess liquidity (0 if shortfall).
    /// @return shortfall LT shortfall (0 if healthy).
    function getHypotheticalAccountLiquidity(
        address vault,
        uint256 withdrawAmount
    ) external view returns (uint256 liquidity, uint256 shortfall) {
        return AccountLiquidityLib.getHypotheticalAccountLiquidity(vault, withdrawAmount);
    }

    /// @notice Preview seize amount for a given repay and liquidation type.
    /// @param vault Vault address.
    /// @param repayAmount Amount being repaid.
    /// @param liquidationType HF_BASED or DEADLINE.
    /// @return Collateral seize amount.
    function calculateSeizeAmount(
        address vault,
        uint256 repayAmount,
        LiquidationType liquidationType
    ) external view returns (uint256) {
        if (!isRegistered[vault]) revert VaultNotRegistered();
        return _calculateSeizeAmountInternal(vault, repayAmount, liquidationType);
    }

    /// @notice Returns state summary for all registered vaults.
    /// @return Array of VaultStateInfo structs.
    function getAggregatedVaultStates() external view returns (VaultStateInfo[] memory) {
        uint256 len = allVaults.length;
        VaultStateInfo[] memory infos = new VaultStateInfo[](len);
        for (uint256 i; i < len;) {
            address v = allVaults[i];
            IInstitutionalLoanVault vault = IInstitutionalLoanVault(v);
            infos[i] = VaultStateInfo({
                vault: v,
                state: vault.state(),
                institutionOperator: vault.config().institutionOperator,
                totalRaised: vault.runtime().totalRaised,
                outstandingDebt: vault.outstandingDebt()
            });
            unchecked { ++i; }
        }
        return infos;
    }

    /// @notice Returns total number of deployed vaults.
    /// @return Number of vaults in registry.
    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Pure
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Assembles VaultConfig with the minted tokenId.
    function _assembleVaultConfig(
        VaultConfig calldata c,
        uint256 tokenId
    ) internal pure returns (VaultConfig memory) {
        return VaultConfig({
            supplyAsset: c.supplyAsset,
            collateralAsset: c.collateralAsset,
            requiredCollateral: c.requiredCollateral,
            fixedAPY: c.fixedAPY,
            minBorrowCap: c.minBorrowCap,
            maxBorrowCap: c.maxBorrowCap,
            openDuration: c.openDuration,
            lockDuration: c.lockDuration,
            settlementWindow: c.settlementWindow,
            reserveFactor: c.reserveFactor,
            institutionOperator: c.institutionOperator,
            positionTokenId: tokenId,
            minSupplierDeposit: c.minSupplierDeposit
        });
    }

    /// @dev Validates vault and risk config at creation.
    function _validateVaultConfig(VaultConfig calldata c, RiskConfig calldata r) internal pure {
        if (c.requiredCollateral == 0) revert InvalidConfig();
        if (c.minBorrowCap > c.maxBorrowCap) revert InvalidConfig();
        if (c.maxBorrowCap == 0) revert InvalidConfig();
        if (c.openDuration == 0 || c.lockDuration == 0 || c.settlementWindow == 0) revert InvalidConfig();
        if (r.collateralFactor == 0 || r.collateralFactor >= MANTISSA) revert InvalidConfig();
        if (r.liquidationThreshold <= r.collateralFactor || r.liquidationThreshold > MANTISSA) revert InvalidConfig();
        if (r.liquidationIncentive <= 1e18 || r.liquidationIncentive > 1.3e18) revert InvalidConfig();
        if (r.latePenaltyRate <= 1e18) revert InvalidConfig();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — View
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Selects incentive by LiquidationType and delegates to library. Caches riskConfig.
    function _calculateSeizeAmountInternal(
        address vault,
        uint256 repayAmount,
        LiquidationType liqType
    ) internal view returns (uint256) {
        RiskConfig memory rc = IInstitutionalLoanVault(vault).riskConfig();
        uint256 incentive = liqType == LiquidationType.HF_BASED
            ? rc.liquidationIncentive
            : rc.latePenaltyRate;
        return AccountLiquidityLib.calculateSeizeAmount(vault, repayAmount, incentive);
    }
}
