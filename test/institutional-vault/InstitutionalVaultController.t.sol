// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { VaultConfig, VaultState, PauseLevel } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig, VaultStateInfo } from "../../src/interfaces/IInstitutionalVaultTypes.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InstitutionalVaultControllerTest is VaultTestBase {
    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5A — Initialization
    // ──────────────────────────────────────────────────────────────────────

    function test_initialize_setsAllParams() external {
        assertEq(controller.vaultImplementation(), _getVaultImpl());
        assertEq(controller.liquidationAdapter(), address(adapter));
        assertEq(controller.oracle(), address(oracle));
        assertEq(controller.protocolShareReserve(), address(psr));
        assertEq(controller.comptroller(), comptrollerAddr);
        assertEq(address(controller.positionToken()), address(posToken));
    }

    function test_initialize_revertsIfCalledTwice() external {
        vm.expectRevert("Initializable: contract is already initialized");
        controller.initialize(
            address(1),
            address(adapter),
            address(oracle),
            address(psr),
            comptrollerAddr,
            address(posToken),
            address(acm)
        );
    }

    function test_initialize_revertsIfZeroAddress() external {
        InstitutionalVaultController impl = new InstitutionalVaultController();
        address impl_ = address(impl);
        address pa = makeAddr("pa_ctrl");
        address validImpl = address(new InstitutionalLoanVault());
        address validAdapter = makeAddr("adapter");
        address validOracle = makeAddr("oracle");
        address validPSR = makeAddr("psr");
        address validComp = makeAddr("comp");
        address validToken = makeAddr("token");
        address validAcm = address(acm);

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                InstitutionalVaultController.initialize,
                (address(0), validAdapter, validOracle, validPSR, validComp, validToken, validAcm)
            )
        );

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                InstitutionalVaultController.initialize,
                (validImpl, address(0), validOracle, validPSR, validComp, validToken, validAcm)
            )
        );

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                InstitutionalVaultController.initialize,
                (validImpl, validAdapter, address(0), validPSR, validComp, validToken, validAcm)
            )
        );

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                InstitutionalVaultController.initialize,
                (validImpl, validAdapter, validOracle, address(0), validComp, validToken, validAcm)
            )
        );

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                InstitutionalVaultController.initialize,
                (validImpl, validAdapter, validOracle, validPSR, address(0), validToken, validAcm)
            )
        );

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                InstitutionalVaultController.initialize,
                (validImpl, validAdapter, validOracle, validPSR, validComp, address(0), validAcm)
            )
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5B — Vault Deployment
    // ──────────────────────────────────────────────────────────────────────

    function test_createVault_basic() external {
        address vaultAddr = _createVault();

        assertEq(controller.allVaultsLength(), 1);
        assertEq(controller.allVaults(0), vaultAddr);
        assertTrue(controller.isRegistered(vaultAddr));
    }

    function test_createVault_emitsVaultCreated() external {
        address predicted = controller.predictVaultAddress(institution);

        vm.expectEmit(true, true, false, false);
        emit InstitutionalVaultController.VaultCreated(predicted, institution);

        controller.createVault(_buildVaultConfig(), _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_setsPositionToken() external {
        address vaultAddr = _createVault();
        InstitutionalLoanVault v = InstitutionalLoanVault(vaultAddr);

        uint256 tokenId = v.institutionalConfig().positionTokenId;
        assertGt(tokenId, 0);
        assertEq(posToken.ownerOf(tokenId), institution);
        assertEq(posToken.tokenIdToVault(tokenId), vaultAddr);
    }

    function test_createVault_incrementsNonce() external {
        address vault1 = _createVault();
        address vault2 = _createVault();

        assertFalse(vault1 == vault2);
        assertEq(controller.institutionNonce(institution), 2);
        assertEq(controller.allVaultsLength(), 2);
    }

    // VaultConfig boundaries

    function test_createVault_revertsIfOpenDurationZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.openDuration = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfLockDurationZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.lockDuration = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfSettlementWindowZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.settlementWindow = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfMaxBorrowCapZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.maxBorrowCap = 0;
        cfg.minBorrowCap = 0; // avoid min > max triggering first

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfMinBorrowCapZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.minBorrowCap = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfMinCapExceedsMax() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.minBorrowCap = cfg.maxBorrowCap + 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_minCapEqualsMax_succeeds() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.minBorrowCap = cfg.maxBorrowCap;

        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfFixedAPYZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.fixedAPY = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfSupplyAssetZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.supplyAsset = IERC20(address(0));

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfReserveFactorExceedsMantissa() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.reserveFactor = MANTISSA_ONE + 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_reserveFactorAtMantissa_succeeds() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.reserveFactor = MANTISSA_ONE;

        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    // InstitutionalConfig boundaries

    function test_createVault_revertsIfCollateralAssetZero() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.collateralAsset = IERC20(address(0));

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    function test_createVault_revertsIfSupplyEqualsCollateral() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.collateralAsset = IERC20(address(supply));

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    function test_createVault_revertsIfInstitutionOperatorZero() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.institutionOperator = address(0);

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    function test_createVault_revertsIfIdealCollateralZero() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.idealCollateralAmount = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    function test_createVault_revertsIfMarginRateZero() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.marginRate = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    function test_createVault_revertsIfMarginRateExceedsMantissa() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.marginRate = MANTISSA_ONE + 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    function test_createVault_marginRateAtMantissa_succeeds() external {
        InstitutionalConfig memory instCfg = _buildInstConfig();
        instCfg.marginRate = MANTISSA_ONE;

        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    // RiskConfig boundaries

    function test_createVault_revertsIfLTZero() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationThreshold = 0;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_revertsIfLTExceedsMantissa() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationThreshold = MANTISSA_ONE + 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_ltAtMantissa_succeeds() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationThreshold = MANTISSA_ONE;

        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_revertsIfLIAtMantissa() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationIncentive = MANTISSA_ONE;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_revertsIfLIBelowMantissa() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationIncentive = MANTISSA_ONE - 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_liJustAboveMantissa_succeeds() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationIncentive = MANTISSA_ONE + 1;

        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_revertsIfLatePenaltyAtMantissa() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.latePenaltyRate = MANTISSA_ONE;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_revertsIfLatePenaltyBelowMantissa() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.latePenaltyRate = MANTISSA_ONE - 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_latePenaltyJustAboveMantissa_succeeds() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.latePenaltyRate = MANTISSA_ONE + 1;

        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_allMinimumValidParams_succeeds() external {
        VaultConfig memory cfg = VaultConfig({
            supplyAsset: IERC20(address(supply)),
            fixedAPY: 1,
            reserveFactor: 0,
            minBorrowCap: 1,
            maxBorrowCap: 1,
            minSupplierDeposit: 0,
            openDuration: 1,
            lockDuration: 1,
            settlementWindow: 1
        });

        InstitutionalConfig memory instCfg = InstitutionalConfig({
            collateralAsset: IERC20(address(collateral)),
            idealCollateralAmount: 1,
            marginRate: 1,
            institutionOperator: institution,
            positionTokenId: 0
        });

        RiskConfig memory rc = RiskConfig({
            liquidationThreshold: 1, liquidationIncentive: MANTISSA_ONE + 1, latePenaltyRate: MANTISSA_ONE + 1
        });

        controller.createVault(cfg, instCfg, rc);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5C — Vault Lifecycle Proxied Calls
    // ──────────────────────────────────────────────────────────────────────

    function test_openVault_ACMGated() external {
        _createVault();
        _openVault();

        assertEq(uint8(vault.state()), uint8(VaultState.Fundraising));
    }

    function test_openVault_revertsIfVaultNotRegistered() external {
        vm.expectRevert(InstitutionalVaultController.VaultNotRegistered.selector);
        controller.openVault(makeAddr("unknownVault"));
    }

    function test_openVault_revertsIfNotACM() external {
        _createVault();

        collateral.mint(institution, MARGIN_AMOUNT);
        vm.startPrank(institution);
        collateral.approve(address(vault), MARGIN_AMOUNT);
        vault.depositCollateral(MARGIN_AMOUNT);
        vm.stopPrank();

        vm.prank(lender1);
        vm.expectRevert();
        controller.openVault(address(vault));
    }

    function test_closeVault_ACMGated() external {
        _createVault();
        _openVault();
        _lockVault();
        _settleVault();

        vm.expectEmit(false, false, false, true);
        emit BaseVault.VaultClosed(VaultState.Matured);

        controller.closeVault(address(vault));

        assertFalse(vault.runtime().isActive);
    }

    function test_partialPauseVault() external {
        _createVault();
        controller.partialPauseVault(address(vault));

        assertEq(uint8(vault.pauseLevel()), uint8(PauseLevel.Partial));
    }

    function test_completePauseVault() external {
        _createVault();
        controller.completePauseVault(address(vault));

        assertEq(uint8(vault.pauseLevel()), uint8(PauseLevel.Complete));
    }

    function test_unpauseVault() external {
        _createVault();
        controller.partialPauseVault(address(vault));
        controller.unpauseVault(address(vault));

        assertEq(uint8(vault.pauseLevel()), uint8(PauseLevel.Unpaused));
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5D — Risk Parameter Proxied Calls
    // ──────────────────────────────────────────────────────────────────────

    function test_setLiquidationThreshold_proxied() external {
        _createVault();
        uint256 newLT = 0.8e18;

        vm.expectEmit(true, false, false, true);
        emit InstitutionalVaultController.LiquidationThresholdUpdated(address(vault), newLT);

        controller.setLiquidationThreshold(address(vault), newLT);

        assertEq(vault.riskConfig().liquidationThreshold, newLT);
    }

    function test_setLiquidationIncentive_proxied() external {
        _createVault();
        uint256 newLI = 1.15e18;

        vm.expectEmit(true, false, false, true);
        emit InstitutionalVaultController.LiquidationIncentiveUpdated(address(vault), newLI);

        controller.setLiquidationIncentive(address(vault), newLI);

        assertEq(vault.riskConfig().liquidationIncentive, newLI);
    }

    function test_setLatePenaltyRate_proxied() external {
        _createVault();
        uint256 newRate = 1.2e18;

        vm.expectEmit(true, false, false, true);
        emit InstitutionalVaultController.LatePenaltyRateUpdated(address(vault), newRate);

        controller.setLatePenaltyRate(address(vault), newRate);

        assertEq(vault.riskConfig().latePenaltyRate, newRate);
    }

    function test_riskSetters_revertsIfVaultNotRegistered() external {
        address unknown = makeAddr("unknownVault");

        vm.expectRevert(InstitutionalVaultController.VaultNotRegistered.selector);
        controller.setLiquidationThreshold(unknown, 0.8e18);

        vm.expectRevert(InstitutionalVaultController.VaultNotRegistered.selector);
        controller.setLiquidationIncentive(unknown, 1.15e18);

        vm.expectRevert(InstitutionalVaultController.VaultNotRegistered.selector);
        controller.setLatePenaltyRate(unknown, 1.2e18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5E — System Config Setters
    // ──────────────────────────────────────────────────────────────────────

    function test_setOracle_ACMGated() external {
        address newOracle = makeAddr("newOracle");

        vm.expectEmit(true, true, false, false);
        emit InstitutionalVaultController.OracleUpdated(address(oracle), newOracle);

        controller.setOracle(newOracle);

        assertEq(controller.oracle(), newOracle);
    }

    function test_setPSR_ACMGated() external {
        address newPSR = makeAddr("newPSR");

        vm.expectEmit(true, true, false, false);
        emit InstitutionalVaultController.ProtocolShareReserveUpdated(address(psr), newPSR);

        controller.setProtocolShareReserve(newPSR);

        assertEq(controller.protocolShareReserve(), newPSR);
    }

    function test_setComptroller_ACMGated() external {
        address newComp = makeAddr("newComptroller");

        vm.expectEmit(true, true, false, false);
        emit InstitutionalVaultController.ComptrollerUpdated(comptrollerAddr, newComp);

        controller.setComptroller(newComp);

        assertEq(controller.comptroller(), newComp);
    }

    function test_setVaultImplementation_ACMGated() external {
        address oldImpl = controller.vaultImplementation();
        address newImpl = makeAddr("newImpl");

        vm.expectEmit(true, true, false, false);
        emit InstitutionalVaultController.VaultImplementationUpdated(oldImpl, newImpl);

        controller.setVaultImplementation(newImpl);

        assertEq(controller.vaultImplementation(), newImpl);
    }

    function test_setLiquidationAdapter_ACMGated() external {
        address oldAdapter = controller.liquidationAdapter();
        address newAdapter = makeAddr("newAdapter");

        vm.expectEmit(true, true, false, false);
        emit InstitutionalVaultController.LiquidationAdapterUpdated(oldAdapter, newAdapter);

        controller.setLiquidationAdapter(newAdapter);

        assertEq(controller.liquidationAdapter(), newAdapter);
    }

    function test_setters_revertsIfZeroAddress() external {
        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        controller.setOracle(address(0));

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        controller.setProtocolShareReserve(address(0));

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        controller.setComptroller(address(0));

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        controller.setVaultImplementation(address(0));

        vm.expectRevert(InstitutionalVaultController.InvalidAddress.selector);
        controller.setLiquidationAdapter(address(0));
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5F — Registry View Functions
    // ──────────────────────────────────────────────────────────────────────

    function test_getAllVaults() external {
        address vault1 = _createVault();
        address vault2 = _createVault();

        assertEq(controller.allVaultsLength(), 2);
        assertEq(controller.allVaults(0), vault1);
        assertEq(controller.allVaults(1), vault2);
    }

    function test_getAggregatedVaultStates() external {
        address vaultAddr = _createVault();

        VaultStateInfo[] memory infos = controller.getAggregatedVaultStates();

        assertEq(infos.length, 1);
        assertEq(infos[0].vault, vaultAddr);
        assertEq(uint8(infos[0].state), uint8(VaultState.WaitingForMargin));
        assertEq(infos[0].institutionOperator, institution);
        assertEq(infos[0].totalRaised, 0);
        assertEq(infos[0].outstandingDebt, 0);
    }

    function test_isRegistered_trueForDeployed() external {
        address vaultAddr = _createVault();
        assertTrue(controller.isRegistered(vaultAddr));
    }

    function test_isRegistered_falseForUnknown() external {
        assertFalse(controller.isRegistered(makeAddr("unknownVault")));
    }

    function test_approveAndRevokePositionTransfer() external {
        address vaultAddr = _createVault();
        InstitutionalLoanVault v = InstitutionalLoanVault(vaultAddr);
        uint256 tokenId = v.institutionalConfig().positionTokenId;

        // Approve transfer via controller (ACM-gated).
        controller.approvePositionTransfer(vaultAddr);
        assertTrue(posToken.transferApproved(tokenId));

        // Revoke approval.
        controller.revokePositionTransfer(vaultAddr);
        assertFalse(posToken.transferApproved(tokenId));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal helper — reads current vaultImpl from controller (needed for assertions).
    // ──────────────────────────────────────────────────────────────────────

    function _getVaultImpl() internal view returns (address) {
        return controller.vaultImplementation();
    }
}
