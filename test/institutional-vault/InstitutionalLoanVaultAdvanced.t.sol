// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { VaultState } from "../../src/interfaces/IVaultTypes.sol";
import { LiquidationType } from "../../src/interfaces/IInstitutionalVaultTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InstitutionalLoanVaultAdvancedTest is VaultTestBase {
    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
        _createVault();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Section A — Fuzz tests for liquidation math
    // ──────────────────────────────────────────────────────────────────────

    function testFuzz_calculateSeizeAmount_HFBased(
        uint256 repayAmt,
        uint256 supplyPrice,
        uint256 collateralPrice
    ) external {
        repayAmt = bound(repayAmt, 1e18, 500_000e18);
        supplyPrice = bound(supplyPrice, 0.01e18, 10_000e18);
        collateralPrice = bound(collateralPrice, 0.01e18, 10_000e18);

        // Get vault to Lock state.
        _openVault();
        _lockVault();

        // Mock oracle prices via setDirectPrice.
        _setPrice(address(supply), supplyPrice);
        _setPrice(address(collateral), collateralPrice);

        uint256 seize = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);

        // Expected: (repayAmt * supplyPrice / MANTISSA_ONE) * LI / collateralPrice
        uint256 repayValueUSD = (repayAmt * supplyPrice) / MANTISSA_ONE;
        uint256 expected = (repayValueUSD * LI) / collateralPrice;

        assertEq(seize, expected);
    }

    function testFuzz_calculateSeizeAmount_deadline(
        uint256 repayAmt,
        uint256 supplyPrice,
        uint256 collateralPrice
    ) external {
        repayAmt = bound(repayAmt, 1e18, 500_000e18);
        supplyPrice = bound(supplyPrice, 0.01e18, 10_000e18);
        collateralPrice = bound(collateralPrice, 0.01e18, 10_000e18);

        // Get vault to Lock state.
        _openVault();
        _lockVault();

        // Mock oracle prices.
        _setPrice(address(supply), supplyPrice);
        _setPrice(address(collateral), collateralPrice);

        uint256 seize = vault.calculateSeizeAmount(repayAmt, LiquidationType.DEADLINE);

        // Expected: same formula but uses LATE_PENALTY_RATE instead of LI.
        uint256 repayValueUSD = (repayAmt * supplyPrice) / MANTISSA_ONE;
        uint256 expected = (repayValueUSD * LATE_PENALTY_RATE) / collateralPrice;

        assertEq(seize, expected);
    }

    function testFuzz_liquidate_repayWithinCloseFactor(
        uint256 repayAmt
    ) external {
        // Setup liquidatable vault: collateral price drops to $0.90.
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();
        adapter.setLiquidatorWhitelist(liquidator, true);
        _setPrice(address(collateral), 0.9e18);

        uint256 debt = vault.outstandingDebt();
        uint256 maxRepay = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
        repayAmt = bound(repayAmt, 1e18, maxRepay);

        // Compute expected seize to ensure we don't exceed available collateral.
        uint256 expectedSeize = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 availableCollateral = vault.institutionalRuntime().totalCollateralDeposited;
        vm.assume(expectedSeize <= availableCollateral);

        uint256 debtBefore = vault.outstandingDebt();
        uint256 collateralBefore = vault.institutionalRuntime().totalCollateralDeposited;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        // Debt reduced by exact repayAmt.
        assertEq(vault.outstandingDebt(), debtBefore - repayAmt);

        // Liquidator received collateral (minus protocol share which stays on adapter).
        uint256 totalSeized = collateralBefore - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(totalSeized, expectedSeize);

        // Liquidator balance + protocol accrued = total seized.
        uint256 liquidatorCollateral = collateral.balanceOf(liquidator);
        uint256 protocolAccrued = adapter.protocolShareAccrued(address(collateral));
        assertEq(liquidatorCollateral + protocolAccrued, expectedSeize);
    }

    function testFuzz_collateralDeposit_anyAmount(
        uint256 amount
    ) external {
        // Setup vault in Fundraising state.
        _openVault();

        amount = bound(amount, 1e18, 10 * IDEAL_COLLATERAL_AMOUNT);

        collateral.mint(institution, amount);
        vm.startPrank(institution);
        collateral.approve(address(vault), amount);
        vault.depositCollateral(amount);
        vm.stopPrank();

        // MARGIN_AMOUNT was deposited during _openVault, now + amount.
        assertEq(vault.institutionalRuntime().totalCollateralDeposited, MARGIN_AMOUNT + amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Section B — Oracle edge cases
    // ──────────────────────────────────────────────────────────────────────

    function test_liquidate_seizeExceedsTotalCollateral_reverts() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();
        adapter.setLiquidatorWhitelist(liquidator, true);

        // Dramatically drop collateral price so seize formula returns more than totalCollateralDeposited.
        // At $0.01 collateral price with $1 supply: seize = repay * 1 * 1.1 / 0.01 = repay * 110
        // Even a small repayAmt will demand way more collateral than exists.
        _setPrice(address(collateral), 0.01e18);

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
        uint256 seizeAmount = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 availableCollateral = vault.institutionalRuntime().totalCollateralDeposited;

        // Verify seize would exceed available collateral.
        assertTrue(seizeAmount > availableCollateral);

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        vm.expectRevert(
            abi.encodeWithSelector(
                InstitutionalLoanVault.InsufficientCollateralForSeize.selector, seizeAmount, availableCollateral
            )
        );
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();
    }

    function test_healthFactor_extremePrices_noOverflow() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Set supply price to very large value and collateral price to very small.
        _setPrice(address(supply), 1_000_000e18);
        _setPrice(address(collateral), 1e12);

        // Should not overflow — should return shortfall > 0.
        (uint256 liquidity, uint256 shortfall) = vault.getVaultLiquidity();
        assertEq(liquidity, 0);
        assertTrue(shortfall > 0);
    }

    function test_healthFactor_verySmallPrices() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Both prices at 1 wei of USD (extremely small).
        _setPrice(address(supply), 1);
        _setPrice(address(collateral), 1);

        // Should work without division-by-zero or overflow. Since both prices are equal (1 wei),
        // the relative health check behaves the same as at $1/$1 — just scaled down uniformly.
        // collateralUSD = 1_500_000e18 * 1 / 1e18 = 1_500_000
        // debtUSD       = ~1_080_000e18 * 1 / 1e18 = ~1_080_000
        // ltCap         = 1_500_000 * 0.75e18 / 1e18 = 1_125_000
        // Since debtUSD < ltCap, vault is still healthy (liquidity > 0, shortfall == 0).
        (uint256 liquidity, uint256 shortfall) = vault.getVaultLiquidity();

        // Verify the function completed without reverting and returned consistent values.
        assertEq(shortfall, 0, "shortfall should be 0 - equal prices, vault still over-collateralised");
        assertGt(liquidity, 0, "liquidity should be > 0 with equal very small prices");
    }

    function test_getCollateralValueUSD_priceDropMakesLiquidatable() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        // Verify vault is healthy at $1 prices.
        (uint256 liquidity, uint256 shortfall) = vault.getVaultLiquidity();
        assertTrue(liquidity > 0);
        assertEq(shortfall, 0);

        // Drop collateral price to $0.90 — should create shortfall.
        _setPrice(address(collateral), 0.9e18);

        (uint256 liquidity2, uint256 shortfall2) = vault.getVaultLiquidity();
        assertEq(liquidity2, 0);
        assertTrue(shortfall2 > 0);

        // Execute liquidation — should succeed.
        adapter.setLiquidatorWhitelist(liquidator, true);
        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        // Debt reduced.
        assertEq(vault.outstandingDebt(), debt - repayAmt);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Section C — Full collateral depletion via repeated liquidations
    // ──────────────────────────────────────────────────────────────────────

    function test_repeatedLiquidations_drainCollateral() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();
        adapter.setLiquidatorWhitelist(liquidator, true);

        // Drop collateral price to $0.90 to make vault liquidatable.
        _setPrice(address(collateral), 0.9e18);

        // Perform multiple liquidations at close factor until either:
        // a) Collateral is fully drained (InsufficientCollateralForSeize)
        // b) No more shortfall (NotLiquidatable)
        uint256 totalRepaid;
        bool collateralDepleted;
        bool healthRestored;

        for (uint256 i; i < 20; ++i) {
            uint256 debt = vault.outstandingDebt();
            if (debt == 0) break;

            (, uint256 shortfall) = vault.getVaultLiquidity();
            if (shortfall == 0) {
                healthRestored = true;
                break;
            }

            uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
            if (repayAmt == 0) break;

            uint256 seizeAmount = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
            uint256 availableCollateral = vault.institutionalRuntime().totalCollateralDeposited;

            if (seizeAmount > availableCollateral) {
                collateralDepleted = true;
                break;
            }

            supply.mint(liquidator, repayAmt);
            vm.startPrank(liquidator);
            supply.approve(address(adapter), repayAmt);
            adapter.liquidate(address(vault), repayAmt);
            vm.stopPrank();

            totalRepaid += repayAmt;
        }

        // After all liquidations, one of the two exit conditions must hold.
        assertTrue(collateralDepleted || healthRestored);

        if (collateralDepleted) {
            // Bad debt scenario: debt still > 0 but collateral would be exceeded.
            assertTrue(vault.outstandingDebt() > 0);

            // Resolve via repayBadDebt.
            uint256 interest = _computeInterest(MAX_BORROW_CAP);
            uint256 remainingDebt = vault.outstandingDebt();
            uint256 repayForBadDebt = remainingDebt - interest;

            supply.mint(admin, repayForBadDebt);
            supply.approve(address(vault), repayForBadDebt);
            vault.repayBadDebt(repayForBadDebt);

            assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));
        }
    }

    function test_liquidation_afterPreviousLiquidation_reChecksHealth() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();
        adapter.setLiquidatorWhitelist(liquidator, true);

        // Drop collateral price to $0.90 to create shortfall.
        _setPrice(address(collateral), 0.9e18);

        // First liquidation at close factor.
        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        // Check if health was restored by the first liquidation.
        (, uint256 shortfall) = vault.getVaultLiquidity();

        if (shortfall == 0) {
            // Health restored — second liquidation should revert NotLiquidatable.
            uint256 debt2 = vault.outstandingDebt();
            uint256 repayAmt2 = (debt2 * CLOSE_FACTOR) / MANTISSA_ONE;

            supply.mint(liquidator, repayAmt2);
            vm.startPrank(liquidator);
            supply.approve(address(adapter), repayAmt2);
            vm.expectRevert(InstitutionalLoanVault.NotLiquidatable.selector);
            adapter.liquidate(address(vault), repayAmt2);
            vm.stopPrank();
        } else {
            // Still liquidatable — second liquidation should succeed.
            uint256 debt2 = vault.outstandingDebt();
            uint256 repayAmt2 = (debt2 * CLOSE_FACTOR) / MANTISSA_ONE;
            uint256 seizeAmount = vault.calculateSeizeAmount(repayAmt2, LiquidationType.HF_BASED);
            uint256 availableCollateral = vault.institutionalRuntime().totalCollateralDeposited;

            if (seizeAmount <= availableCollateral) {
                supply.mint(liquidator, repayAmt2);
                vm.startPrank(liquidator);
                supply.approve(address(adapter), repayAmt2);
                adapter.liquidate(address(vault), repayAmt2);
                vm.stopPrank();

                assertEq(vault.outstandingDebt(), debt2 - repayAmt2);
            }
        }
    }

    function test_badDebt_emergesFromRepeatedLiquidations() external {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();
        adapter.setLiquidatorWhitelist(liquidator, true);

        // Drop collateral price aggressively to $0.50 so liquidations drain collateral faster.
        _setPrice(address(collateral), 0.5e18);

        // Perform liquidations until collateral is depleted.
        for (uint256 i; i < 30; ++i) {
            uint256 debt = vault.outstandingDebt();
            if (debt == 0) break;

            (, uint256 shortfall) = vault.getVaultLiquidity();
            if (shortfall == 0) break;

            uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
            if (repayAmt == 0) break;

            uint256 seizeAmount = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
            uint256 availableCollateral = vault.institutionalRuntime().totalCollateralDeposited;

            if (seizeAmount > availableCollateral) break;

            supply.mint(liquidator, repayAmt);
            vm.startPrank(liquidator);
            supply.approve(address(adapter), repayAmt);
            adapter.liquidate(address(vault), repayAmt);
            vm.stopPrank();
        }

        // Verify bad debt condition: collateralValueUSD < debtValueUSD.
        uint256 collateralValueUSD = vault.getCollateralValueUSD();
        uint256 debtValueUSD = vault.getDebtValueUSD();
        assertTrue(collateralValueUSD < debtValueUSD);

        // repayBadDebt can be called to resolve.
        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 remainingDebt = vault.outstandingDebt();
        uint256 repayForBadDebt = remainingDebt - interest;

        supply.mint(admin, repayForBadDebt);
        supply.approve(address(vault), repayForBadDebt);
        vault.repayBadDebt(repayForBadDebt);

        // State transitions to Liquidated.
        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Section D — Position token transfer + vault operations
    // ──────────────────────────────────────────────────────────────────────

    function test_positionTransfer_newOwnerCanDepositCollateral() external {
        _openVault();

        address newInstitution = makeAddr("newInstitution");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        // Admin approves the transfer via controller.
        controller.approvePositionTransfer(address(vault), newInstitution);

        // Institution transfers position token to new owner.
        vm.prank(institution);
        posToken.transferFrom(institution, newInstitution, tokenId);

        // Verify new owner holds the token.
        assertEq(posToken.ownerOf(tokenId), newInstitution);

        // New owner can deposit collateral.
        uint256 depositAmt = 100_000e18;
        collateral.mint(newInstitution, depositAmt);
        vm.startPrank(newInstitution);
        collateral.approve(address(vault), depositAmt);
        vault.depositCollateral(depositAmt);
        vm.stopPrank();

        assertEq(vault.institutionalRuntime().totalCollateralDeposited, MARGIN_AMOUNT + depositAmt);

        // Old institution cannot deposit collateral.
        collateral.mint(institution, depositAmt);
        vm.startPrank(institution);
        collateral.approve(address(vault), depositAmt);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.depositCollateral(depositAmt);
        vm.stopPrank();
    }

    function test_positionTransfer_newOwnerCanClaimRaisedFunds() external {
        _openVault();
        _lockVault();

        address newInstitution = makeAddr("newInstitution");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        // Admin approves the transfer via controller.
        controller.approvePositionTransfer(address(vault), newInstitution);

        // Institution transfers position token to new owner.
        vm.prank(institution);
        posToken.transferFrom(institution, newInstitution, tokenId);

        // New owner calls claimRaisedFunds.
        vm.prank(newInstitution);
        vault.claimRaisedFunds();

        // Funds sent to new owner.
        assertEq(supply.balanceOf(newInstitution), MAX_BORROW_CAP);

        // Old owner cannot claim (already claimed anyway, but also not position holder).
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.claimRaisedFunds();
    }

    function test_positionTransfer_newOwnerCanWithdrawCollateral() external {
        // Full lifecycle to Matured.
        _openVault();
        _lockVault();
        _settleVault();

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        address newInstitution = makeAddr("newInstitution");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        // Admin approves the transfer via controller.
        controller.approvePositionTransfer(address(vault), newInstitution);

        // Institution transfers position token to new owner.
        vm.prank(institution);
        posToken.transferFrom(institution, newInstitution, tokenId);

        uint256 totalCollateral = vault.institutionalRuntime().totalCollateralDeposited;

        // New owner can withdraw all collateral.
        vm.prank(newInstitution);
        vault.withdrawCollateral(totalCollateral);

        assertEq(collateral.balanceOf(newInstitution), totalCollateral);
        assertEq(vault.institutionalRuntime().totalCollateralDeposited, 0);

        // Old owner would revert (also no collateral left, but not position holder).
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.withdrawCollateral(1);
    }

    function test_positionTransfer_oldOwnerCannotOperate() external {
        _openVault();

        address newInstitution = makeAddr("newInstitution");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        // Admin approves the transfer via controller.
        controller.approvePositionTransfer(address(vault), newInstitution);

        // Institution transfers position token to new owner.
        vm.prank(institution);
        posToken.transferFrom(institution, newInstitution, tokenId);

        // Verify old owner cannot call any position-holder gated functions.

        // 1. depositCollateral
        collateral.mint(institution, 1e18);
        vm.startPrank(institution);
        collateral.approve(address(vault), 1e18);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.depositCollateral(1e18);
        vm.stopPrank();

        // 2. withdrawCollateral — need Lock or terminal state; advance to Lock first.
        // Deposit remaining collateral as new owner so vault can lock.
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(newInstitution, remaining);
        vm.startPrank(newInstitution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        // Lender deposits to fill the cap.
        supply.mint(lender1, MAX_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MAX_BORROW_CAP);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        // Advance past open window to trigger Lock.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        // Settle the vault to reach Matured for unrestricted collateral withdrawal.
        uint256 lockEnd = vault.runtime().lockEndTime;
        vm.warp(lockEnd + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(newInstitution, debt);
        vm.startPrank(newInstitution);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        // Old owner cannot withdrawCollateral.
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.withdrawCollateral(1e18);

        // 3. claimRaisedFunds — vault is Matured, so it would revert InvalidState,
        //    but the modifier check for NotPositionHolder runs first.
        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.claimRaisedFunds();
    }
}
