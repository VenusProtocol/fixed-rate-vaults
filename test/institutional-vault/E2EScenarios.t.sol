// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { VaultState } from "../../src/interfaces/IVaultTypes.sol";
import { LiquidationType } from "../../src/interfaces/IInstitutionalVaultTypes.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice End-to-end scenario tests. Each test walks a complete continuous flow from vault
///         creation to final lender redemption, verifying the lender's actual received amount.
contract E2EScenariosTest is VaultTestBase {
    address internal lender3;

    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
        _createVault();
        lender3 = makeAddr("lender3");
    }

    // ── Local helpers
    // ──────────────────────────────────────────────────────

    function _whitelistLiquidator() internal {
        adapter.setLiquidatorWhitelist(liquidator, true);
    }

    function _whitelistSettler() internal {
        adapter.setSettlerWhitelist(settler, true);
    }

    /// @dev Mint supply, approve vault, and deposit as a given lender in one call.
    function _depositAs(
        address lender,
        uint256 amount
    ) internal {
        supply.mint(lender, amount);
        vm.startPrank(lender);
        supply.approve(address(vault), amount);
        vault.deposit(amount, lender);
        vm.stopPrank();
    }

    /// @dev Institution claims raised funds then fully repays all outstanding debt after lock ends.
    ///      Leaves vault in Matured state.
    function _claimAndRepay() internal {
        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState(); // → PendingSettlement

        uint256 debt = vault.outstandingDebt(); // principal + interest after claim
        supply.mint(institution, debt);
        vm.startPrank(institution);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        vault.updateVaultState(); // → Matured
    }

    // ──────────────────────────────────────────────────────────────────────
    // F1 — Full happy path (single lender)
    //      open → deposit → lock → claim → repay → lender redeems with interest
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_happyPath_singleLender() external {
        _openVault();
        _lockVault(); // lender1 = MAX_BORROW_CAP, institution tops up collateral

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        _claimAndRepay();

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        // Lender redeems all shares.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
        assertLe(vault.runtime().settlementAmount, 1);

        // Institution withdraws all collateral.
        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vault.withdrawCollateral(totalCollateral);

        assertEq(collateral.balanceOf(institution), IDEAL_COLLATERAL_AMOUNT);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F2 — Multi-lender proportional exit (3 lenders, different deposit sizes)
    //      Each lender redeems their exact proportional share of the settlement
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_happyPath_multiLender() external {
        _openVault();

        // Three lenders deposit 300k, 200k, 500k (sum = MAX_BORROW_CAP).
        uint256 deposit1 = 300_000e18;
        uint256 deposit2 = 200_000e18;
        uint256 deposit3 = 500_000e18;
        _depositAs(lender1, deposit1);
        _depositAs(lender2, deposit2);
        _depositAs(lender3, deposit3);

        // Institution tops up remaining collateral and warp → Lock.
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        _claimAndRepay();

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        uint256 settlement = MAX_BORROW_CAP + interest - protocolFee;

        // All three lenders redeem sequentially.
        uint256 shares1 = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares1, lender1, lender1);

        uint256 shares2 = vault.balanceOf(lender2);
        vm.prank(lender2);
        vault.redeem(shares2, lender2, lender2);

        uint256 shares3 = vault.balanceOf(lender3);
        vm.prank(lender3);
        vault.redeem(shares3, lender3, lender3);

        // Each lender receives their proportional share of the settlement pool.
        assertApproxEqAbs(supply.balanceOf(lender1), (settlement * deposit1) / MAX_BORROW_CAP, 2);
        assertApproxEqAbs(supply.balanceOf(lender2), (settlement * deposit2) / MAX_BORROW_CAP, 2);
        assertApproxEqAbs(supply.balanceOf(lender3), (settlement * deposit3) / MAX_BORROW_CAP, 2);

        // Vault fully drained (dust tolerance).
        assertLe(supply.balanceOf(address(vault)), 3);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F3 — Insufficient raise (clean fail)
    //      open → lenders deposit below min cap → vault fails → institution gets
    //      collateral back in full → lender redeems exact principal
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_insufficientRaise_cleanFail() external {
        _openVault();

        // Lender deposits well below MIN_BORROW_CAP — vault will fail.
        uint256 depositAmt = 100_000e18;
        _depositAs(lender1, depositAmt);

        // Warp past open window without reaching minCap → Failed.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertFalse(vault.institutionalRuntime().institutionDefaulted);

        // Institution withdraws all collateral (no confiscation in clean fail).
        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vault.withdrawCollateral(totalCollateral);

        // Lender redeems shares → receives exact principal, no loss.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertEq(collateral.balanceOf(institution), MARGIN_AMOUNT);
        assertEq(supply.balanceOf(lender1), depositAmt);
        assertEq(vault.runtime().settlementAmount, 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F4 — Institution default (collateral confiscation)
    //      open → lenders deposit above min cap → institution never tops up →
    //      vault fails with default → lender redeems principal + margin compensation
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_institutionDefault_confiscation() external {
        _openVault(); // only MARGIN_AMOUNT in vault (institution hasn't topped up)

        // Two lenders deposit above MIN_BORROW_CAP — lender1: 60%, lender2: 40%.
        uint256 deposit1 = (MIN_BORROW_CAP * 60) / 100; // 300_000e18
        uint256 deposit2 = MIN_BORROW_CAP - deposit1; // 200_000e18
        _depositAs(lender1, deposit1);
        _depositAs(lender2, deposit2);

        // Institution does NOT top up remaining collateral.
        // Warp past open window → Failed with institution default.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertTrue(vault.institutionalRuntime().institutionDefaulted);

        uint256 confiscated = vault.institutionalRuntime().confiscatedMarginRemaining;
        uint256 totalRaised = vault.runtime().totalRaised;

        // Lender1 redeems — 60% of principal + 60% of confiscated margin.
        uint256 shares1 = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares1, lender1, lender1);

        uint256 expectedCollateral1 = (confiscated * deposit1) / totalRaised;
        assertEq(supply.balanceOf(lender1), deposit1);
        assertApproxEqAbs(collateral.balanceOf(lender1), expectedCollateral1, 1);

        // Lender2 redeems — 40% of principal + 40% of confiscated margin.
        uint256 shares2 = vault.balanceOf(lender2);
        vm.prank(lender2);
        vault.redeem(shares2, lender2, lender2);

        uint256 expectedCollateral2 = (confiscated * deposit2) / totalRaised;
        assertEq(supply.balanceOf(lender2), deposit2);
        assertApproxEqAbs(collateral.balanceOf(lender2), expectedCollateral2, 1);

        // All confiscated margin distributed — none remaining.
        assertApproxEqAbs(vault.institutionalRuntime().confiscatedMarginRemaining, 0, 1);

        // Institution can no longer withdraw: all collateral was confiscated and distributed to lenders.
        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vm.prank(institution);
        vault.withdrawCollateral(1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F5 — Settlement deadline exceeded → settler covers all debt → lenders made whole
    //      open → lock → institution claims but never repays → deadline passes →
    //      settler repays via liquidateOverdueVault → lenders receive full principal + interest
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_deadlineExceeded_settlerCoversAll() external {
        _openVault();
        _lockVault();

        // Institution claims funds but will never repay.
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Warp past settlement deadline (lockEndTime + SETTLEMENT_WINDOW).
        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        // Allow settler to cover the full outstanding debt in a single call.
        adapter.setCloseFactor(1e18);
        _whitelistSettler();

        uint256 debt = vault.outstandingDebt();
        supply.mint(settler, debt);
        vm.startPrank(settler);
        supply.approve(address(adapter), debt);
        adapter.liquidateOverdueVault(address(vault), debt);
        vm.stopPrank();

        // Debt is now zero → advance to Matured.
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        // Lender redeems.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        // Settler covered all debt → lenders made whole.
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);

        // Settler seized more collateral than supply repaid (late penalty as incentive).
        assertGt(collateral.balanceOf(settler), 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F6 — Institution partial repay → price drop → bad debt → lender gets principal only
    //      open → lock → institution claims → repays partial principal → price crashes →
    //      bad debt condition → protocol covers gap → lender receives principal but no interest
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_partialRepay_badDebt_principalOnly() external {
        _openVault();
        _lockVault();

        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState(); // → PendingSettlement

        // Institution repays only 600_000 (less than full principal of 1_000_000).
        uint256 partialRepay = 600_000e18;
        supply.mint(institution, partialRepay);
        vm.startPrank(institution);
        supply.approve(address(vault), partialRepay);
        vault.repay(partialRepay);
        vm.stopPrank();

        // Drop collateral price → collateralUSD (450_000) < debtUSD (480_000): bad debt condition.
        // collateral = 1_500_000 * 0.3 = 450_000; debt = 480_000 * 1 = 480_000
        _setPrice(address(collateral), 0.3e18);

        uint256 remainingDebt = vault.outstandingDebt(); // 480_000e18
        uint256 totalInterest = _computeInterest(MAX_BORROW_CAP); // 80_000e18

        // repayBadDebt: must cover at least (remainingDebt - totalInterest) so totalDebt ≤ totalInterest.
        uint256 badDebtCoverage = remainingDebt - totalInterest; // 400_000e18
        supply.mint(address(this), badDebtCoverage);
        supply.approve(address(controller), badDebtCoverage);
        controller.repayBadDebt(address(vault), badDebtCoverage);

        // Vault transitions to Liquidated; _settleProtocolShare runs.
        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));

        // Lender redeems.
        // Vault supply at settlement = 600_000 (institution) + 400_000 (bad debt) = 1_000_000
        // available (1_000_000) <= totalRaised (1_000_000) → shortfall case, no fee.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertEq(supply.balanceOf(lender1), MAX_BORROW_CAP);

        // Confirm lender received less than the happy-path outcome (no interest).
        assertLt(supply.balanceOf(lender1), MAX_BORROW_CAP + totalInterest - _computeProtocolFee(totalInterest));
    }

    // ──────────────────────────────────────────────────────────────────────
    // F6b — Bad debt: protocol covers principal shortfall AND full interest →
    //       lenders receive complete principal + interest on redeem
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_badDebt_protocolCoversAll_lenderGetsFull() external {
        _openVault();
        _lockVault();

        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState(); // → PendingSettlement

        // Institution repays nothing — full outstanding debt is bad debt.
        // Drop collateral price so bad debt condition holds.
        // collateral = 1_500_000 * 0.3 = 450_000 USD; debt = 1_080_000 USD
        _setPrice(address(collateral), 0.3e18);

        uint256 totalInterest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(totalInterest);
        uint256 fullDebt = vault.outstandingDebt(); // principal + interest = 1_080_000e18

        // Protocol covers the full outstanding debt (principal + interest) via repayBadDebt.
        supply.mint(address(this), fullDebt);
        supply.approve(address(controller), fullDebt);
        controller.repayBadDebt(address(vault), fullDebt);

        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));

        // Lender redeems.
        // available at settlement = fullDebt repaid = 1_080_000
        // available > totalRaised → surplus path → protocol fee applied on interest portion.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        uint256 expectedBalance = MAX_BORROW_CAP + totalInterest - protocolFee;
        assertApproxEqAbs(supply.balanceOf(lender1), expectedBalance, 1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F7 — HF liquidation during lock → institution repays remaining debt → lenders made whole
    //      open → lock → price drop → liquidation → lock ends → institution repays remainder →
    //      lenders receive full principal + interest despite the liquidation event
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_liquidation_thenFullRepay() external {
        _openVault();
        _lockVault();

        vm.prank(institution);
        vault.claimRaisedFunds(); // totalDebt = principal + interest = 1_080_000

        // Drop collateral price to trigger HF-based liquidation.
        // collateralUSD = 1_500_000 * 0.7 = 1_050_000; debtUSD = 1_080_000 → HF ≈ 0.729 < LT 0.75
        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 liqRepay = 50_000e18;
        uint256 expectedSeize = vault.calculateSeizeAmount(liqRepay, LiquidationType.HF_BASED);

        supply.mint(liquidator, liqRepay);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), liqRepay);
        adapter.liquidate(address(vault), liqRepay);
        vm.stopPrank();

        // Liquidator received collateral (net of protocol share).
        assertGt(collateral.balanceOf(liquidator), 0);
        assertLe(collateral.balanceOf(liquidator), expectedSeize);

        // Institution repays remaining debt after lock ends.
        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 remainingDebt = vault.outstandingDebt(); // 1_030_000 (reduced by liquidation repay)
        supply.mint(institution, remainingDebt);
        vm.startPrank(institution);
        supply.approve(address(vault), remainingDebt);
        vault.repay(remainingDebt);
        vm.stopPrank();

        vault.updateVaultState(); // → Matured

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        // Lender redeems.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        // Total supply in vault at settlement = 50_000 (liq repay) + 1_030_000 (inst repay) = 1_080_000
        // available = expectedRepayment → full settlement, lenders fully made whole.
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F8 — Repeated liquidations drain collateral → bad debt → lender gets principal only
    //      open → lock → institution claims, never repays → price crashes → liquidations
    //      drain collateral → protocol repays bad debt → lender receives principal only
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_badDebt_collateralDrain() external {
        _openVault();
        _lockVault();

        vm.prank(institution);
        vault.claimRaisedFunds(); // institution receives supply, never repays

        // Crash collateral price — one liquidation will drain most of the collateral.
        // collateralUSD = 1_500_000 * 0.4 = 600_000; debtUSD = 1_080_000 → HF ≈ 0.417
        _setPrice(address(collateral), 0.4e18);
        _whitelistLiquidator();

        // Liquidate at max close factor: repay 540_000 → seize 1_485_000 (leaves ~15_000 collateral).
        uint256 debt = vault.outstandingDebt(); // 1_080_000e18
        uint256 maxRepay = (debt * CLOSE_FACTOR) / MANTISSA_ONE; // 540_000e18

        supply.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), maxRepay);
        adapter.liquidate(address(vault), maxRepay);
        vm.stopPrank();

        // Collateral is near-zero; bad debt condition is met.
        // collateralLeft ≈ 15_000 * 0.4 = 6_000 << debtUSD = 540_000
        uint256 collateralLeft = vault.institutionalRuntime().totalCollateralDeposited;
        assertLt(collateralLeft, 20_000e18);
        assertGt(vault.outstandingDebt(), 0);
        assertLt(vault.getCollateralValueUSD(), vault.getDebtValueUSD());

        // Protocol covers bad debt: repay enough to bring totalDebt ≤ totalInterest.
        uint256 remainingDebt = vault.outstandingDebt(); // 540_000e18
        uint256 totalInterest = _computeInterest(MAX_BORROW_CAP); // 80_000e18
        uint256 badDebtCoverage = remainingDebt - totalInterest; // 460_000e18

        supply.mint(address(this), badDebtCoverage);
        supply.approve(address(controller), badDebtCoverage);
        controller.repayBadDebt(address(vault), badDebtCoverage);

        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));

        // Lender redeems.
        // Vault supply at settlement = 540_000 (liq repay) + 460_000 (bad debt) = 1_000_000
        // available (1_000_000) <= totalRaised (1_000_000) → shortfall, no fee.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertEq(supply.balanceOf(lender1), MAX_BORROW_CAP);

        // Lender received principal only — no interest due to bad debt.
        assertLt(supply.balanceOf(lender1), MAX_BORROW_CAP + totalInterest - _computeProtocolFee(totalInterest));
    }

    // ──────────────────────────────────────────────────────────────────────
    // F9 — Position token transfer mid-lifecycle → new holder completes full cycle
    //      open → transfer position → lock → new holder claims → repays → lenders
    //      made whole; new holder recovers collateral; original institution gets nothing
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_positionTransfer_newHolderCompletesCycle() external {
        _openVault(); // institution deposits MARGIN_AMOUNT

        // Governance approves position token transfer.
        controller.approvePositionTransfer(address(vault));

        address newHolder = makeAddr("newHolder");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        // Institution transfers position NFT to new holder.
        vm.prank(institution);
        IERC721(address(posToken)).safeTransferFrom(institution, newHolder, tokenId);
        assertEq(posToken.ownerOf(tokenId), newHolder);

        // Lender deposits.
        _depositAs(lender1, MAX_BORROW_CAP);

        // New holder tops up remaining collateral.
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(newHolder, remaining);
        vm.startPrank(newHolder);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        // Warp → Lock.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        // New holder claims raised funds (institution operator access now belongs to new holder).
        vm.prank(newHolder);
        vault.claimRaisedFunds();
        assertEq(supply.balanceOf(newHolder), MAX_BORROW_CAP);

        // New holder repays full debt after lock ends (principal already held + mint interest portion).
        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState();
        uint256 debt = vault.outstandingDebt(); // principal + interest
        uint256 interestOwed = debt - MAX_BORROW_CAP;
        supply.mint(newHolder, interestOwed);
        vm.startPrank(newHolder);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        vault.updateVaultState(); // → Matured

        // Lender redeems with full principal + interest.
        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);

        // New holder withdraws all collateral (margin deposited by institution + top-up by new holder).
        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(newHolder);
        vault.withdrawCollateral(totalCollateral);
        assertEq(collateral.balanceOf(newHolder), IDEAL_COLLATERAL_AMOUNT);

        // Original institution has no collateral — position was transferred away.
        assertEq(collateral.balanceOf(institution), 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // F10 — Pause during fundraising → unpause → complete cycle
    //       open → partial pause blocks deposit → unpause → deposit succeeds →
    //       full settlement → lender receives correct amount (pause didn't corrupt state)
    // ──────────────────────────────────────────────────────────────────────

    function test_e2e_pause_unpause_completeCycle() external {
        _openVault();

        // Partial pause blocks new deposits.
        controller.partialPauseVault(address(vault));
        supply.mint(lender1, MAX_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MAX_BORROW_CAP);
        vm.expectRevert(BaseVault.PartiallyPaused.selector);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        // Unpause restores deposit access.
        controller.unpauseVault(address(vault));
        vm.startPrank(lender1);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        assertEq(vault.runtime().totalRaised, MAX_BORROW_CAP);

        // Institution tops up remaining collateral and warp → Lock.
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        // Full settlement.
        _claimAndRepay();

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        // Lender redeems — pause/unpause did not corrupt any vault state.
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
    }
}
