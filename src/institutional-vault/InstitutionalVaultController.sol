// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { VaultConfig } from "../interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig, VaultStateInfo } from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionalLoanVault } from "../interfaces/IInstitutionalLoanVault.sol";
import { IInstitutionPositionToken } from "../interfaces/IInstitutionPositionToken.sol";

/**
 * @title InstitutionalVaultController
 * @notice Central orchestrator for the Institutional Vault system. Deploys vault clones, maintains the registry,
 *         holds the Venus ACM reference, and proxies governance operations to vaults.
 * @dev Deployed as a transparent proxy (upgradeable via ProxyAdmin).
 */
contract InstitutionalVaultController is Initializable, AccessControlledV8 {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    uint256 public constant MANTISSA = 1e18;

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

    /// @dev Reserved storage gap for future upgrades.
    uint256[41] private __gap;

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
    error InvalidAddress();

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
     * @notice Initializes the controller proxy.
     * @param vaultImplementation_ InstitutionalLoanVault implementation for cloning.
     * @param liquidationAdapter_ LiquidationAdapter address.
     * @param oracle_ Venus ResilientOracle address.
     * @param protocolShareReserve_ PSR address.
     * @param comptroller_ Comptroller address for PSR.
     * @param positionToken_ InstitutionPositionToken address.
     * @param acm_ Venus AccessControlManager address.
     */
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

        if (vaultImplementation_ == address(0)) revert InvalidAddress();
        if (liquidationAdapter_ == address(0)) revert InvalidAddress();
        if (oracle_ == address(0)) revert InvalidAddress();
        if (protocolShareReserve_ == address(0)) revert InvalidAddress();
        if (comptroller_ == address(0)) revert InvalidAddress();
        if (positionToken_ == address(0)) revert InvalidAddress();

        vaultImplementation = vaultImplementation_;
        liquidationAdapter = liquidationAdapter_;
        oracle = oracle_;
        protocolShareReserve = protocolShareReserve_;
        comptroller = comptroller_;
        positionToken = IInstitutionPositionToken(positionToken_);
    }

    /**
     * @notice Accepts pending ownership of the InstitutionPositionToken.
     * @dev Required because PositionToken uses Ownable2Step. Call after transferOwnership.
     */
    function acceptPositionTokenOwnership() external {
        _checkAccessAllowed("acceptPositionTokenOwnership()");
        positionToken.acceptOwnership();
    }

    /**
     * @notice Deploys a new vault clone via deterministic CREATE2.
     * @param _vaultConfig Shared vault configuration (asset, rates, caps, timing).
     * @param _instConfig Institutional-specific configuration (collateral, sizing, position identity).
     * @param _riskConfig Risk parameters.
     * @return vault Deployed vault address.
     * @custom:event VaultCreated
     */
    function createVault(
        VaultConfig calldata _vaultConfig,
        InstitutionalConfig calldata _instConfig,
        RiskConfig calldata _riskConfig
    ) external returns (address vault) {
        _checkAccessAllowed("createVault(VaultConfig,InstitutionalConfig,RiskConfig)");
        _validateVaultConfig(_vaultConfig, _instConfig, _riskConfig);

        address institution = _instConfig.institutionOperator;
        bytes32 salt = keccak256(abi.encode(institution, institutionNonce[institution]));

        // Mint position token first (predict address for vault mapping)
        vault = Clones.predictDeterministicAddress(vaultImplementation, salt);
        uint256 tokenId = positionToken.mint(institution, vault);

        // Deploy clone
        vault = Clones.cloneDeterministic(vaultImplementation, salt);

        // Assemble institutional config with tokenId and initialize
        InstitutionalConfig memory assembledInstConfig = _withPositionTokenId(_instConfig, tokenId);
        IInstitutionalLoanVault(vault)
            .initialize(_vaultConfig, assembledInstConfig, _riskConfig, positionToken, liquidationAdapter);

        // Register
        institutionNonce[institution]++;
        allVaults.push(vault);
        isRegistered[vault] = true;

        emit VaultCreated(vault, institution);
    }

    /**
     * @notice Transitions MarginDeposited -> Open on a vault.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function openVault(
        address vault
    ) external {
        _checkAccessAllowed("openVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).openVault();
    }

    /**
     * @notice Emergency pause on vault.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function pauseVault(
        address vault
    ) external {
        _checkAccessAllowed("pauseVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).pause();
    }

    /**
     * @notice Unpause vault.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function unpauseVault(
        address vault
    ) external {
        _checkAccessAllowed("unpauseVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).unpause();
    }

    /**
     * @notice Sets isActive = false on vault.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function closeVault(
        address vault
    ) external {
        _checkAccessAllowed("closeVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).closeVault();
    }

    /**
     * @notice Bad-debt rescue. Pulls funds from caller and repays vault debt.
     * @param vault Vault address.
     * @param repayAmount Amount to pull from caller.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function repayBadDebt(
        address vault,
        uint256 repayAmount
    ) external {
        _checkAccessAllowed("repayBadDebt(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();

        IInstitutionalLoanVault v = IInstitutionalLoanVault(vault);

        if (repayAmount > 0) {
            IERC20 supplyAsset = IERC20(address(v.config().supplyAsset));
            supplyAsset.safeTransferFrom(msg.sender, address(this), repayAmount);
            supplyAsset.forceApprove(vault, repayAmount);
            v.repayBadDebt(repayAmount);
            supplyAsset.forceApprove(vault, 0);
        } else {
            v.repayBadDebt(0);
        }
    }

    /**
     * @notice Approves transfer of the vault's position token.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function approvePositionTransfer(
        address vault
    ) external {
        _checkAccessAllowed("approvePositionTransfer(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        uint256 tokenId = positionToken.vaultToTokenId(vault);
        positionToken.approveTransfer(tokenId);
    }

    /**
     * @notice Revokes a previously granted approval.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function revokePositionTransfer(
        address vault
    ) external {
        _checkAccessAllowed("revokePositionTransfer(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        uint256 tokenId = positionToken.vaultToTokenId(vault);
        positionToken.revokeTransferApproval(tokenId);
    }

    /**
     * @notice Updates liquidation threshold on a vault.
     * @param vault Vault address.
     * @param newLT New liquidation threshold (mantissa).
     * @custom:error VaultNotRegistered If vault is not in the registry.
     * @custom:error InvalidLiquidationThreshold If newLT == 0 or newLT > MANTISSA.
     */
    function setLiquidationThreshold(
        address vault,
        uint256 newLT
    ) external {
        _checkAccessAllowed("setLiquidationThreshold(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newLT == 0 || newLT > MANTISSA) revert InvalidLiquidationThreshold();
        IInstitutionalLoanVault(vault).setLiquidationThreshold(newLT);
    }

    /**
     * @notice Updates liquidation incentive on a vault.
     * @param vault Vault address.
     * @param newLI New liquidation incentive (mantissa).
     * @custom:error VaultNotRegistered If vault is not in the registry.
     * @custom:error InvalidLiquidationIncentive If outside (1e18, 1.3e18] range.
     */
    function setLiquidationIncentive(
        address vault,
        uint256 newLI
    ) external {
        _checkAccessAllowed("setLiquidationIncentive(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newLI <= 1e18 || newLI > 1.3e18) revert InvalidLiquidationIncentive();
        IInstitutionalLoanVault(vault).setLiquidationIncentive(newLI);
    }

    /**
     * @notice Updates late penalty rate on a vault.
     * @param vault Vault address.
     * @param newRate New late penalty rate (mantissa).
     * @custom:error VaultNotRegistered If vault is not in the registry.
     * @custom:error InvalidLatePenaltyRate If newRate <= 1e18.
     */
    function setLatePenaltyRate(
        address vault,
        uint256 newRate
    ) external {
        _checkAccessAllowed("setLatePenaltyRate(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newRate <= 1e18) revert InvalidLatePenaltyRate();
        IInstitutionalLoanVault(vault).setLatePenaltyRate(newRate);
    }

    /**
     * @notice Update clone source. Only affects future vaults.
     * @param impl New implementation address.
     * @custom:error InvalidAddress if zero address.
     * @custom:event VaultImplementationUpdated
     */
    function setVaultImplementation(
        address impl
    ) external {
        _checkAccessAllowed("setVaultImplementation(address)");
        if (impl == address(0)) revert InvalidAddress();
        emit VaultImplementationUpdated(vaultImplementation, impl);
        vaultImplementation = impl;
    }

    /**
     * @notice Update LiquidationAdapter address.
     * @param adapter New adapter address.
     * @custom:error InvalidAddress if zero address.
     * @custom:event LiquidationAdapterUpdated
     */
    function setLiquidationAdapter(
        address adapter
    ) external {
        _checkAccessAllowed("setLiquidationAdapter(address)");
        if (adapter == address(0)) revert InvalidAddress();
        emit LiquidationAdapterUpdated(liquidationAdapter, adapter);
        liquidationAdapter = adapter;
    }

    /**
     * @notice Update ResilientOracle reference.
     * @param oracle_ New oracle address.
     * @custom:error InvalidAddress if zero address.
     * @custom:event OracleUpdated
     */
    function setOracle(
        address oracle_
    ) external {
        _checkAccessAllowed("setOracle(address)");
        if (oracle_ == address(0)) revert InvalidAddress();
        emit OracleUpdated(oracle, oracle_);
        oracle = oracle_;
    }

    /**
     * @notice Update ProtocolShareReserve address.
     * @param psr New PSR address.
     * @custom:error InvalidAddress if zero address.
     * @custom:event ProtocolShareReserveUpdated
     */
    function setProtocolShareReserve(
        address psr
    ) external {
        _checkAccessAllowed("setProtocolShareReserve(address)");
        if (psr == address(0)) revert InvalidAddress();
        emit ProtocolShareReserveUpdated(protocolShareReserve, psr);
        protocolShareReserve = psr;
    }

    /**
     * @notice Update comptroller address for PSR.
     * @param comptroller_ New comptroller address.
     * @custom:error InvalidAddress if zero address.
     * @custom:event ComptrollerUpdated
     */
    function setComptroller(
        address comptroller_
    ) external {
        _checkAccessAllowed("setComptroller(address)");
        if (comptroller_ == address(0)) revert InvalidAddress();
        emit ComptrollerUpdated(comptroller, comptroller_);
        comptroller = comptroller_;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — View
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Predicts the next vault address for a given institution.
     * @param institution Institution operator address.
     * @return Predicted vault address.
     */
    function predictVaultAddress(
        address institution
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(institution, institutionNonce[institution]));
        return Clones.predictDeterministicAddress(vaultImplementation, salt);
    }

    /**
     * @notice Returns state summary for all registered vaults.
     * @return Array of VaultStateInfo structs.
     */
    function getAggregatedVaultStates() external view returns (VaultStateInfo[] memory) {
        uint256 len = allVaults.length;
        VaultStateInfo[] memory infos = new VaultStateInfo[](len);
        for (uint256 i; i < len;) {
            address v = allVaults[i];
            IInstitutionalLoanVault vault = IInstitutionalLoanVault(v);
            infos[i] = VaultStateInfo({
                vault: v,
                state: vault.state(),
                institutionOperator: vault.institutionalConfig().institutionOperator,
                totalRaised: vault.runtime().totalRaised,
                outstandingDebt: vault.outstandingDebt()
            });
            unchecked {
                ++i;
            }
        }
        return infos;
    }

    /**
     * @notice Returns total number of deployed vaults.
     * @return Number of vaults in registry.
     */
    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Pure
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Assembles InstitutionalConfig with the minted tokenId.
    function _withPositionTokenId(
        InstitutionalConfig calldata c,
        uint256 tokenId
    ) internal pure returns (InstitutionalConfig memory) {
        return InstitutionalConfig({
            collateralAsset: c.collateralAsset,
            idealCollateralAmount: c.idealCollateralAmount,
            marginRate: c.marginRate,
            institutionOperator: c.institutionOperator,
            positionTokenId: tokenId
        });
    }

    /// @dev Validates shared vault config, institutional config, and risk config at creation.
    function _validateVaultConfig(
        VaultConfig calldata vaultConfig,
        InstitutionalConfig calldata instConfig,
        RiskConfig calldata riskConfig
    ) internal pure {
        // Shared config validation
        if (vaultConfig.minBorrowCap > vaultConfig.maxBorrowCap) revert InvalidConfig();
        if (vaultConfig.maxBorrowCap == 0) revert InvalidConfig();
        if (vaultConfig.openDuration == 0 || vaultConfig.lockDuration == 0 || vaultConfig.settlementWindow == 0) revert InvalidConfig();
        if (address(vaultConfig.supplyAsset) == address(instConfig.collateralAsset)) revert InvalidConfig();
        if (vaultConfig.fixedAPY == 0) revert InvalidConfig();
        if (vaultConfig.reserveFactor > MANTISSA) revert InvalidConfig();
        // Institutional config validation
        if (instConfig.institutionOperator == address(0)) revert InvalidConfig();
        if (instConfig.idealCollateralAmount == 0) revert InvalidConfig();
        if (instConfig.marginRate == 0 || instConfig.marginRate > MANTISSA) revert InvalidConfig();
        // Risk config validation
        if (riskConfig.liquidationThreshold == 0 || riskConfig.liquidationThreshold > MANTISSA) revert InvalidConfig();
        if (riskConfig.liquidationIncentive <= 1e18) revert InvalidConfig();
        if (riskConfig.latePenaltyRate <= 1e18) revert InvalidConfig();
    }
}
