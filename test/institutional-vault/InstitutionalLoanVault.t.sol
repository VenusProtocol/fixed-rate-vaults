// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    AccessControlManager
} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlManager.sol";
import { ChainlinkOracle } from "@venusprotocol/oracle/contracts/oracles/ChainlinkOracle.sol";

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { LiquidationAdapter } from "../../src/institutional-vault/LiquidationAdapter.sol";
import { InstitutionPositionToken } from "../../src/institutional-vault/InstitutionPositionToken.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { VaultConfig, VaultRuntime, VaultState, PauseLevel } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig, LiquidationType } from "../../src/interfaces/IInstitutionalVaultTypes.sol";
import { IInstitutionPositionToken } from "../../src/interfaces/IInstitutionPositionToken.sol";

import { MockPSR } from "./mocks/MockPSR.sol";

contract InstitutionalLoanVaultTest is VaultTestBase {
    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
        _createVault();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3A — Initialization & Open
    // ──────────────────────────────────────────────────────────────────────

    function test_initialize_setsAllConfig() external {
        VaultConfig memory cfg = vault.config();
        InstitutionalConfig memory instCfg = vault.institutionalConfig();
        RiskConfig memory rc = vault.riskConfig();

        assertEq(address(cfg.supplyAsset), address(supply));
        assertEq(cfg.fixedAPY, FIXED_APY);
        assertEq(cfg.reserveFactor, RESERVE_FACTOR);
        assertEq(cfg.minBorrowCap, MIN_BORROW_CAP);
        assertEq(cfg.maxBorrowCap, MAX_BORROW_CAP);
        assertEq(cfg.openDuration, OPEN_DURATION);
        assertEq(cfg.lockDuration, LOCK_DURATION);
        assertEq(cfg.settlementWindow, SETTLEMENT_WINDOW);

        assertEq(address(instCfg.collateralAsset), address(collateral));
        assertEq(instCfg.idealCollateralAmount, IDEAL_COLLATERAL_AMOUNT);
        assertEq(instCfg.marginRate, MARGIN_RATE);
        assertEq(instCfg.institutionOperator, institution);
        assertGt(instCfg.positionTokenId, 0); // assigned by controller

        assertEq(rc.liquidationThreshold, LT);
        assertEq(rc.liquidationIncentive, LI);
        assertEq(rc.latePenaltyRate, LATE_PENALTY_RATE);

        assertEq(uint8(vault.state()), uint8(VaultState.WaitingForMargin));
        assertEq(vault.vaultController(), address(controller));
    }

    function test_initialize_revertsIfCalledTwice() external {
        VaultConfig memory cfg = _buildVaultConfig();
        InstitutionalConfig memory instCfg = _buildInstConfig();
        RiskConfig memory rc = _buildRiskConfig();

        vm.expectRevert("Initializable: contract is already initialized");
        vault.initialize(cfg, instCfg, rc, IInstitutionPositionToken(address(posToken)), address(adapter));
    }

    function test_openVault_byController() external {
        _openVault();

        assertEq(uint8(vault.state()), uint8(VaultState.Fundraising));
        assertTrue(vault.runtime().isActive);
        assertGt(vault.runtime().openEndTime, 0);
        assertGt(vault.runtime().lockEndTime, vault.runtime().openEndTime);
        assertGt(vault.runtime().settlementDeadline, vault.runtime().lockEndTime);
    }

    function test_openVault_revertsIfNotMarginDeposited() external {
        // Vault is in WaitingForMargin, not MarginDeposited.
        vm.expectRevert(BaseVault.InvalidState.selector);
        controller.openVault(address(vault));
    }

    function test_openVault_revertsIfNotController() external {
        // depositCollateral to reach MarginDeposited first.
        collateral.mint(institution, MARGIN_AMOUNT);
        vm.startPrank(institution);
        collateral.approve(address(vault), MARGIN_AMOUNT);
        vault.depositCollateral(MARGIN_AMOUNT);
        vm.stopPrank();

        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.openVault();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3B — Collateral Management
    // ──────────────────────────────────────────────────────────────────────

    function test_depositCollateral_inWaitingForMargin_reachesMargin() external {
        collateral.mint(institution, MARGIN_AMOUNT);

        vm.startPrank(institution);
        collateral.approve(address(vault), MARGIN_AMOUNT);

        vm.expectEmit(false, false, false, true);
        emit InstitutionalLoanVault.CollateralDeposited(MARGIN_AMOUNT, MARGIN_AMOUNT);
        vm.expectEmit(true, true, false, false);
        emit BaseVault.StateTransition(VaultState.WaitingForMargin, VaultState.MarginDeposited, block.timestamp);

        vault.depositCollateral(MARGIN_AMOUNT);
        vm.stopPrank();

        assertEq(uint8(vault.state()), uint8(VaultState.MarginDeposited));
        assertEq(vault.institutionalRuntime().totalCollateralDeposited, MARGIN_AMOUNT);
    }

    function test_depositCollateral_inWaitingForMargin_belowMargin_reverts() external {
        uint256 insufficient = MARGIN_AMOUNT - 1;
        collateral.mint(institution, insufficient);

        vm.startPrank(institution);
        collateral.approve(address(vault), insufficient);
        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vault.depositCollateral(insufficient);
        vm.stopPrank();
    }

    function test_depositCollateral_inFundraising() external {
        _openVault();

        uint256 extraCollateral = 100_000e18;
        collateral.mint(institution, extraCollateral);
        vm.startPrank(institution);
        collateral.approve(address(vault), extraCollateral);
        vault.depositCollateral(extraCollateral);
        vm.stopPrank();

        uint256 expected = MARGIN_AMOUNT + extraCollateral;
        assertEq(vault.institutionalRuntime().totalCollateralDeposited, expected);
    }

    function test_depositCollateral_inLock() external {
        _openVault();
        _lockVault();

        uint256 topUp = 50_000e18;
        uint256 expectedTotal = IDEAL_COLLATERAL_AMOUNT + topUp;

        collateral.mint(institution, topUp);
        vm.startPrank(institution);
        collateral.approve(address(vault), topUp);

        vm.expectEmit(false, false, false, true);
        emit InstitutionalLoanVault.CollateralDeposited(topUp, expectedTotal);

        vault.depositCollateral(topUp);
        vm.stopPrank();

        assertEq(vault.institutionalRuntime().totalCollateralDeposited, expectedTotal);
    }

    function test_depositCollateral_revertsIfWrongState() external {
        _openVault();
        _lockVault();

        // Advance to PendingSettlement.
        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState();

        collateral.mint(institution, 100e18);
        vm.startPrank(institution);
        collateral.approve(address(vault), 100e18);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.depositCollateral(100e18);
        vm.stopPrank();
    }

    function test_depositCollateral_revertsIfNotPositionHolder() external {
        collateral.mint(lender1, MARGIN_AMOUNT);
        vm.startPrank(lender1);
        collateral.approve(address(vault), MARGIN_AMOUNT);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.depositCollateral(MARGIN_AMOUNT);
        vm.stopPrank();
    }

    /// @dev Sending collateral tokens directly to the vault must not affect totalCollateralDeposited.
    ///      Collateral accounting uses a counter incremented only by depositCollateral().
    ///      A direct transfer cannot inflate collateral, improve health factor, or rescue a vault
    ///      from liquidation — the tokens sit in the vault untracked by the protocol.
    function test_directCollateralTransfer_doesNotAffectAccounting() external {
        _openVault();
        _lockVault();

        uint256 collateralBefore = vault.institutionalRuntime().totalCollateralDeposited;

        // Donate collateral directly — not via depositCollateral().
        address attacker = makeAddr("attacker");
        uint256 donation = 500_000e18;
        collateral.mint(attacker, donation);
        vm.prank(attacker);
        collateral.transfer(address(vault), donation);

        // Counter must be unchanged — donation is invisible to the protocol.
        assertEq(vault.institutionalRuntime().totalCollateralDeposited, collateralBefore);
        // The tokens are physically in the vault but not tracked.
        assertEq(collateral.balanceOf(address(vault)), collateralBefore + donation);
    }

    function test_withdrawCollateral_inLock_healthy() external {
        _openVault();

        // Raise only MIN_BORROW_CAP so minimumCollateralRequired = 750k (not full 1.5M).
        // This leaves a 750k buffer that can be withdrawn while remaining healthy.
        supply.mint(lender1, MIN_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MIN_BORROW_CAP);
        vault.deposit(MIN_BORROW_CAP, lender1);
        vm.stopPrank();

        // Institution tops up to full ideal collateral.
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState(); // → Lock

        // Institution claims funds so there is actual debt to check LT against.
        vm.prank(institution);
        vault.claimRaisedFunds();

        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        uint256 minRequired = vault.institutionalRuntime().minimumCollateralRequired;
        uint256 withdrawable = totalCollateral - minRequired; // = 750k

        // Withdraw exactly the withdrawable buffer — should stay healthy at $1.
        vm.expectEmit(true, false, false, true);
        emit InstitutionalLoanVault.CollateralReleased(institution, withdrawable);

        vm.prank(institution);
        vault.withdrawCollateral(withdrawable);

        assertEq(vault.institutionalRuntime().totalCollateralDeposited, minRequired);
        assertEq(collateral.balanceOf(institution), withdrawable);
    }

    function test_withdrawCollateral_inLock_breachesLT_reverts() external {
        _openVault();

        // Raise only MIN_BORROW_CAP for a 750k buffer above minimumCollateralRequired.
        supply.mint(lender1, MIN_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MIN_BORROW_CAP);
        vault.deposit(MIN_BORROW_CAP, lender1);
        vm.stopPrank();

        // Institution tops up to full ideal collateral.
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState(); // → Lock

        vm.prank(institution);
        vault.claimRaisedFunds();

        // Drop collateral price to $0.90.
        // After withdrawing the 750k buffer: remaining = 750k * $0.90 = $675k.
        // debt (principal + interest) = 500k + 40k = 540k.
        // LT cap = 675k * 0.75 = 506.25k < 540k → breach.
        _setPrice(address(collateral), 0.9e18);

        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        uint256 minRequired = vault.institutionalRuntime().minimumCollateralRequired;
        uint256 buffer = totalCollateral - minRequired;

        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.WithdrawalWouldBreachLT.selector);
        vault.withdrawCollateral(buffer);
    }

    function test_withdrawCollateral_inLock_breachesFloor_reverts() external {
        _openVault();
        _lockVault();

        // No debt (funds not claimed), but floor check still applies.
        uint256 minRequired = vault.institutionalRuntime().minimumCollateralRequired;
        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        // Try to withdraw all (would leave less than floor).
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(totalCollateral);
    }

    function test_withdrawCollateral_inMatured() external {
        _openVault();
        _lockVault();
        _settleVault();

        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;

        vm.expectEmit(true, false, false, true);
        emit InstitutionalLoanVault.CollateralReleased(institution, totalCollateral);

        vm.prank(institution);
        vault.withdrawCollateral(totalCollateral);

        assertEq(collateral.balanceOf(institution), totalCollateral);
        assertEq(vault.institutionalRuntime().totalCollateralDeposited, 0);
    }

    function test_withdrawCollateral_inFailed_noDefault() external {
        // Insufficient raise → Failed (no confiscation).
        _openVault();
        // Institution doesn't fully fund collateral (only margin), lenders below minCap.
        uint256 smallDeposit = 100_000e18;
        supply.mint(lender1, smallDeposit);
        vm.startPrank(lender1);
        supply.approve(address(vault), smallDeposit);
        vault.deposit(smallDeposit, lender1);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState(); // Failed (totalRaised < minCap)

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertFalse(vault.institutionalRuntime().institutionDefaulted);

        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;

        vm.expectEmit(true, false, false, true);
        emit InstitutionalLoanVault.CollateralReleased(institution, totalCollateral);

        vm.prank(institution);
        vault.withdrawCollateral(totalCollateral);

        assertEq(collateral.balanceOf(institution), totalCollateral);
    }

    function test_withdrawCollateral_inFailed_withDefault() external {
        // Institution default scenario: totalRaised >= minCap but collateral < ideal.
        // Deploy a new vault where institution deposits only the margin (not full ideal).
        _openVault();

        // Lenders deposit above minCap.
        supply.mint(lender1, MIN_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MIN_BORROW_CAP);
        vault.deposit(MIN_BORROW_CAP, lender1);
        vm.stopPrank();

        // Institution does NOT deposit remaining collateral (only margin deposited).
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState(); // Failed: institution default

        assertTrue(vault.institutionalRuntime().institutionDefaulted);

        uint256 confiscated = vault.institutionalRuntime().confiscatedMarginRemaining;
        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        uint256 availableToInstitution = totalCollateral - confiscated;

        vm.prank(institution);
        vault.withdrawCollateral(availableToInstitution);

        assertEq(collateral.balanceOf(institution), availableToInstitution);

        // Institution cannot withdraw the confiscated portion.
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1);
    }

    function test_withdrawCollateral_revertsIfWrongState() external {
        _openVault();
        // In Fundraising state.
        collateral.mint(institution, 1e18);
        vm.startPrank(institution);
        collateral.approve(address(vault), 1e18);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.withdrawCollateral(1e18);
        vm.stopPrank();
    }

    function test_withdrawCollateral_revertsIfNotPositionHolder() external {
        _openVault();
        _lockVault();

        vm.prank(lender1);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.withdrawCollateral(1e18);
    }

    function test_withdrawCollateral_revertsIfOverAmount() external {
        _openVault();
        _lockVault();
        _settleVault();

        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vault.withdrawCollateral(totalCollateral + 1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3C — State Machine (Institution-Specific)
    // ──────────────────────────────────────────────────────────────────────

    function test_fundraisingToLock_fullCollateral() external {
        _openVault();
        _lockVault();

        VaultRuntime memory rt = vault.runtime();
        assertEq(uint8(rt.state), uint8(VaultState.Lock));

        // minimumCollateralRequired = idealCollateral * totalRaised / maxBorrowCap.
        uint256 expectedMin = (IDEAL_COLLATERAL_AMOUNT * MAX_BORROW_CAP) / MAX_BORROW_CAP;
        assertEq(vault.institutionalRuntime().minimumCollateralRequired, expectedMin);
        assertEq(rt.totalDebt, _computeInterest(MAX_BORROW_CAP));
    }

    function test_fundraisingToFailed_institutionDefault() external {
        _openVault();

        // Lenders deposit above minCap; institution does NOT complete collateral.
        supply.mint(lender1, MIN_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MIN_BORROW_CAP);
        vault.deposit(MIN_BORROW_CAP, lender1);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);

        vm.expectEmit(false, false, false, true);
        emit BaseVault.VaultFailed(MIN_BORROW_CAP, MIN_BORROW_CAP);
        vm.expectEmit(false, false, false, true);
        emit InstitutionalLoanVault.MarginConfiscated(MARGIN_AMOUNT);

        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertTrue(vault.institutionalRuntime().institutionDefaulted);
        assertEq(vault.institutionalRuntime().confiscatedMarginRemaining, MARGIN_AMOUNT);
    }

    function test_fundraisingToFailed_insufficientRaise() external {
        _openVault();

        // Deposit below minCap.
        uint256 deposit = MIN_BORROW_CAP - 1;
        supply.mint(lender1, deposit);
        vm.startPrank(lender1);
        supply.approve(address(vault), deposit);
        vault.deposit(deposit, lender1);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertFalse(vault.institutionalRuntime().institutionDefaulted);
        assertEq(vault.institutionalRuntime().confiscatedMarginRemaining, 0);
    }

    function test_failed_institutionDefault_marginCompensation() external {
        _openVault();

        supply.mint(lender1, MIN_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MIN_BORROW_CAP);
        vault.deposit(MIN_BORROW_CAP, lender1);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState(); // Failed with institution default

        uint256 confiscated = vault.institutionalRuntime().confiscatedMarginRemaining;
        uint256 totalShares = vault.totalSupply();
        uint256 lenderShares = vault.balanceOf(lender1);

        // lender1 holds all shares → should receive all of confiscated margin.
        uint256 expectedCompensation = (confiscated * lenderShares) / totalShares;
        uint256 expectedSupplyRefund = vault.previewRedeem(lenderShares);

        vm.prank(lender1);
        vault.redeem(lenderShares, lender1, lender1);

        assertEq(collateral.balanceOf(lender1), expectedCompensation);
        assertEq(supply.balanceOf(lender1), expectedSupplyRefund);
        // Lender gets their full principal back in supply + the full confiscated margin on top
        // (lender1 holds 100% of shares so receives 100% of confiscated margin == MARGIN_AMOUNT).
        assertEq(supply.balanceOf(lender1), MIN_BORROW_CAP);
        assertEq(collateral.balanceOf(lender1), MARGIN_AMOUNT);
    }

    function test_failed_institutionDefault_multipleWithdrawals() external {
        _openVault();

        // Two lenders deposit equal amounts.
        uint256 each = MIN_BORROW_CAP / 2;
        supply.mint(lender1, each);
        supply.mint(lender2, each);

        vm.startPrank(lender1);
        supply.approve(address(vault), each);
        vault.deposit(each, lender1);
        vm.stopPrank();

        vm.startPrank(lender2);
        supply.approve(address(vault), each);
        vault.deposit(each, lender2);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        uint256 confiscated = vault.institutionalRuntime().confiscatedMarginRemaining;
        uint256 shares1 = vault.balanceOf(lender1);
        uint256 shares2 = vault.balanceOf(lender2);
        uint256 totalShares = vault.totalSupply();

        uint256 expectedComp1 = (confiscated * shares1) / totalShares;

        vm.prank(lender1);
        vault.redeem(shares1, lender1, lender1);

        assertEq(collateral.balanceOf(lender1), expectedComp1);

        // Remaining confiscated for lender2.
        uint256 remainingConfiscated = vault.institutionalRuntime().confiscatedMarginRemaining;
        uint256 totalSharesAfter = vault.totalSupply();
        uint256 expectedComp2 = (remainingConfiscated * shares2) / totalSharesAfter;

        vm.prank(lender2);
        vault.redeem(shares2, lender2, lender2);

        assertEq(collateral.balanceOf(lender2), expectedComp2);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3D — Repay
    // ──────────────────────────────────────────────────────────────────────

    function test_repay_inLock() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        uint256 debtBefore = vault.outstandingDebt();
        uint256 partialRepay = 10_000e18;

        supply.mint(institution, partialRepay);
        vm.startPrank(institution);
        supply.approve(address(vault), partialRepay);

        vm.expectEmit(false, false, false, true);
        emit BaseVault.Repaid(partialRepay, debtBefore - partialRepay);

        vault.repay(partialRepay);
        vm.stopPrank();

        assertEq(vault.outstandingDebt(), debtBefore - partialRepay);
    }

    function test_repay_clampsToDebt() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // claimRaisedFunds gives institution the raised principal, so they already hold
        // MAX_BORROW_CAP supply tokens before we mint extra for the overpay test.
        uint256 balanceBefore = supply.balanceOf(institution);

        uint256 debt = vault.outstandingDebt();
        uint256 overpay = debt + 1_000_000e18;

        supply.mint(institution, overpay);
        vm.startPrank(institution);
        supply.approve(address(vault), overpay);

        // Repay should emit with the clamped amount (debt), not the overpay.
        vm.expectEmit(false, false, false, true);
        emit BaseVault.Repaid(debt, 0);

        vault.repay(overpay);
        vm.stopPrank();

        // Only debt amount pulled; over-allowance not consumed.
        assertEq(vault.outstandingDebt(), 0);
        assertEq(supply.balanceOf(institution), balanceBefore + overpay - debt);
    }

    function test_repay_fullDebt_inPendingSettlement() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState(); // PendingSettlement

        uint256 debt = vault.outstandingDebt();
        supply.mint(institution, debt);
        vm.startPrank(institution);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    function test_repay_revertsIfZero() external {
        _openVault();
        _lockVault();

        vm.expectRevert(BaseVault.ZeroRepayAmount.selector);
        vault.repay(0);
    }

    function test_repay_revertsIfNoDebt() external {
        _openVault();
        _lockVault();
        // Debt at Lock is interest-only and non-zero (claimRaisedFunds not called).
        // To get NoOutstandingDebt, we need to repay everything first.
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt); // pays off interest

        // Now debt is zero.
        vm.expectRevert(BaseVault.NoOutstandingDebt.selector);
        vault.repay(1);
    }

    function test_repay_revertsIfWrongState() external {
        _openVault();
        // In Fundraising state.
        supply.mint(address(this), 1);
        supply.approve(address(vault), 1);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.repay(1);
    }

    function test_repay_revertsIfCompletelyPaused() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        controller.completePauseVault(address(vault));

        supply.mint(address(this), 1);
        supply.approve(address(vault), 1);
        vm.expectRevert(BaseVault.CompletelyPaused.selector);
        vault.repay(1);
    }

    function test_repay_allowedDuringPartialPause() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        controller.partialPauseVault(address(vault));

        uint256 partialRepay = 1000e18;
        supply.mint(address(this), partialRepay);
        supply.approve(address(vault), partialRepay);
        vault.repay(partialRepay); // must succeed
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3E — Liquidation (HF-based)
    // ──────────────────────────────────────────────────────────────────────

    function _setupLiquidatableVault() internal {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Whitelist liquidator on adapter.
        adapter.setLiquidatorWhitelist(liquidator, true);

        // Drop collateral price to create LT shortfall.
        // collateral value = IDEAL_COLLATERAL_AMOUNT * price / 1e18
        // debt value = totalDebt * supplyPrice / 1e18
        // We need: collateralUSD * LT < debtUSD
        // With debt = interest + principal = 80k + 1M = 1.08M, LT = 0.75
        // collateralUSD * 0.75 < 1.08M → collateralUSD < 1.44M
        // IDEAL_COLLATERAL_AMOUNT = 1.5M at $1 = $1.5M USD > $1.44M (healthy)
        // So drop collateral price to $0.90 per token:
        // collateralUSD = 1.5M * 0.9 = $1.35M, LT cap = $1.35M * 0.75 = $1.0125M
        // debt = $1.08M > $1.0125M → shortfall!
        _setPrice(address(collateral), 0.9e18);
    }

    function test_liquidate_basic() external {
        _setupLiquidatableVault();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE; // exactly at close factor limit

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);

        vm.expectEmit(true, false, false, false);
        emit InstitutionalLoanVault.LiquidationExecuted(address(adapter), repayAmt, 0);

        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        // Vault debt reduced.
        assertEq(vault.outstandingDebt(), debt - repayAmt);
        // Liquidator received collateral (amount checked via seize formula).
        assertGt(collateral.balanceOf(liquidator) + adapter.protocolShareAccrued(address(collateral)), 0);
    }

    function test_liquidate_seizeAmountCalc() external {
        _setupLiquidatableVault();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        // Compute expected seize: repayUSD * incentive / collateralPrice
        // supplyPrice = 1e18, collateralPrice = 0.9e18, incentive = 1.1e18
        uint256 supplyPrice = 1e18;
        uint256 collateralPrice = 0.9e18;
        uint256 repayValueUSD = (repayAmt * supplyPrice) / MANTISSA_ONE;
        uint256 seizeValueUSD = (repayValueUSD * LI) / MANTISSA_ONE;
        uint256 expectedSeize = (seizeValueUSD * MANTISSA_ONE) / collateralPrice;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 protocolShare = adapter.protocolShareAccrued(address(collateral));
        uint256 liquidatorShare = collateral.balanceOf(liquidator);
        assertEq(protocolShare + liquidatorShare, expectedSeize);
    }

    function test_liquidate_clampedToDebt() external {
        _setupLiquidatableVault();

        // Use 100% close factor so we can request 2× debt without ExceedsCloseFactor.
        // vault.liquidate clamps actualRepay = min(repayAmount, debt), then checks
        // actualRepay <= debt * closeFactor / MANTISSA_ONE. With closeFactor = MANTISSA_ONE that
        // becomes actualRepay <= debt, which is always true after clamping.
        adapter.setCloseFactor(MANTISSA_ONE);

        uint256 debt = vault.outstandingDebt();
        uint256 overpay = debt * 2;

        supply.mint(liquidator, overpay);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), overpay);
        adapter.liquidate(address(vault), overpay);
        vm.stopPrank();

        // Debt fully cleared (repayAmount clamped to debt inside vault.liquidate).
        assertEq(vault.outstandingDebt(), 0);
        // Adapter refunds the excess (overpay - debt = debt) back to liquidator.
        assertEq(supply.balanceOf(liquidator), debt);
    }

    function test_liquidate_revertsIfNotLiquidatable() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        adapter.setLiquidatorWhitelist(liquidator, true);
        // Collateral is at $1, vault is healthy.
        uint256 repayAmt = 10_000e18;
        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        vm.expectRevert(InstitutionalLoanVault.NotLiquidatable.selector);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();
    }

    function test_liquidate_revertsIfExceedsCloseFactor() external {
        _setupLiquidatableVault();

        uint256 debt = vault.outstandingDebt();
        uint256 overLimit = (debt * CLOSE_FACTOR) / MANTISSA_ONE + 1;

        supply.mint(liquidator, overLimit);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), overLimit);
        vm.expectRevert(InstitutionalLoanVault.ExceedsCloseFactor.selector);
        adapter.liquidate(address(vault), overLimit);
        vm.stopPrank();
    }

    function test_liquidate_revertsIfZeroAmount() external {
        _setupLiquidatableVault();

        // Must go through the adapter (vault.liquidate is onlyAdapter-gated).
        vm.startPrank(liquidator);
        vm.expectRevert(BaseVault.ZeroRepayAmount.selector);
        adapter.liquidate(address(vault), 0);
        vm.stopPrank();
    }

    function test_liquidate_revertsIfWrongState() external {
        _openVault(); // Fundraising state
        adapter.setLiquidatorWhitelist(liquidator, true);

        supply.mint(liquidator, 1e18);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), 1e18);
        vm.expectRevert(BaseVault.InvalidState.selector);
        adapter.liquidate(address(vault), 1e18);
        vm.stopPrank();
    }

    function test_liquidate_revertsIfNotAdapter() external {
        _setupLiquidatableVault();

        vm.prank(liquidator);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.liquidate(10_000e18);
    }

    function test_liquidate_revertsIfCompletelyPaused() external {
        _setupLiquidatableVault();

        controller.completePauseVault(address(vault));

        supply.mint(liquidator, 10_000e18);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), 10_000e18);
        vm.expectRevert(BaseVault.CompletelyPaused.selector);
        adapter.liquidate(address(vault), 10_000e18);
        vm.stopPrank();
    }

    function test_liquidate_allowedDuringPartialPause() external {
        _setupLiquidatableVault();
        controller.partialPauseVault(address(vault));

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt); // must succeed
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3F — Liquidation (Overdue)
    // ──────────────────────────────────────────────────────────────────────

    function _setupOverdueLiquidation() internal {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Advance past settlement deadline with debt still outstanding.
        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState(); // SettlementDeadlineExceeded

        adapter.setSettlerWhitelist(settler, true);
    }

    function test_liquidateOverdue_basic() external {
        _setupOverdueLiquidation();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(settler, repayAmt);
        vm.startPrank(settler);
        supply.approve(address(adapter), repayAmt);

        vm.expectEmit(true, false, false, false);
        emit InstitutionalLoanVault.OverdueLiquidationExecuted(address(adapter), repayAmt, 0);

        adapter.liquidateOverdueVault(address(vault), repayAmt);
        vm.stopPrank();

        assertEq(vault.outstandingDebt(), debt - repayAmt);
    }

    function test_liquidateOverdue_revertsIfNotSettlementDeadlineExceeded() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();
        // Still in Lock state.
        adapter.setSettlerWhitelist(settler, true);

        supply.mint(settler, 10_000e18);
        vm.startPrank(settler);
        supply.approve(address(adapter), 10_000e18);
        vm.expectRevert(InstitutionalLoanVault.InvalidStateForOverdueLiquidation.selector);
        adapter.liquidateOverdueVault(address(vault), 10_000e18);
        vm.stopPrank();
    }

    function test_liquidateOverdue_revertsIfNoDebt() external {
        _setupOverdueLiquidation();

        // Use 100% close factor so a single call can clear all debt.
        adapter.setCloseFactor(MANTISSA_ONE);

        uint256 debt = vault.outstandingDebt();
        supply.mint(settler, debt);
        vm.startPrank(settler);
        supply.approve(address(adapter), debt);
        adapter.liquidateOverdueVault(address(vault), debt); // clears all debt; state stays SDE
        vm.stopPrank();

        // On the next call, _checkAndAdvanceState fires first (debt == 0 → SDE → Matured),
        // so the state check fires before NoOutstandingDebt.
        supply.mint(settler, 1);
        vm.startPrank(settler);
        supply.approve(address(adapter), 1);
        vm.expectRevert(InstitutionalLoanVault.InvalidStateForOverdueLiquidation.selector);
        adapter.liquidateOverdueVault(address(vault), 1);
        vm.stopPrank();
    }

    function test_liquidateOverdue_revertsIfNotAdapter() external {
        _setupOverdueLiquidation();

        vm.prank(settler);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.liquidateOverdueVault(10_000e18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3G — Bad Debt Rescue
    // ──────────────────────────────────────────────────────────────────────

    function test_repayBadDebt_basic() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Create bad-debt: drop collateral price so collateralUSD < debtUSD.
        // debt = 1.08M supply tokens. At $1 each = $1.08M USD.
        // collateral = 1.5M tokens. We need collateralUSD < debtUSD = $1.08M.
        // At price $0.70: collateralUSD = 1.5M * 0.7 = $1.05M < $1.08M. Bad debt!
        _setPrice(address(collateral), 0.7e18);

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        // Repay enough to cover principal (debt must fall to <= interest).
        uint256 repayAmt = vault.outstandingDebt() - interest;
        supply.mint(admin, repayAmt);
        supply.approve(address(vault), repayAmt);

        vm.expectEmit(true, true, false, false);
        emit BaseVault.StateTransition(VaultState.Lock, VaultState.Liquidated, block.timestamp);
        vm.expectEmit(false, false, false, false);
        emit InstitutionalLoanVault.VaultLiquidated(0);

        vault.repayBadDebt(repayAmt);

        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));
        assertTrue(vault.runtime().protocolShareSettled);
    }

    function test_repayBadDebt_revertsIfNotBadDebt() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Vault is healthy — collateralUSD >= debtUSD.
        supply.mint(admin, 1);
        supply.approve(address(vault), 1);
        vm.expectRevert(InstitutionalLoanVault.NotBadDebt.selector);
        vault.repayBadDebt(1);
    }

    function test_repayBadDebt_revertsIfZero() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        _setPrice(address(collateral), 0.7e18);
        vm.expectRevert(BaseVault.ZeroRepayAmount.selector);
        vault.repayBadDebt(0);
    }

    function test_repayBadDebt_revertsIfNoDebt() external {
        _openVault();
        _lockVault();
        // Debt at Lock is interest only; repay it all.
        uint256 debt = vault.outstandingDebt();
        supply.mint(admin, debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);

        _setPrice(address(collateral), 0.7e18);
        vm.expectRevert(BaseVault.NoOutstandingDebt.selector);
        vault.repayBadDebt(1);
    }

    function test_repayBadDebt_revertsIfInsufficientRepayment() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        _setPrice(address(collateral), 0.7e18);

        // Repay a tiny amount — debt will still be > interest.
        uint256 tinyRepay = 1;
        supply.mint(admin, tinyRepay);
        supply.approve(address(vault), tinyRepay);
        vm.expectRevert(InstitutionalLoanVault.InsufficientRepayment.selector);
        vault.repayBadDebt(tinyRepay);
    }

    function test_repayBadDebt_revertsIfWrongState() external {
        _openVault();
        // In Fundraising.
        supply.mint(admin, 1);
        supply.approve(address(vault), 1);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.repayBadDebt(1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3H — Risk Parameter Setters
    // ──────────────────────────────────────────────────────────────────────

    function test_setLiquidationThreshold_valid() external {
        uint256 newLT = 0.8e18;

        vm.expectEmit(true, false, false, true);
        emit InstitutionalLoanVault.LiquidationThresholdUpdated(LT, newLT);

        controller.setLiquidationThreshold(address(vault), newLT);

        assertEq(vault.riskConfig().liquidationThreshold, newLT);
    }

    function test_setLiquidationThreshold_revertsIfZero() external {
        vm.expectRevert(InstitutionalVaultController.InvalidLiquidationThreshold.selector);
        controller.setLiquidationThreshold(address(vault), 0);
    }

    function test_setLiquidationThreshold_revertsIfExceedsMantissa() external {
        vm.expectRevert(InstitutionalVaultController.InvalidLiquidationThreshold.selector);
        controller.setLiquidationThreshold(address(vault), MANTISSA_ONE + 1);
    }

    function test_setLiquidationThreshold_revertsIfNotController() external {
        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.setLiquidationThreshold(0.8e18);
    }

    function test_setLiquidationIncentive_valid() external {
        uint256 newLI = 1.15e18;

        vm.expectEmit(false, false, false, true);
        emit InstitutionalLoanVault.LiquidationIncentiveUpdated(LI, newLI);

        controller.setLiquidationIncentive(address(vault), newLI);

        assertEq(vault.riskConfig().liquidationIncentive, newLI);
    }

    function test_setLiquidationIncentive_revertsIfBelowMantissa() external {
        vm.expectRevert(InstitutionalVaultController.InvalidLiquidationIncentive.selector);
        controller.setLiquidationIncentive(address(vault), MANTISSA_ONE);
    }

    function test_setLiquidationIncentive_revertsIfAboveMax() external {
        uint256 tooHigh = controller.MANTISSA_ONE_AND_HALF() + 1;
        vm.expectRevert(InstitutionalVaultController.InvalidLiquidationIncentive.selector);
        controller.setLiquidationIncentive(address(vault), tooHigh);
    }

    function test_setLatePenaltyRate_valid() external {
        uint256 newRate = 1.2e18;

        vm.expectEmit(false, false, false, true);
        emit InstitutionalLoanVault.LatePenaltyRateUpdated(LATE_PENALTY_RATE, newRate);

        controller.setLatePenaltyRate(address(vault), newRate);

        assertEq(vault.riskConfig().latePenaltyRate, newRate);
    }

    function test_setLatePenaltyRate_revertsIfBelowMantissa() external {
        vm.expectRevert(InstitutionalVaultController.InvalidLatePenaltyRate.selector);
        controller.setLatePenaltyRate(address(vault), MANTISSA_ONE);
    }

    function test_setLatePenaltyRate_revertsIfAboveMax() external {
        uint256 tooHigh = controller.MANTISSA_ONE_AND_HALF() + 1;
        vm.expectRevert(InstitutionalVaultController.InvalidLatePenaltyRate.selector);
        controller.setLatePenaltyRate(address(vault), tooHigh);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3I — Oracle Edge Cases
    // ──────────────────────────────────────────────────────────────────────

    function test_getCollateralValueUSD_zeroPrice_reverts() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // setDirectPrice(asset, 0) falls through to a missing Chainlink feed and reverts with a
        // different error. Mock getPrice directly to return 0 so the vault's InvalidOraclePrice
        // guard is exercised.
        vm.mockCall(
            address(oracle), abi.encodeWithSignature("getPrice(address)", address(collateral)), abi.encode(uint256(0))
        );
        vm.expectRevert(InstitutionalLoanVault.InvalidOraclePrice.selector);
        vault.getCollateralValueUSD();
    }

    function test_getDebtValueUSD_zeroPrice_reverts() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.mockCall(
            address(oracle), abi.encodeWithSignature("getPrice(address)", address(supply)), abi.encode(uint256(0))
        );
        vm.expectRevert(InstitutionalLoanVault.InvalidOraclePrice.selector);
        vault.getDebtValueUSD();
    }

    function test_calculateSeizeAmount_zeroPrices_reverts() external {
        _openVault();
        _lockVault();

        vm.mockCall(
            address(oracle), abi.encodeWithSignature("getPrice(address)", address(supply)), abi.encode(uint256(0))
        );
        vm.expectRevert(InstitutionalLoanVault.InvalidOraclePrice.selector);
        vault.calculateSeizeAmount(1e18, LiquidationType.HF_BASED);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 3J — View Functions
    // ──────────────────────────────────────────────────────────────────────

    function test_getVaultLiquidity_healthy() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        (uint256 liquidity, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(liquidity, 0);
        assertEq(shortfall, 0);
    }

    function test_getVaultLiquidity_shortfall() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        _setPrice(address(collateral), 0.9e18);

        (uint256 liquidity, uint256 shortfall) = vault.getVaultLiquidity();
        assertEq(liquidity, 0);
        assertGt(shortfall, 0);
    }

    function test_getHypotheticalVaultLiquidity_simulates_withdrawal() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        (uint256 liqBefore,) = vault.getVaultLiquidity();
        uint256 collatBal = vault.institutionalRuntime().totalCollateralDeposited;

        (uint256 liqAfter, uint256 shortfallAfter) = vault.getHypotheticalVaultLiquidity(collatBal / 2, 0);

        // Simulated withdrawal must reduce liquidity.
        assertLt(liqAfter, liqBefore);
        // Full removal must create shortfall.
        (, uint256 shortfallFull) = vault.getHypotheticalVaultLiquidity(collatBal, 0);
        assertGt(shortfallFull, shortfallAfter);
    }

    function test_calculateSeizeAmount_HFBased() external {
        _openVault();
        _lockVault();

        uint256 repayAmt = 10_000e18;
        // supplyPrice = 1e18, collateralPrice = 1e18, incentive = LI = 1.1e18
        uint256 repayValueUSD = repayAmt; // price = $1
        uint256 seizeValueUSD = (repayValueUSD * LI) / MANTISSA_ONE;
        uint256 expectedSeize = seizeValueUSD; // collateralPrice = $1

        assertEq(vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED), expectedSeize);
    }

    function test_calculateSeizeAmount_deadline() external {
        _openVault();
        _lockVault();

        uint256 repayAmt = 10_000e18;
        // latePenaltyRate = 1.15e18, both prices = $1
        uint256 expectedSeize = (repayAmt * LATE_PENALTY_RATE) / MANTISSA_ONE;

        assertEq(vault.calculateSeizeAmount(repayAmt, LiquidationType.DEADLINE), expectedSeize);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Configurable-decimal ERC-20 mock
// ──────────────────────────────────────────────────────────────────────────────

contract MockERC20Decimals is ERC20 {
    uint8 private _dec;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Test suite: Cross-decimal liquidation (6-dec supply, 18-dec collateral)
// ──────────────────────────────────────────────────────────────────────────────

contract CrossDecimalLiquidationTest is Test {
    // ── Constants
    // ────────────────────────────────────────────────────────
    uint256 constant FIXED_APY = 800;
    uint256 constant RESERVE_FACTOR = 0.1e18;
    uint40 constant OPEN_DURATION = 7 days;
    uint40 constant LOCK_DURATION = 365 days;
    uint40 constant SETTLEMENT_WINDOW = 30 days;
    uint256 constant BPS = 10_000;
    uint256 constant MANTISSA_ONE = 1e18;
    uint256 constant YEAR = 365 days;

    uint256 constant LT = 0.75e18;
    uint256 constant LI = 1.1e18;
    uint256 constant LATE_PENALTY_RATE = 1.15e18;
    uint256 constant CLOSE_FACTOR = 0.5e18;
    uint256 constant PROTOCOL_LIQ_SHARE = 0.1e18;

    // ── Actors
    // ────────────────────────────────────────────────────────────
    address internal admin;
    address internal institution;
    address internal lender1;
    address internal liquidator;
    address internal proxyAdmin;
    address internal comptrollerAddr;

    // ── Contracts
    // ──────────────────────────────────────────────────────────
    InstitutionalVaultController internal controller;
    InstitutionalLoanVault internal vault;
    LiquidationAdapter internal adapter;
    InstitutionPositionToken internal posToken;
    MockERC20Decimals internal supply6;
    MockERC20Decimals internal collateral18;
    AccessControlManager internal acm;
    ChainlinkOracle internal oracle;
    MockPSR internal psr;

    // ── Cap sizing (in 6-decimal supply units)
    // ────────────────────────────
    uint256 constant MAX_BORROW_CAP = 1_000_000e6;
    uint256 constant MIN_BORROW_CAP = 500_000e6;
    uint256 constant IDEAL_COLLATERAL_AMOUNT = 1_500_000e18;
    uint256 constant MARGIN_RATE = 0.1e18;
    uint256 constant MARGIN_AMOUNT = 150_000e18;

    function setUp() external {
        admin = address(this);
        institution = makeAddr("institution");
        lender1 = makeAddr("lender1");
        liquidator = makeAddr("liquidator");
        proxyAdmin = makeAddr("proxyAdmin");
        comptrollerAddr = makeAddr("comptroller");

        supply6 = new MockERC20Decimals("USD Coin", "USDC", 6);
        collateral18 = new MockERC20Decimals("Collateral Token", "COL", 18);
        psr = new MockPSR();

        _deploySystem();
        _createVault();
        _openVault();
    }

    function _deploySystem() internal {
        acm = new AccessControlManager();

        ChainlinkOracle oracleImpl = new ChainlinkOracle();
        oracle = ChainlinkOracle(
            address(
                new TransparentUpgradeableProxy(
                    address(oracleImpl), proxyAdmin, abi.encodeCall(ChainlinkOracle.initialize, (address(acm)))
                )
            )
        );
        acm.giveCallPermission(address(0), "setDirectPrice(address,uint256)", admin);

        // setDirectPrice stores raw 18-decimal USD prices.
        // getPrice will return: storedPrice * 10^(18 - token.decimals())
        // For supply6 (6 dec): getPrice = 1e18 * 10^12 = 1e30
        // For collateral18 (18 dec): getPrice = 1e18 * 10^0 = 1e18
        oracle.setDirectPrice(address(supply6), 1e18);
        oracle.setDirectPrice(address(collateral18), 1e18);

        posToken = new InstitutionPositionToken();

        InstitutionalLoanVault vaultImpl = new InstitutionalLoanVault();
        LiquidationAdapter adapterImpl = new LiquidationAdapter();
        InstitutionalVaultController controllerImpl = new InstitutionalVaultController();

        controller = InstitutionalVaultController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        InstitutionalVaultController.initialize,
                        (
                            address(vaultImpl),
                            address(1),
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

        _grantAllPermissions();
        controller.setLiquidationAdapter(address(adapter));

        posToken.transferOwnership(address(controller));
        controller.acceptPositionTokenOwnership();
    }

    function _grantAllPermissions() internal {
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

    function _createVault() internal {
        VaultConfig memory cfg = VaultConfig({
            supplyAsset: IERC20(address(supply6)),
            fixedAPY: FIXED_APY,
            reserveFactor: RESERVE_FACTOR,
            minBorrowCap: MIN_BORROW_CAP,
            maxBorrowCap: MAX_BORROW_CAP,
            minSupplierDeposit: 0,
            openDuration: OPEN_DURATION,
            lockDuration: LOCK_DURATION,
            settlementWindow: SETTLEMENT_WINDOW
        });

        InstitutionalConfig memory instCfg = InstitutionalConfig({
            collateralAsset: IERC20(address(collateral18)),
            idealCollateralAmount: IDEAL_COLLATERAL_AMOUNT,
            marginRate: MARGIN_RATE,
            institutionOperator: institution,
            positionTokenId: 0
        });

        RiskConfig memory rc =
            RiskConfig({ liquidationThreshold: LT, liquidationIncentive: LI, latePenaltyRate: LATE_PENALTY_RATE });

        address vaultAddr = controller.createVault(cfg, instCfg, rc);
        vault = InstitutionalLoanVault(vaultAddr);
    }

    function _openVault() internal {
        collateral18.mint(institution, MARGIN_AMOUNT);
        vm.startPrank(institution);
        collateral18.approve(address(vault), MARGIN_AMOUNT);
        vault.depositCollateral(MARGIN_AMOUNT);
        vm.stopPrank();

        controller.openVault(address(vault));
    }

    function _lockVault() internal {
        supply6.mint(lender1, MAX_BORROW_CAP);
        vm.startPrank(lender1);
        supply6.approve(address(vault), MAX_BORROW_CAP);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral18.mint(institution, remaining);
        vm.startPrank(institution);
        collateral18.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Test: Cross-decimal liquidation (6-dec supply, 18-dec collateral)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Sets up a liquidatable vault with 6-decimal supply and 18-decimal collateral,
    ///         then verifies the seize amount formula produces economically correct results
    ///         across the decimal mismatch.
    ///
    ///         Oracle math:
    ///           supply6 price  = setDirectPrice(1e18) → getPrice = 1e18 * 10^12 = 1e30
    ///           collateral18 price = setDirectPrice(1e18) → getPrice = 1e18
    ///
    ///         Seize formula:
    ///           repayValueUSD = repayAmount * supplyPrice / MANTISSA_ONE
    ///           seizeValueUSD = repayValueUSD * incentive / MANTISSA_ONE
    ///           seizeAmount   = seizeValueUSD * MANTISSA_ONE / collateralPrice
    ///
    ///         For repayAmount = 10_000e6 ($10K USDC), incentive = 1.1e18 (10%):
    ///           repayValueUSD = 10_000e6 * 1e30 / 1e18 = 10_000e18 ($10K)
    ///           seizeValueUSD = 10_000e18 * 1.1e18 / 1e18 = 11_000e18 ($11K)
    ///           seizeAmount   = 11_000e18 * 1e18 / 1e18 = 11_000e18 (11K collateral tokens)
    ///         At $1/token, 11_000 collateral tokens = $11K, which is $10K * 1.1 incentive.
    function test_liquidate_crossDecimalPair() external {
        _lockVault();

        vm.prank(institution);
        vault.claimRaisedFunds();

        // Drop collateral price to trigger LT shortfall.
        // At $0.50/token: collateral = $750K, LT-weighted = $562.5K < ~$1.08M debt → liquidatable.
        oracle.setDirectPrice(address(collateral18), 0.5e18);

        adapter.setLiquidatorWhitelist(liquidator, true);

        uint256 repayAmount = 10_000e6; // $10K USDC
        supply6.mint(liquidator, repayAmount);

        uint256 expectedSeize = vault.calculateSeizeAmount(repayAmount, LiquidationType.HF_BASED);

        vm.startPrank(liquidator);
        supply6.approve(address(adapter), repayAmount);
        adapter.liquidate(address(vault), repayAmount);
        vm.stopPrank();

        // supplyPrice = 1e18 (stored) → getPrice = 1e30 (after decimal scaling for 6-dec token)
        // collateralPrice = 0.5e18 (stored) → getPrice = 0.5e18 (18-dec token, no scaling)
        // repayValueUSD = 10_000e6 * 1e30 / 1e18 = 10_000e18 ($10K)
        // seizeValueUSD = 10_000e18 * 1.1e18 / 1e18 = 11_000e18 ($11K)
        // seizeAmount = 11_000e18 * 1e18 / 0.5e18 = 22_000e18 (22K collateral tokens)
        // At $0.50/token: 22K tokens * $0.50 = $11K = $10K * 1.1. Correct.
        uint256 expectedRepayValueUSD = (repayAmount * oracle.getPrice(address(supply6))) / MANTISSA_ONE;
        uint256 expectedSeizeValueUSD = (expectedRepayValueUSD * LI) / MANTISSA_ONE;
        uint256 expectedSeizeCalc = (expectedSeizeValueUSD * MANTISSA_ONE) / oracle.getPrice(address(collateral18));

        assertEq(expectedSeize, expectedSeizeCalc, "preview matches manual calculation");

        uint256 collateralPrice = oracle.getPrice(address(collateral18));
        uint256 seizedValueUSD = (expectedSeize * collateralPrice) / MANTISSA_ONE;
        uint256 repaidValueUSD = (repayAmount * oracle.getPrice(address(supply6))) / MANTISSA_ONE;
        uint256 expectedIncentivizedValue = (repaidValueUSD * LI) / MANTISSA_ONE;

        assertEq(seizedValueUSD, expectedIncentivizedValue, "seized USD = repaid USD * incentive");

        // Protocol share is on incentive portion only, not total seized.
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / LI;
        uint256 incentiveAmt = expectedSeize - repayEquivalent;
        uint256 protocolAmount = (incentiveAmt * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 expectedLiquidatorAmt = expectedSeize - protocolAmount;

        assertEq(
            collateral18.balanceOf(liquidator),
            expectedLiquidatorAmt,
            "liquidator received collateral minus protocol share on incentive portion"
        );
    }
}
