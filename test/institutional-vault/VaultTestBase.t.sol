// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    AccessControlManager
} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlManager.sol";
import { ChainlinkOracle } from "@venusprotocol/oracle/contracts/oracles/ChainlinkOracle.sol";

import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { LiquidationAdapter } from "../../src/institutional-vault/LiquidationAdapter.sol";
import { InstitutionPositionToken } from "../../src/institutional-vault/InstitutionPositionToken.sol";

import { VaultConfig, VaultRuntime } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig } from "../../src/interfaces/IInstitutionalVaultTypes.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPSR } from "./mocks/MockPSR.sol";

abstract contract VaultTestBase is Test {
    // ── Default vault configuration constants
    // ──────────────────────────────
    uint256 internal constant MAX_BORROW_CAP = 1_000_000e18;
    uint256 internal constant MIN_BORROW_CAP = 500_000e18;
    uint256 internal constant FIXED_APY = 800; // 8 % in BPS
    uint256 internal constant RESERVE_FACTOR = 0.1e18; // 10 %
    uint40 internal constant OPEN_DURATION = 7 days;
    uint40 internal constant LOCK_DURATION = 365 days;
    uint40 internal constant SETTLEMENT_WINDOW = 30 days;

    uint256 internal constant IDEAL_COLLATERAL_AMOUNT = 1_500_000e18; // 150 % of maxBorrowCap
    uint256 internal constant MARGIN_RATE = 0.1e18; // 10 %
    uint256 internal constant MARGIN_AMOUNT = 150_000e18; // idealCollateral * marginRate / 1e18

    uint256 internal constant LT = 0.75e18;
    uint256 internal constant LI = 1.1e18;
    uint256 internal constant LATE_PENALTY_RATE = 1.15e18;
    uint256 internal constant CLOSE_FACTOR = 0.5e18;
    uint256 internal constant PROTOCOL_LIQ_SHARE = 0.1e18;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MANTISSA_ONE = 1e18;
    uint256 internal constant YEAR = 365 days;
    // ── Actors
    // ────────────────────────────────────────────────────────────
    address internal admin; // = address(this); holds ACM DEFAULT_ADMIN
    address internal institution;
    address internal lender1;
    address internal lender2;
    address internal liquidator;
    address internal settler;
    address internal proxyAdmin;
    address internal comptrollerAddr; // dummy comptroller address for PSR

    // ── Contracts
    // ────────────────────────────────────────────────────────
    InstitutionalVaultController internal controller;
    InstitutionalLoanVault internal vault;
    LiquidationAdapter internal adapter;
    InstitutionPositionToken internal posToken;
    MockERC20 internal supply;
    MockERC20 internal collateral;
    AccessControlManager internal acm;
    ChainlinkOracle internal oracle;
    MockPSR internal psr;

    // ──────────────────────────────────────────────────────────────────────
    // Setup helpers
    // ──────────────────────────────────────────────────────────────────────

    function _makeActors() internal {
        admin = address(this);
        institution = makeAddr("institution");
        lender1 = makeAddr("lender1");
        lender2 = makeAddr("lender2");
        liquidator = makeAddr("liquidator");
        settler = makeAddr("settler");
        proxyAdmin = makeAddr("proxyAdmin");
        comptrollerAddr = makeAddr("comptroller");
    }

    function _deployTokens() internal {
        supply = new MockERC20("Mock USDC", "mUSDC");
        collateral = new MockERC20("Mock BTC", "mBTC");
        psr = new MockPSR();
    }

    /// @dev Deploys and initialises the ChainlinkOracle proxy with an ACM reference.
    function _deployOracle() internal {
        // Deploy ACM — msg.sender (test contract) becomes DEFAULT_ADMIN.
        acm = new AccessControlManager();

        // Deploy ChainlinkOracle behind TransparentUpgradeableProxy.
        ChainlinkOracle oracleImpl = new ChainlinkOracle();
        oracle = ChainlinkOracle(
            address(
                new TransparentUpgradeableProxy(
                    address(oracleImpl), proxyAdmin, abi.encodeCall(ChainlinkOracle.initialize, (address(acm)))
                )
            )
        );

        // Grant admin permission to call setDirectPrice on any contract.
        acm.giveCallPermission(address(0), "setDirectPrice(address,uint256)", admin);

        // Set initial prices: $1 each (18-dec token).
        oracle.setDirectPrice(address(supply), 1e18);
        oracle.setDirectPrice(address(collateral), 1e18);
    }

    /// @dev Deploys all system contracts and wires them together.
    function _deploySystem() internal {
        _deployOracle();

        // InstitutionPositionToken — owned by test contract initially.
        posToken = new InstitutionPositionToken();

        // Vault implementation (for cloning).
        InstitutionalLoanVault vaultImpl = new InstitutionalLoanVault();

        // LiquidationAdapter implementation.
        LiquidationAdapter adapterImpl = new LiquidationAdapter();

        // Controller implementation.
        InstitutionalVaultController controllerImpl = new InstitutionalVaultController();

        // Deploy controller proxy with a placeholder adapter address (updated below).
        // This avoids the circular dependency: controller needs adapter, adapter needs controller.
        controller = InstitutionalVaultController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        InstitutionalVaultController.initialize,
                        (
                            address(vaultImpl),
                            address(1), // placeholder adapter — updated after adapter deploy
                            address(oracle),
                            address(psr),
                            comptrollerAddr,
                            makeAddr("treasury"),
                            address(posToken),
                            address(acm)
                        )
                    )
                )
            )
        );

        // Deploy adapter proxy with the real controller address.
        adapter = LiquidationAdapter(
            address(
                new TransparentUpgradeableProxy(
                    address(adapterImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        LiquidationAdapter.initialize,
                        (
                            address(controller),
                            address(psr),
                            comptrollerAddr,
                            PROTOCOL_LIQ_SHARE,
                            CLOSE_FACTOR,
                            address(acm)
                        )
                    )
                )
            )
        );

        // Grant all ACM permissions before calling any gated functions.
        _grantAllPermissions();

        // Update controller to use the real adapter.
        controller.setLiquidationAdapter(address(adapter));

        // Transfer posToken ownership to controller via 2-step Ownable.
        posToken.transferOwnership(address(controller));
        controller.acceptPositionTokenOwnership();
    }

    function _grantAllPermissions() internal {
        // Controller functions
        string[14] memory controllerSigs = [
            "acceptPositionTokenOwnership()",
            "createVault(VaultConfig,InstitutionalConfig,RiskConfig)",
            "openVault(address)",
            "partialPauseVault(address)",
            "completePauseVault(address)",
            "unpauseVault(address)",
            "closeVault(address)",
            "approvePositionTransfer(address)",
            "revokePositionTransfer(address)",
            "setLiquidationThreshold(address,uint256)",
            "setLiquidationIncentive(address,uint256)",
            "setLatePenaltyRate(address,uint256)",
            "setVaultImplementation(address)",
            "setLiquidationAdapter(address)"
        ];
        for (uint256 i; i < 14; ++i) {
            acm.giveCallPermission(address(0), controllerSigs[i], admin);
        }

        string[3] memory controllerSetterSigs =
            ["setOracle(address)", "setProtocolShareReserve(address)", "setComptroller(address)"];
        for (uint256 i; i < 3; ++i) {
            acm.giveCallPermission(address(0), controllerSetterSigs[i], admin);
        }

        // Adapter functions
        string[7] memory adapterSigs = [
            "setLiquidatorWhitelist(address,bool)",
            "setSettlerWhitelist(address,bool)",
            "setProtocolLiquidationShare(uint256)",
            "setCloseFactor(uint256)",
            "setProtocolShareReserve(address)",
            "setComptroller(address)",
            "sweepProtocolShareToReserve(address)"
        ];
        for (uint256 i; i < 7; ++i) {
            acm.giveCallPermission(address(0), adapterSigs[i], admin);
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Vault lifecycle helpers
    // ──────────────────────────────────────────────────────────────────────

    function _buildVaultConfig() internal view returns (VaultConfig memory) {
        return VaultConfig({
            supplyAsset: IERC20(address(supply)),
            fixedAPY: FIXED_APY,
            reserveFactor: RESERVE_FACTOR,
            minBorrowCap: MIN_BORROW_CAP,
            maxBorrowCap: MAX_BORROW_CAP,
            minSupplierDeposit: 0,
            openDuration: OPEN_DURATION,
            lockDuration: LOCK_DURATION,
            settlementWindow: SETTLEMENT_WINDOW
        });
    }

    function _buildInstConfig() internal view returns (InstitutionalConfig memory) {
        return InstitutionalConfig({
            collateralAsset: IERC20(address(collateral)),
            idealCollateralAmount: IDEAL_COLLATERAL_AMOUNT,
            marginRate: MARGIN_RATE,
            institutionOperator: institution,
            positionTokenId: 0 // assigned by controller on createVault
        });
    }

    function _buildRiskConfig() internal pure returns (RiskConfig memory) {
        return RiskConfig({ liquidationThreshold: LT, liquidationIncentive: LI, latePenaltyRate: LATE_PENALTY_RATE });
    }

    /// @dev Creates a vault clone and returns its address.
    function _createVault() internal returns (address vaultAddr) {
        vaultAddr = controller.createVault(_buildVaultConfig(), _buildInstConfig(), _buildRiskConfig());
        vault = InstitutionalLoanVault(vaultAddr);
    }

    /// @dev Institution deposits margin → controller opens vault (WaitingForMargin → Fundraising).
    function _openVault() internal {
        // Mint margin collateral to institution and deposit it.
        collateral.mint(institution, MARGIN_AMOUNT);
        vm.startPrank(institution);
        collateral.approve(address(vault), MARGIN_AMOUNT);
        vault.depositCollateral(MARGIN_AMOUNT);
        vm.stopPrank();

        // Controller opens the vault.
        controller.openVault(address(vault));
    }

    /// @dev Lenders deposit full cap; institution tops up remaining collateral; warp → Lock.
    function _lockVault() internal {
        // lender1 deposits full maxBorrowCap.
        supply.mint(lender1, MAX_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MAX_BORROW_CAP);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        // Institution deposits remaining collateral (ideal - margin already deposited).
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        // Advance time past the open window and trigger state transition.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
    }

    /// @dev Warp past lockEnd; institution repays all debt → Matured.
    function _settleVault() internal {
        uint256 lockEnd = vault.runtime().lockEndTime;
        vm.warp(lockEnd + 1);

        uint256 debt = vault.outstandingDebt();
        supply.mint(institution, debt);
        vm.startPrank(institution);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        // Trigger Matured transition.
        vault.updateVaultState();
    }

    /// @dev Changes oracle price for an asset. Price is in 18-decimal USD mantissa.
    function _setPrice(
        address asset,
        uint256 priceUSD18
    ) internal {
        oracle.setDirectPrice(asset, priceUSD18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Arithmetic helpers
    // ──────────────────────────────────────────────────────────────────────

    function _computeInterest(
        uint256 raised
    ) internal pure returns (uint256) {
        return (raised * FIXED_APY * LOCK_DURATION) / (BPS * YEAR);
    }

    function _computeProtocolFee(
        uint256 interest
    ) internal pure returns (uint256) {
        return (interest * RESERVE_FACTOR) / MANTISSA_ONE;
    }
}
