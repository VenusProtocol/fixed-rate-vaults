// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { VaultConfig } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig } from "../../src/interfaces/IInstitutionalVaultTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Tests every boundary condition in _validateVaultConfig to ensure
///         degenerate vault configurations are rejected at creation time.
contract InitBoundaryTest is VaultTestBase {
    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
    }

    // ──────────────────────────────────────────────────────────────────────
    // VaultConfig boundaries
    // ──────────────────────────────────────────────────────────────────────

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
        cfg.minBorrowCap = 0; // also set min to 0 to avoid min > max check triggering first

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_revertsIfMinBorrowCapZero() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.minBorrowCap = 0;

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
        cfg.reserveFactor = MANTISSA_ONE; // 100% — extreme but valid

        // Should not revert (reserveFactor <= MANTISSA_ONE passes)
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

    function test_createVault_revertsIfMinCapExceedsMax() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.minBorrowCap = cfg.maxBorrowCap + 1;

        vm.expectRevert(InstitutionalVaultController.InvalidConfig.selector);
        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    function test_createVault_minCapEqualsMax_succeeds() external {
        VaultConfig memory cfg = _buildVaultConfig();
        cfg.minBorrowCap = cfg.maxBorrowCap; // Equal is valid

        controller.createVault(cfg, _buildInstConfig(), _buildRiskConfig());
    }

    // ──────────────────────────────────────────────────────────────────────
    // InstitutionalConfig boundaries
    // ──────────────────────────────────────────────────────────────────────

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
        instCfg.marginRate = MANTISSA_ONE; // 100% margin — extreme but valid

        controller.createVault(_buildVaultConfig(), instCfg, _buildRiskConfig());
    }

    // ──────────────────────────────────────────────────────────────────────
    // RiskConfig boundaries
    // ──────────────────────────────────────────────────────────────────────

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
        rc.liquidationThreshold = MANTISSA_ONE; // 100% — valid boundary

        controller.createVault(_buildVaultConfig(), _buildInstConfig(), rc);
    }

    function test_createVault_revertsIfLIAtMantissa() external {
        RiskConfig memory rc = _buildRiskConfig();
        rc.liquidationIncentive = MANTISSA_ONE; // must be > 1e18, not == 1e18

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
        rc.latePenaltyRate = MANTISSA_ONE; // must be > 1e18

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

    // ──────────────────────────────────────────────────────────────────────
    // Combined edge case: all parameters at minimum valid values
    // ──────────────────────────────────────────────────────────────────────

    function test_createVault_allMinimumValidParams_succeeds() external {
        VaultConfig memory cfg = VaultConfig({
            supplyAsset: IERC20(address(supply)),
            fixedAPY: 1, // 0.01%
            reserveFactor: 0, // no protocol fee
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
            marginRate: 1, // smallest possible non-zero
            institutionOperator: institution,
            positionTokenId: 0
        });

        RiskConfig memory rc = RiskConfig({
            liquidationThreshold: 1, // smallest possible non-zero
            liquidationIncentive: MANTISSA_ONE + 1, // smallest valid
            latePenaltyRate: MANTISSA_ONE + 1 // smallest valid
        });

        controller.createVault(cfg, instCfg, rc);
    }
}
