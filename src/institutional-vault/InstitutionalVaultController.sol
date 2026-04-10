// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { VaultConfig } from "../interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig, VaultStateInfo } from "../interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionalLoanVault } from "../interfaces/IInstitutionalLoanVault.sol";
import { IInstitutionPositionToken } from "../interfaces/IInstitutionPositionToken.sol";
import { IInstitutionalVaultController } from "../interfaces/IInstitutionalVaultController.sol";

/**
 * @title InstitutionalVaultController
 * @notice Central orchestrator for the Institutional Vault system. Deploys vault clones, maintains the registry,
 *         holds the Venus ACM reference, and proxies governance operations to vaults.
 * @dev Deployed as a transparent proxy (upgradeable via ProxyAdmin).
 */
contract InstitutionalVaultController is Initializable, AccessControlledV8, IInstitutionalVaultController {
    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    uint256 public constant MANTISSA_ONE = 1e18;

    /// @notice Maximum allowed multiplier for rate parameters (LI, LP). Caps bonus/penalty at 50% above mantissa.
    uint256 public constant MANTISSA_ONE_AND_HALF = 1.5e18;

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

    /// @notice Treasury address — recipient for swept tokens.
    address public treasury;

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
    uint256[40] private __gap;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event VaultCreated(address indexed vault, address indexed institution);
    event VaultImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event LiquidationAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ProtocolShareReserveUpdated(address indexed oldPSR, address indexed newPSR);
    event ComptrollerUpdated(address indexed oldComptroller, address indexed newComptroller);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event LiquidationThresholdUpdated(address indexed vault, uint256 newLT);
    event LiquidationIncentiveUpdated(address indexed vault, uint256 newLI);
    event LatePenaltyRateUpdated(address indexed vault, uint256 newRate);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error VaultNotRegistered();
    error InvalidConfig();
    error InvalidLiquidationThreshold();
    error InvalidLiquidationIncentive();
    error InvalidLatePenaltyRate();
    error InvalidAddress();
    error OwnershipCannotBeRenounced();

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
     * @param treasury_ Treasury address — recipient for swept tokens.
     * @param positionToken_ InstitutionPositionToken address.
     * @param acm_ Venus AccessControlManager address.
     */
    function initialize(
        address vaultImplementation_,
        address liquidationAdapter_,
        address oracle_,
        address protocolShareReserve_,
        address comptroller_,
        address treasury_,
        address positionToken_,
        address acm_
    ) external initializer {
        __AccessControlled_init(acm_);

        if (vaultImplementation_ == address(0)) revert InvalidAddress();
        if (liquidationAdapter_ == address(0)) revert InvalidAddress();
        if (oracle_ == address(0)) revert InvalidAddress();
        if (protocolShareReserve_ == address(0)) revert InvalidAddress();
        if (comptroller_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();
        if (positionToken_ == address(0)) revert InvalidAddress();

        vaultImplementation = vaultImplementation_;
        liquidationAdapter = liquidationAdapter_;
        oracle = oracle_;
        protocolShareReserve = protocolShareReserve_;
        comptroller = comptroller_;
        treasury = treasury_;
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
        InstitutionalConfig memory assembledInstConfig = _assembleInstConfig(_instConfig, tokenId);
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
     * @notice Partial pause — blocks general operations; repay and liquidation remain available.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function partialPauseVault(
        address vault
    ) external {
        _checkAccessAllowed("partialPauseVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).partialPause();
    }

    /**
     * @notice Complete pause — blocks all operations including repay and liquidation.
     * @param vault Vault address.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function completePauseVault(
        address vault
    ) external {
        _checkAccessAllowed("completePauseVault(address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).completePause();
    }

    /**
     * @notice Unpause vault — removes all pause restrictions.
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
     * @notice Recovers stuck tokens from a vault to treasury.
     * @param vault Vault address.
     * @param token Token address to sweep.
     * @custom:error VaultNotRegistered If vault is not in the registry.
     */
    function sweep(
        address vault,
        address token
    ) external {
        _checkAccessAllowed("sweep(address,address)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        IInstitutionalLoanVault(vault).sweep(token);
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
     * @custom:error InvalidLiquidationThreshold If newLT == 0 or newLT > MANTISSA_ONE.
     * @custom:event LiquidationThresholdUpdated
     */
    function setLiquidationThreshold(
        address vault,
        uint256 newLT
    ) external {
        _checkAccessAllowed("setLiquidationThreshold(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newLT == 0 || newLT > MANTISSA_ONE) revert InvalidLiquidationThreshold();
        emit LiquidationThresholdUpdated(vault, newLT);
        IInstitutionalLoanVault(vault).setLiquidationThreshold(newLT);
    }

    /**
     * @notice Updates liquidation incentive on a vault.
     * @param vault Vault address.
     * @param newLI New liquidation incentive (mantissa). Must be in range (MANTISSA_ONE, MANTISSA_ONE_AND_HALF].
     * @custom:error VaultNotRegistered If vault is not in the registry.
     * @custom:error InvalidLiquidationIncentive If newLI <= MANTISSA_ONE or newLI > MANTISSA_ONE_AND_HALF.
     * @custom:event LiquidationIncentiveUpdated
     */
    function setLiquidationIncentive(
        address vault,
        uint256 newLI
    ) external {
        _checkAccessAllowed("setLiquidationIncentive(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newLI <= MANTISSA_ONE || newLI > MANTISSA_ONE_AND_HALF) revert InvalidLiquidationIncentive();
        emit LiquidationIncentiveUpdated(vault, newLI);
        IInstitutionalLoanVault(vault).setLiquidationIncentive(newLI);
    }

    /**
     * @notice Updates late penalty rate on a vault.
     * @param vault Vault address.
     * @param newRate New late penalty rate (mantissa). Must be in range (MANTISSA_ONE, MANTISSA_ONE_AND_HALF].
     * @custom:error VaultNotRegistered If vault is not in the registry.
     * @custom:error InvalidLatePenaltyRate If newRate <= MANTISSA_ONE or newRate > MANTISSA_ONE_AND_HALF.
     * @custom:event LatePenaltyRateUpdated
     */
    function setLatePenaltyRate(
        address vault,
        uint256 newRate
    ) external {
        _checkAccessAllowed("setLatePenaltyRate(address,uint256)");
        if (!isRegistered[vault]) revert VaultNotRegistered();
        if (newRate <= MANTISSA_ONE || newRate > MANTISSA_ONE_AND_HALF) revert InvalidLatePenaltyRate();
        emit LatePenaltyRateUpdated(vault, newRate);
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

    /**
     * @notice Update treasury address for swept tokens.
     * @param treasury_ New treasury address.
     * @custom:error InvalidAddress if zero address.
     * @custom:event TreasuryUpdated
     */
    function setTreasury(
        address treasury_
    ) external {
        _checkAccessAllowed("setTreasury(address)");
        if (treasury_ == address(0)) revert InvalidAddress();
        emit TreasuryUpdated(treasury, treasury_);
        treasury = treasury_;
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
    function _assembleInstConfig(
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
        if (address(vaultConfig.supplyAsset) == address(0)) revert InvalidConfig();
        if (address(instConfig.collateralAsset) == address(0)) revert InvalidConfig();
        if (vaultConfig.minBorrowCap == 0 || vaultConfig.minBorrowCap > vaultConfig.maxBorrowCap) {
            revert InvalidConfig();
        }
        if (vaultConfig.maxBorrowCap == 0) revert InvalidConfig();
        if (vaultConfig.openDuration == 0 || vaultConfig.lockDuration == 0 || vaultConfig.settlementWindow == 0) {
            revert InvalidConfig();
        }
        if (address(vaultConfig.supplyAsset) == address(instConfig.collateralAsset)) revert InvalidConfig();
        if (vaultConfig.fixedAPY == 0) revert InvalidConfig();
        if (vaultConfig.reserveFactor > MANTISSA_ONE) revert InvalidConfig();
        // Institutional config validation
        if (instConfig.institutionOperator == address(0)) revert InvalidConfig();
        if (instConfig.idealCollateralAmount == 0) revert InvalidConfig();
        if (instConfig.marginRate == 0 || instConfig.marginRate > MANTISSA_ONE) revert InvalidConfig();
        // Risk config validation
        if (riskConfig.liquidationThreshold == 0 || riskConfig.liquidationThreshold > MANTISSA_ONE) {
            revert InvalidConfig();
        }
        if (riskConfig.liquidationIncentive <= MANTISSA_ONE || riskConfig.liquidationIncentive > MANTISSA_ONE_AND_HALF) revert InvalidConfig();
        if (riskConfig.latePenaltyRate <= MANTISSA_ONE || riskConfig.latePenaltyRate > MANTISSA_ONE_AND_HALF) {
            revert InvalidConfig();
        }
    }

    /**
     * @notice Disabled — renouncing ownership would permanently brick ACM-gated vault governance.
     * @custom:error OwnershipCannotBeRenounced Always reverts.
     */
    function renounceOwnership() public override {
        revert OwnershipCannotBeRenounced();
    }
}
