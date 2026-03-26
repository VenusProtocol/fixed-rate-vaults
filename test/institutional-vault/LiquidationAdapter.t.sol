// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { LiquidationAdapter } from "../../src/institutional-vault/LiquidationAdapter.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { VaultState } from "../../src/interfaces/IVaultTypes.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract LiquidationAdapterTest is VaultTestBase {
    function setUp() external {
        _makeActors();
        _deployTokens();
        _deploySystem();
        _createVault();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4A — Initialization
    // ──────────────────────────────────────────────────────────────────────

    function test_initialize_setsAllParams() external {
        assertEq(adapter.vaultController(), address(controller));
        assertEq(adapter.protocolShareReserve(), address(psr));
        assertEq(adapter.comptroller(), comptrollerAddr);
        assertEq(adapter.protocolLiquidationShare(), PROTOCOL_LIQ_SHARE);
        assertEq(adapter.closeFactor(), CLOSE_FACTOR);
    }

    function test_initialize_revertsIfCalledTwice() external {
        vm.expectRevert("Initializable: contract is already initialized");
        adapter.initialize(
            address(controller), address(psr), comptrollerAddr, PROTOCOL_LIQ_SHARE, CLOSE_FACTOR, address(acm)
        );
    }

    function test_initialize_revertsIfProtocolShareExceedsMantissa() external {
        LiquidationAdapter adapterImpl = new LiquidationAdapter();
        vm.expectRevert(LiquidationAdapter.InvalidShare.selector);
        new TransparentUpgradeableProxy(
            address(adapterImpl),
            makeAddr("pa2"),
            abi.encodeCall(
                LiquidationAdapter.initialize,
                (address(controller), address(psr), comptrollerAddr, MANTISSA_ONE + 1, CLOSE_FACTOR, address(acm))
            )
        );
    }

    function test_initialize_revertsIfZeroAddress() external {
        LiquidationAdapter adapterImpl = new LiquidationAdapter();
        address impl_ = address(adapterImpl);
        address pa = makeAddr("pa_la");

        vm.expectRevert(LiquidationAdapter.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                LiquidationAdapter.initialize,
                (address(0), address(psr), comptrollerAddr, PROTOCOL_LIQ_SHARE, CLOSE_FACTOR, address(acm))
            )
        );

        vm.expectRevert(LiquidationAdapter.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                LiquidationAdapter.initialize,
                (address(controller), address(0), comptrollerAddr, PROTOCOL_LIQ_SHARE, CLOSE_FACTOR, address(acm))
            )
        );

        vm.expectRevert(LiquidationAdapter.InvalidAddress.selector);
        new TransparentUpgradeableProxy(
            impl_,
            pa,
            abi.encodeCall(
                LiquidationAdapter.initialize,
                (address(controller), address(psr), address(0), PROTOCOL_LIQ_SHARE, CLOSE_FACTOR, address(acm))
            )
        );
    }

    function test_initialize_revertsIfCloseFactorZero() external {
        LiquidationAdapter adapterImpl = new LiquidationAdapter();
        vm.expectRevert(LiquidationAdapter.InvalidCloseFactor.selector);
        new TransparentUpgradeableProxy(
            address(adapterImpl),
            makeAddr("pa3"),
            abi.encodeCall(
                LiquidationAdapter.initialize,
                (address(controller), address(psr), comptrollerAddr, PROTOCOL_LIQ_SHARE, 0, address(acm))
            )
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4B — Whitelist Management
    // ──────────────────────────────────────────────────────────────────────

    function test_addLiquidator_ACMGated() external {
        vm.expectEmit(true, false, false, true);
        emit LiquidationAdapter.LiquidatorWhitelistUpdated(liquidator, true);

        adapter.setLiquidatorWhitelist(liquidator, true);

        assertTrue(adapter.isWhitelistedLiquidator(liquidator));
    }

    function test_removeLiquidator() external {
        adapter.setLiquidatorWhitelist(liquidator, true);
        adapter.setLiquidatorWhitelist(liquidator, false);

        assertFalse(adapter.isWhitelistedLiquidator(liquidator));
    }

    function test_addSettler() external {
        vm.expectEmit(true, false, false, true);
        emit LiquidationAdapter.SettlerWhitelistUpdated(settler, true);

        adapter.setSettlerWhitelist(settler, true);

        assertTrue(adapter.isWhitelistedSettler(settler));
    }

    function test_removeSettler() external {
        adapter.setSettlerWhitelist(settler, true);
        adapter.setSettlerWhitelist(settler, false);

        assertFalse(adapter.isWhitelistedSettler(settler));
    }

    function test_whitelist_revertsIfNotACM() external {
        vm.prank(lender1);
        vm.expectRevert();
        adapter.setLiquidatorWhitelist(liquidator, true);

        vm.prank(lender1);
        vm.expectRevert();
        adapter.setSettlerWhitelist(settler, true);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4C — Liquidate Flow
    // ──────────────────────────────────────────────────────────────────────

    function _setupLiquidatableVault() internal {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        adapter.setLiquidatorWhitelist(liquidator, true);
        // Drop collateral price to create LT shortfall.
        _setPrice(address(collateral), 0.9e18);
    }

    function test_liquidate_basic() external {
        _setupLiquidatableVault();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        // Compute expected seize: repayUSD * LI / collateralPrice
        uint256 repayValueUSD = repayAmt; // supply price = $1
        uint256 seizeValueUSD = (repayValueUSD * LI) / MANTISSA_ONE;
        uint256 expectedSeize = (seizeValueUSD * MANTISSA_ONE) / 0.9e18; // collateral price = $0.9

        // Compute expected split: protocol share is on incentive portion only.
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / LI;
        uint256 incentiveAmt = expectedSeize - repayEquivalent;
        uint256 expectedProtocol = (incentiveAmt * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 expectedLiquidator = expectedSeize - expectedProtocol;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);

        vm.expectEmit(false, false, false, true);
        emit LiquidationAdapter.LiquidationCollateralSplit(expectedSeize, expectedProtocol, expectedLiquidator);

        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        assertEq(collateral.balanceOf(liquidator), expectedLiquidator);
        assertEq(adapter.protocolShareAccrued(address(collateral)), expectedProtocol);
    }

    function test_liquidate_protocolShareSplit() external {
        _setupLiquidatableVault();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 totalSeized = collateral.balanceOf(liquidator) + adapter.protocolShareAccrued(address(collateral));
        uint256 repayEquivalent = (totalSeized * MANTISSA_ONE) / LI;
        uint256 incentiveAmt = totalSeized - repayEquivalent;
        uint256 expectedProtocol = (incentiveAmt * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;

        assertEq(adapter.protocolShareAccrued(address(collateral)), expectedProtocol);
        assertEq(collateral.balanceOf(liquidator), totalSeized - expectedProtocol);
    }

    function test_liquidate_revertsIfZeroRepay() external {
        _setupLiquidatableVault();

        vm.startPrank(liquidator);
        vm.expectRevert(LiquidationAdapter.ZeroRepayAmount.selector);
        adapter.liquidate(address(vault), 0);
        vm.stopPrank();
    }

    function test_liquidate_revertsIfVaultNotRegistered() external {
        adapter.setLiquidatorWhitelist(liquidator, true);

        address fakeVault = makeAddr("fakeVault");
        supply.mint(liquidator, 1e18);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), 1e18);
        vm.expectRevert(LiquidationAdapter.VaultNotRegistered.selector);
        adapter.liquidate(fakeVault, 1e18);
        vm.stopPrank();
    }

    function test_liquidate_revertsIfNotWhitelisted() external {
        _setupLiquidatableVault();

        address nonWhitelisted = makeAddr("nonWhitelisted");
        supply.mint(nonWhitelisted, 1e18);
        vm.startPrank(nonWhitelisted);
        supply.approve(address(adapter), 1e18);
        vm.expectRevert(LiquidationAdapter.NotWhitelistedLiquidator.selector);
        adapter.liquidate(address(vault), 1e18);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4D — LiquidateOverdueVault Flow
    // ──────────────────────────────────────────────────────────────────────

    function _setupOverdueLiquidation() internal {
        _openVault();
        _lockVault();
        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState(); // SettlementDeadlineExceeded

        adapter.setSettlerWhitelist(settler, true);
    }

    function test_liquidateOverdue_basic() external {
        _setupOverdueLiquidation();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        // Pre-compute expected seize and split.
        uint256 repayValueUSD = repayAmt; // price = $1
        uint256 seizeValueUSD = (repayValueUSD * LATE_PENALTY_RATE) / MANTISSA_ONE;
        uint256 expectedSeize = seizeValueUSD; // collateral price = $1
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / LATE_PENALTY_RATE;
        uint256 incentiveAmt = expectedSeize - repayEquivalent;
        uint256 expectedProtocol = (incentiveAmt * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 expectedSettler = expectedSeize - expectedProtocol;

        supply.mint(settler, repayAmt);
        vm.startPrank(settler);
        supply.approve(address(adapter), repayAmt);

        vm.expectEmit(false, false, false, true);
        emit LiquidationAdapter.LiquidationCollateralSplit(expectedSeize, expectedProtocol, expectedSettler);

        adapter.liquidateOverdueVault(address(vault), repayAmt);
        vm.stopPrank();

        assertEq(vault.outstandingDebt(), debt - repayAmt);
        assertEq(collateral.balanceOf(settler), expectedSettler);
        assertEq(adapter.protocolShareAccrued(address(collateral)), expectedProtocol);
    }

    function test_liquidateOverdue_revertsIfNotWhitelistedSettler() external {
        _setupOverdueLiquidation();

        address nonWhitelisted = makeAddr("nonWhitelisted");
        supply.mint(nonWhitelisted, 1e18);
        vm.startPrank(nonWhitelisted);
        supply.approve(address(adapter), 1e18);
        vm.expectRevert(LiquidationAdapter.NotWhitelistedSettler.selector);
        adapter.liquidateOverdueVault(address(vault), 1e18);
        vm.stopPrank();
    }

    function test_liquidateOverdue_revertsIfVaultNotRegistered() external {
        adapter.setSettlerWhitelist(settler, true);

        address fakeVault = makeAddr("fakeVault");
        supply.mint(settler, 1e18);
        vm.startPrank(settler);
        supply.approve(address(adapter), 1e18);
        vm.expectRevert(LiquidationAdapter.VaultNotRegistered.selector);
        adapter.liquidateOverdueVault(fakeVault, 1e18);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4E — sweepProtocolShare
    // ──────────────────────────────────────────────────────────────────────

    function test_sweepProtocolShare_basic() external {
        _setupLiquidatableVault();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 accrued = adapter.protocolShareAccrued(address(collateral));
        assertGt(accrued, 0);

        vm.expectEmit(true, false, false, true);
        emit LiquidationAdapter.ProtocolShareSweptToReserve(address(collateral), accrued);

        adapter.sweepProtocolShareToReserve(address(collateral));

        assertEq(adapter.protocolShareAccrued(address(collateral)), 0);
        assertEq(collateral.balanceOf(address(psr)), accrued);
    }

    function test_sweepProtocolShare_revertsIfNotACM() external {
        vm.prank(lender1);
        vm.expectRevert();
        adapter.sweepProtocolShareToReserve(address(collateral));
    }

    function test_sweepProtocolShare_zeroBalance_noop() external {
        // No liquidations occurred — protocolShareAccrued is zero.
        assertEq(adapter.protocolShareAccrued(address(collateral)), 0);

        // Must not revert, nothing transferred.
        adapter.sweepProtocolShareToReserve(address(collateral));

        assertEq(collateral.balanceOf(address(psr)), 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4F — Config Setters
    // ──────────────────────────────────────────────────────────────────────

    function test_setCloseFactor_valid() external {
        uint256 newCF = 0.6e18;

        vm.expectEmit(false, false, false, true);
        emit LiquidationAdapter.CloseFactorUpdated(adapter.closeFactor(), newCF);

        adapter.setCloseFactor(newCF);

        assertEq(adapter.closeFactor(), newCF);
    }

    function test_setCloseFactor_revertsIfExceedsMantissa() external {
        vm.expectRevert(LiquidationAdapter.InvalidCloseFactor.selector);
        adapter.setCloseFactor(MANTISSA_ONE + 1);
    }

    function test_setCloseFactor_revertsIfZero() external {
        vm.expectRevert(LiquidationAdapter.InvalidCloseFactor.selector);
        adapter.setCloseFactor(0);
    }

    function test_setProtocolLiquidationShare_valid() external {
        uint256 newShare = 0.2e18;

        vm.expectEmit(false, false, false, true);
        emit LiquidationAdapter.ProtocolLiquidationShareUpdated(adapter.protocolLiquidationShare(), newShare);

        adapter.setProtocolLiquidationShare(newShare);

        assertEq(adapter.protocolLiquidationShare(), newShare);
    }

    function test_setProtocolLiquidationShare_revertsIfExceedsMantissa() external {
        vm.expectRevert(LiquidationAdapter.InvalidShare.selector);
        adapter.setProtocolLiquidationShare(MANTISSA_ONE + 1);
    }

    function test_setProtocolShareReserve_valid() external {
        address newPSR = makeAddr("newPSR");

        vm.expectEmit(true, true, false, false);
        emit LiquidationAdapter.ProtocolShareReserveUpdated(address(psr), newPSR);

        adapter.setProtocolShareReserve(newPSR);

        assertEq(adapter.protocolShareReserve(), newPSR);
    }

    function test_setComptroller_valid() external {
        address newComp = makeAddr("newComptroller");

        vm.expectEmit(true, true, false, false);
        emit LiquidationAdapter.ComptrollerUpdated(comptrollerAddr, newComp);

        adapter.setComptroller(newComp);

        assertEq(adapter.comptroller(), newComp);
    }
}
