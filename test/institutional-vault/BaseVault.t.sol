// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseVault } from "../../src/BaseVault.sol";
import { VaultConfig, VaultRuntime, VaultState, PauseLevel } from "../../src/interfaces/IVaultTypes.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPSR } from "./mocks/MockPSR.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Minimal concrete vault for testing BaseVault mechanics in isolation.
// Implements the two virtual hooks as the simplest correct logic.
// ──────────────────────────────────────────────────────────────────────────────

contract TestVault is BaseVault {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        VaultConfig calldata cfg,
        address controller_
    ) external initializer {
        __BaseVault_init(IERC20Upgradeable(address(cfg.supplyAsset)), "Test Vault Share", "TVS", controller_);
        _config = cfg;
        _runtime.state = VaultState.Fundraising;
        _runtime.isActive = true;
        uint40 ts = uint40(block.timestamp);
        _runtime.openStartTime = ts;
        _runtime.openEndTime = ts + cfg.openDuration;
        _runtime.lockStartTime = _runtime.openEndTime;
        _runtime.lockEndTime = _runtime.openEndTime + cfg.lockDuration;
        _runtime.settlementDeadline = _runtime.lockEndTime + cfg.settlementWindow;
    }

    function repay(
        uint256 amount
    ) external nonReentrant whenNotCompletelyPaused {
        _repay(msg.sender, amount);
    }

    function claimRaisedFunds(
        address recipient
    ) external onlyController {
        _claimRaisedFunds(recipient);
    }

    /// @dev Test-only helper: forces vault directly to Matured and runs settlement.
    ///      Used to test _settleProtocolShare behaviour when debt > 0 prevents normal auto-transition.
    function forceSettle() external {
        _runtime.state = VaultState.Matured;
        _settleProtocolShare();
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Minimal controller stub — provides PSR and comptroller for settlement tests.
// ──────────────────────────────────────────────────────────────────────────────

contract VaultControllerStub {
    address public protocolShareReserve;
    address public comptroller;
    address public treasury;

    constructor(
        address psr_,
        address comptroller_,
        address treasury_
    ) {
        protocolShareReserve = psr_;
        comptroller = comptroller_;
        treasury = treasury_;
    }

    // Forward vault lifecycle calls (close / pause).
    function callVault(
        address vault,
        bytes calldata data
    ) external returns (bytes memory) {
        (bool ok, bytes memory ret) = vault.call(data);
        require(ok, "VaultControllerStub: vault call failed");
        return ret;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// BaseVault test suite
// ──────────────────────────────────────────────────────────────────────────────

contract BaseVaultTest is Test {
    TestVault internal vault;
    VaultControllerStub internal mockVaultController;
    MockERC20 internal supply;
    MockERC20 internal extraToken;
    MockPSR internal psr;

    address internal admin;
    address internal lender1;
    address internal lender2;
    address internal proxyAdmin;

    uint256 constant MAX_CAP = 1_000_000e18;
    uint256 constant MIN_CAP = 500_000e18;
    uint256 constant FIXED_APY = 800;
    uint256 constant RESERVE_FACTOR = 0.1e18;
    uint40 constant OPEN_DURATION = 7 days;
    uint40 constant LOCK_DURATION = 365 days;
    uint40 constant SETTLEMENT_WINDOW = 30 days;
    uint256 constant BPS = 10_000;
    uint256 constant MANTISSA_ONE = 1e18;
    uint256 constant YEAR = 365 days;

    function setUp() external {
        admin = address(this);
        lender1 = makeAddr("lender1");
        lender2 = makeAddr("lender2");
        proxyAdmin = makeAddr("proxyAdmin");

        supply = new MockERC20("Mock USDC", "mUSDC");
        extraToken = new MockERC20("Extra Token", "EXTRA");
        psr = new MockPSR();

        address comptrollerAddr = makeAddr("comptroller");
        mockVaultController = new VaultControllerStub(address(psr), comptrollerAddr, makeAddr("treasury"));

        _deployVault();
    }

    function _deployVault() internal {
        TestVault impl = new TestVault();
        vault = TestVault(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    proxyAdmin,
                    abi.encodeCall(TestVault.initialize, (_buildConfig(), address(mockVaultController)))
                )
            )
        );
    }

    function _buildConfig() internal view returns (VaultConfig memory) {
        return VaultConfig({
            supplyAsset: IERC20(address(supply)),
            fixedAPY: FIXED_APY,
            reserveFactor: RESERVE_FACTOR,
            minBorrowCap: MIN_CAP,
            maxBorrowCap: MAX_CAP,
            minSupplierDeposit: 0,
            openDuration: OPEN_DURATION,
            lockDuration: LOCK_DURATION,
            settlementWindow: SETTLEMENT_WINDOW
        });
    }

    // ── Helpers
    // ──────────────────────────────────────────────────────────

    function _mintAndDeposit(
        address lender,
        uint256 assets
    ) internal returns (uint256 shares) {
        supply.mint(lender, assets);
        vm.startPrank(lender);
        supply.approve(address(vault), assets);
        shares = vault.deposit(assets, lender);
        vm.stopPrank();
    }

    function _warpToLock() internal {
        // Warp past the open window so _advanceStateFromOpen triggers Lock.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
    }

    function _depositAndLock(
        uint256 depositAmount
    ) internal {
        _mintAndDeposit(lender1, depositAmount);
        _warpToLock();
    }

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

    // ──────────────────────────────────────────────────────────────────────
    // 2A — ERC-4626 Deposits
    // ──────────────────────────────────────────────────────────────────────

    function test_deposit_basic() external {
        uint256 depositAmount = 100e18;
        uint256 expectedShares = vault.previewDeposit(depositAmount);

        supply.mint(lender1, depositAmount);
        vm.startPrank(lender1);
        supply.approve(address(vault), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit IERC4626Upgradeable.Deposit(lender1, lender1, depositAmount, expectedShares);
        uint256 shares = vault.deposit(depositAmount, lender1);
        vm.stopPrank();

        assertEq(shares, expectedShares);
        assertEq(vault.balanceOf(lender1), expectedShares);
        assertEq(vault.runtime().totalRaised, depositAmount);
        assertEq(supply.balanceOf(address(vault)), depositAmount);
        assertEq(supply.balanceOf(lender1), 0);
    }

    function test_deposit_clampedToRemaining() external {
        // Fill vault almost to cap, then try to deposit more.
        uint256 firstDeposit = MAX_CAP - 1e18;
        _mintAndDeposit(lender1, firstDeposit);

        // Second deposit requests more than remaining capacity (1e18 left).
        uint256 excess = 5e18;
        supply.mint(lender2, excess);
        vm.startPrank(lender2);
        supply.approve(address(vault), excess);
        uint256 shares2 = vault.deposit(excess, lender2);
        vm.stopPrank();

        // Only 1e18 should have been deposited (clamped).
        uint256 expectedClamped = 1e18;
        assertEq(shares2, vault.convertToShares(expectedClamped));
        assertEq(vault.runtime().totalRaised, MAX_CAP);
        // lender2 gets refunded the excess (approve was higher but only remaining pulled)
        assertEq(supply.balanceOf(lender2), excess - expectedClamped);
    }

    function test_deposit_revertsAtCapacity() external {
        _mintAndDeposit(lender1, MAX_CAP);

        supply.mint(lender2, 1);
        vm.startPrank(lender2);
        supply.approve(address(vault), 1);
        vm.expectRevert(BaseVault.ExceedsMaxCap.selector);
        vault.deposit(1, lender2);
        vm.stopPrank();
    }

    function test_deposit_revertsIfNotFundraising() external {
        _depositAndLock(MIN_CAP); // advances to Lock

        supply.mint(lender2, 100e18);
        vm.startPrank(lender2);
        supply.approve(address(vault), 100e18);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.deposit(100e18, lender2);
        vm.stopPrank();
    }

    function test_mint_revertsIfNotFundraising() external {
        _depositAndLock(MIN_CAP); // advances to Lock

        supply.mint(lender2, 100e18);
        vm.startPrank(lender2);
        supply.approve(address(vault), 100e18);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.mint(100e18, lender2);
        vm.stopPrank();
    }

    function test_deposit_belowMinimum() external {
        // Redeploy with a non-zero minSupplierDeposit.
        TestVault impl = new TestVault();
        VaultConfig memory cfg = _buildConfig();
        cfg.minSupplierDeposit = 1000e18;
        TestVault vaultWithMin = TestVault(
            address(
                new TransparentUpgradeableProxy(
                    address(impl), proxyAdmin, abi.encodeCall(TestVault.initialize, (cfg, address(mockVaultController)))
                )
            )
        );

        supply.mint(lender1, 500e18);
        vm.startPrank(lender1);
        supply.approve(address(vaultWithMin), 500e18);
        vm.expectRevert(BaseVault.BelowMinimumDepositAmount.selector);
        vaultWithMin.deposit(500e18, lender1);
        vm.stopPrank();
    }

    function test_mint_basic() external {
        uint256 sharesToMint = 100e18;
        uint256 expectedAssets = vault.previewMint(sharesToMint);

        supply.mint(lender1, expectedAssets);
        vm.startPrank(lender1);
        supply.approve(address(vault), expectedAssets);
        uint256 assets = vault.mint(sharesToMint, lender1);
        vm.stopPrank();

        assertEq(assets, expectedAssets);
        assertEq(vault.balanceOf(lender1), sharesToMint);
        assertEq(vault.runtime().totalRaised, expectedAssets);
    }

    function test_maxDeposit_inFundraising() external {
        uint256 deposited = 200_000e18;
        _mintAndDeposit(lender1, deposited);

        assertEq(vault.maxDeposit(lender2), MAX_CAP - deposited);
    }

    function test_maxDeposit_zeroOutsideFundraising() external {
        _depositAndLock(MIN_CAP);
        assertEq(vault.maxDeposit(lender1), 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 2B — State Machine
    // ──────────────────────────────────────────────────────────────────────

    function test_fundraisingToLock_atMinCap() external {
        uint256 raised = MIN_CAP;
        _mintAndDeposit(lender1, raised);

        uint256 expectedInterest = _computeInterest(raised);

        // Warp first so block.timestamp matches what the state machine will record.
        vm.warp(vault.runtime().openEndTime + 1);

        vm.expectEmit(true, true, false, true);
        emit BaseVault.StateTransition(VaultState.Fundraising, VaultState.Lock, block.timestamp);
        vm.expectEmit(false, false, false, true);
        emit BaseVault.VaultLocked(raised, vault.runtime().lockEndTime);

        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Lock));
        assertEq(vault.runtime().totalDebt, expectedInterest);
    }

    function test_fundraisingToFailed_belowMinCap() external {
        // No deposits → raised = 0 < minCap.
        vm.expectEmit(true, true, false, false);
        emit BaseVault.StateTransition(VaultState.Fundraising, VaultState.Failed, block.timestamp + 1);

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertEq(vault.runtime().settlementAmount, 0);
    }

    function test_lockToPendingSettlement() external {
        _depositAndLock(MIN_CAP);

        uint256 lockEnd = vault.runtime().lockEndTime;
        vm.warp(lockEnd + 1);

        vm.expectEmit(true, true, false, false);
        emit BaseVault.StateTransition(VaultState.Lock, VaultState.PendingSettlement, lockEnd + 1);

        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.PendingSettlement));
    }

    function test_pendingSettlementToMatured_onFullRepay() external {
        _depositAndLock(MIN_CAP);

        // Claim funds → institution owes principal + interest.
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        // Warp past lock end.
        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState(); // now PendingSettlement

        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);

        // State transition PendingSettlement -> Matured fires inside repay (via _checkAndAdvanceState).
        vm.expectEmit(true, true, false, false);
        emit BaseVault.StateTransition(VaultState.PendingSettlement, VaultState.Matured, block.timestamp);

        vault.repay(debt);

        vault.updateVaultState(); // no-op: already Matured

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    function test_pendingSettlementToSettlementDeadlineExceeded() external {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        // Warp past settlement deadline with debt outstanding.
        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));
    }

    function test_settlementDeadlineExceededToMatured() external {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState(); // SettlementDeadlineExceeded

        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);

        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    function test_stateCannotGoBackward_fromMatured() external {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vault.updateVaultState(); // Matured

        // Calling updateVaultState again must not change state.
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    // ──────────────────────────────────────────────────────────────────────
    // 2C — Settlement (_settleProtocolShare)
    // ──────────────────────────────────────────────────────────────────────

    function test_settlement_fullRepayment() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this)); // institution receives funds, totalDebt += totalRaised

        vm.warp(vault.runtime().lockEndTime + 1);

        uint256 interest = _computeInterest(MAX_CAP);
        uint256 expectedFee = _computeProtocolFee(interest);
        uint256 totalOwed = MAX_CAP + interest;

        supply.mint(address(this), totalOwed);
        supply.approve(address(vault), totalOwed);

        // Settlement fires inside repay (Lock->PendingSettlement->Matured in one _checkAndAdvanceState call).
        // Full repayment: available == totalOwed, surplus == 0.
        vm.expectEmit(false, false, false, true);
        emit BaseVault.SettlementConfirmed(totalOwed - expectedFee, expectedFee, 0);

        vault.repay(totalOwed);
        vault.updateVaultState(); // no-op: already Matured

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
        assertEq(vault.runtime().settlementAmount, totalOwed - expectedFee);
        assertEq(supply.balanceOf(address(psr)), expectedFee);
        assertEq(psr.callCount(), 1);
        assertTrue(vault.runtime().protocolShareSettled);
    }

    function test_settlement_partialInterest() external {
        uint256 raised = MAX_CAP;
        _depositAndLock(raised);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);

        uint256 interest = _computeInterest(raised);
        // Repay principal + half the interest (partial interest coverage).
        // After repay: debt = interest/2 > 0, so _checkAndAdvanceState only reaches PendingSettlement.
        // Settlement is triggered by forceSettle() which bypasses the debt==0 requirement.
        uint256 partialInterest = interest / 2;
        uint256 repayAmt = raised + partialInterest;
        supply.mint(address(this), repayAmt);
        supply.approve(address(vault), repayAmt);
        vault.repay(repayAmt); // state: Lock -> PendingSettlement (debt still > 0)

        uint256 expectedFee = (partialInterest * RESERVE_FACTOR) / MANTISSA_ONE;
        uint256 expectedSettlement = repayAmt - expectedFee;

        vm.expectEmit(false, false, false, true);
        emit BaseVault.ShortfallDetected(raised + interest, repayAmt);

        vault.forceSettle(); // forces Matured + runs _settleProtocolShare with partial vault balance

        assertEq(vault.runtime().settlementAmount, expectedSettlement);
        assertEq(supply.balanceOf(address(psr)), expectedFee);
    }

    function test_settlement_principalShortfall() external {
        uint256 raised = MAX_CAP;
        _depositAndLock(raised);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);

        // Repay only 90% of principal — available < totalRaised, so no protocol fee.
        // Debt remains > 0, so auto-transition to Matured is blocked; use forceSettle().
        uint256 repayAmt = (raised * 9) / 10;
        supply.mint(address(this), repayAmt);
        supply.approve(address(vault), repayAmt);
        vault.repay(repayAmt); // state: Lock -> PendingSettlement (debt still > 0)

        vm.expectEmit(false, false, false, false);
        emit BaseVault.ShortfallDetected(raised + _computeInterest(raised), repayAmt);

        vault.forceSettle(); // forces Matured + runs _settleProtocolShare with partial vault balance

        // Protocol fee is zero on principal shortfall (available <= totalRaised).
        assertEq(supply.balanceOf(address(psr)), 0);
        assertEq(vault.runtime().settlementAmount, repayAmt);
    }

    function test_settlement_surplus() external {
        uint256 raised = MAX_CAP;
        _depositAndLock(raised);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);

        uint256 interest = _computeInterest(raised);
        uint256 surplus = 5000e18;
        uint256 totalOwed = raised + interest;

        // Mint surplus BEFORE repay so it's already in the vault when _settleProtocolShare runs.
        // Settlement fires inside repay (Lock->PS->Matured), so balanceOf at that moment = surplus + totalOwed.
        supply.mint(address(vault), surplus);

        supply.mint(address(this), totalOwed);
        supply.approve(address(vault), totalOwed);

        uint256 expectedFee = _computeProtocolFee(interest);
        uint256 expectedPSRTotal = expectedFee + surplus;

        vm.expectEmit(false, false, false, true);
        emit BaseVault.SettlementConfirmed(totalOwed - expectedFee, expectedFee, surplus);

        vault.repay(totalOwed); // triggers settlement; available = surplus + totalOwed
        vault.updateVaultState(); // no-op: already Matured

        assertEq(supply.balanceOf(address(psr)), expectedPSRTotal);
        assertEq(vault.runtime().settlementAmount, totalOwed - expectedFee);
    }

    function test_settlement_idempotent() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vault.updateVaultState(); // triggers _settleProtocolShare once

        uint256 psrBalanceAfterFirst = supply.balanceOf(address(psr));
        uint256 settlementAmtAfterFirst = vault.runtime().settlementAmount;

        // Calling updateVaultState again must not re-settle.
        vault.updateVaultState();

        assertEq(supply.balanceOf(address(psr)), psrBalanceAfterFirst);
        assertEq(vault.runtime().settlementAmount, settlementAmtAfterFirst);
    }

    function test_settlement_psrRevertIsCaught() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);

        // Force PSR to revert on updateAssetsState BEFORE repay.
        // Settlement fires inside repay (Lock->PS->Matured), so the revert happens there.
        psr.setShouldRevert(true);

        vm.expectEmit(true, false, false, false);
        emit BaseVault.PSRNotificationFailed(address(psr), bytes("MockPSR: forced revert"));

        // Settlement must NOT revert; PSRNotificationFailed is emitted instead.
        vault.repay(debt);

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
        // PSR balance should be non-zero (tokens transferred; only updateAssetsState reverted).
        assertGt(supply.balanceOf(address(psr)), 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 2D — Withdraw / Redeem
    // ──────────────────────────────────────────────────────────────────────

    function test_withdraw_inMatured() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vault.updateVaultState();

        uint256 settlementBefore = vault.runtime().settlementAmount;
        uint256 sharesToRedeem = vault.balanceOf(lender1);
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        vm.prank(lender1);
        uint256 withdrawn = vault.withdraw(expectedAssets, lender1, lender1);

        assertEq(withdrawn, sharesToRedeem); // shares burned
        assertEq(supply.balanceOf(lender1), expectedAssets);
        assertEq(vault.runtime().settlementAmount, settlementBefore - expectedAssets);
    }

    function test_redeem_inFailed() external {
        // Failed vault: no deposits made, so lender1 has no shares. Test with a deposit then fail.
        uint256 depositAmt = 100_000e18; // below minCap
        _mintAndDeposit(lender1, depositAmt);

        // Warp past open window without reaching minCap → Failed.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));

        uint256 shares = vault.balanceOf(lender1);
        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.prank(lender1);
        uint256 assets = vault.redeem(shares, lender1, lender1);

        assertEq(assets, expectedAssets);
        assertEq(assets, depositAmt); // in Failed state, lender gets back exactly what they deposited
        assertEq(supply.balanceOf(lender1), assets);
        assertEq(vault.balanceOf(lender1), 0);
    }

    function test_withdraw_revertsIfNotTerminal() external {
        _depositAndLock(MIN_CAP); // now in Lock

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.withdraw(shares, lender1, lender1);
    }

    function test_redeem_revertsIfNotTerminal() external {
        _depositAndLock(MIN_CAP); // now in Lock

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.redeem(shares, lender1, lender1);
    }

    function test_redeem_advancesStateFirst() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        // State is PendingSettlement with zero debt. Calling redeem triggers state advance to Matured.

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        uint256 assets = vault.redeem(shares, lender1, lender1);

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
        assertGt(assets, 0);
    }

    function test_maxWithdraw_zeroOutsideTerminal() external {
        _depositAndLock(MIN_CAP);
        assertEq(vault.maxWithdraw(lender1), 0);
    }

    function test_totalAssets_inMatured() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vault.updateVaultState();

        assertEq(vault.totalAssets(), vault.runtime().settlementAmount);
    }

    function test_totalAssets_inFailed() external {
        uint256 depositAmt = 100_000e18;
        _mintAndDeposit(lender1, depositAmt);
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(vault.totalAssets(), vault.runtime().settlementAmount);
        assertEq(vault.totalAssets(), depositAmt);
    }

    function test_totalAssets_inFundraising() external {
        uint256 depositAmt = 200_000e18;
        _mintAndDeposit(lender1, depositAmt);

        assertEq(vault.totalAssets(), depositAmt);
    }

    /// @dev Direct supply token transfer to vault must not affect totalAssets().
    ///      totalAssets() reads _runtime.totalRaised (a counter), not supply.balanceOf(vault).
    ///      A donation is invisible to share price — the vault is immune to balance inflation.
    function test_totalAssets_ignoredDirectSupplyDonation() external {
        uint256 depositAmt = 200_000e18;
        _mintAndDeposit(lender1, depositAmt);

        // Donate directly — bypasses deposit(), so totalRaised is NOT incremented.
        uint256 donation = 500_000e18;
        supply.mint(address(this), donation);
        supply.transfer(address(vault), donation);

        // balanceOf reflects the donation, but totalAssets() must not.
        assertEq(supply.balanceOf(address(vault)), depositAmt + donation);
        assertEq(vault.totalAssets(), depositAmt); // counter-based, donation invisible
        assertEq(vault.runtime().totalRaised, depositAmt);
    }

    /// @dev Classic first-depositor share-inflation attack must be blocked.
    ///      Attack: deposit 1 wei → 1 share, then donate a huge amount directly so
    ///      the next lender's shares round to 0.
    ///      Because totalAssets() uses totalRaised (not balanceOf), the share price
    ///      is never inflated by a direct transfer — lenders always receive correct shares.
    function test_directSupplyDonation_doesNotInflateSharePrice() external {
        address attacker = makeAddr("attacker");

        // Attacker becomes first depositor with 1 wei.
        supply.mint(attacker, 1);
        vm.startPrank(attacker);
        supply.approve(address(vault), 1);
        vault.deposit(1, attacker);
        vm.stopPrank();

        // Attacker donates a large amount directly to vault to try to inflate share price.
        uint256 donation = 1_000_000e18;
        supply.mint(attacker, donation);
        vm.prank(attacker);
        supply.transfer(address(vault), donation);

        // totalRaised = 1, totalSupply = 1 — share price is 1:1, donation is invisible.
        // Without counter protection: totalAssets = 1 + 1_000_000e18, next lender would get 0 shares.
        uint256 depositAmt = 100_000e18;
        uint256 sharesReceived = _mintAndDeposit(lender1, depositAmt);

        // Lender must receive shares equal to their deposit — not 0.
        assertEq(sharesReceived, depositAmt);
        assertEq(vault.balanceOf(lender1), depositAmt);
    }

    // ──────────────────────────────────────────────────────────────────────
    // 2E — Pause System
    // ──────────────────────────────────────────────────────────────────────

    function test_partialPause_blocksDeposit() external {
        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.partialPause, ()));

        supply.mint(lender1, 100e18);
        vm.startPrank(lender1);
        supply.approve(address(vault), 100e18);
        vm.expectRevert(BaseVault.PartiallyPaused.selector);
        vault.deposit(100e18, lender1);
        vm.stopPrank();
    }

    function test_partialPause_allowsRepay() external {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.partialPause, ()));

        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        // Must NOT revert — repay uses whenNotCompletelyPaused, not whenNotPaused.
        vault.repay(debt);
    }

    function test_completePause_blocksRepay() external {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.completePause, ()));

        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vm.expectRevert(BaseVault.CompletelyPaused.selector);
        vault.repay(debt);
    }

    function test_unpause_restoresDeposit() external {
        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.partialPause, ()));

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.unpause, ()));

        assertEq(uint8(vault.pauseLevel()), uint8(PauseLevel.Unpaused));

        supply.mint(lender1, 100e18);
        vm.startPrank(lender1);
        supply.approve(address(vault), 100e18);
        vault.deposit(100e18, lender1); // must succeed
        vm.stopPrank();
    }

    function test_partialPause_emitsEvent() external {
        vm.expectEmit(false, false, false, true);
        emit BaseVault.PauseLevelSet(PauseLevel.Unpaused, PauseLevel.Partial);

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.partialPause, ()));
    }

    function test_pause_revertsIfNotController() external {
        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.partialPause();

        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.completePause();

        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.unpause();
    }

    // ──────────────────────────────────────────────────────────────────────
    // 2F — Misc Controller Functions
    // ──────────────────────────────────────────────────────────────────────

    function _matureAndClose() internal {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vault.updateVaultState();

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.closeVault, ()));
    }

    function test_sweep_nonSupplyToken() external {
        _matureAndClose();
        uint256 amount = 500e18;
        extraToken.mint(address(vault), amount);
        address treasuryAddr = mockVaultController.treasury();

        vm.expectEmit(true, true, false, true);
        emit BaseVault.TokensSwept(address(extraToken), treasuryAddr, amount);

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.sweep, (address(extraToken))));

        assertEq(extraToken.balanceOf(treasuryAddr), amount);
        assertEq(extraToken.balanceOf(address(vault)), 0);
    }

    function test_sweep_revertsIfNothingToSweep() external {
        _matureAndClose();
        vm.prank(address(mockVaultController));
        vm.expectRevert(BaseVault.NothingToSweep.selector);
        vault.sweep(address(extraToken));
    }

    function test_sweep_revertsIfVaultActive() external {
        extraToken.mint(address(vault), 100e18);
        vm.prank(address(mockVaultController));
        vm.expectRevert(BaseVault.VaultNotClosed.selector);
        vault.sweep(address(extraToken));
    }

    function test_sweep_revertsIfNotController() external {
        extraToken.mint(address(vault), 100e18);
        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.sweep(address(extraToken));
    }

    function test_closeVault_inMatured() external {
        _depositAndLock(MIN_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.warp(vault.runtime().lockEndTime + 1);
        uint256 debt = vault.outstandingDebt();
        supply.mint(address(this), debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vault.updateVaultState(); // Matured

        vm.expectEmit(false, false, false, true);
        emit BaseVault.VaultClosed(VaultState.Matured);

        vm.prank(address(mockVaultController));
        mockVaultController.callVault(address(vault), abi.encodeCall(BaseVault.closeVault, ()));

        assertFalse(vault.runtime().isActive);
    }

    function test_closeVault_revertsInLock() external {
        _depositAndLock(MIN_CAP);

        vm.prank(address(mockVaultController));
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.closeVault();
    }

    function test_updateVaultState_permissionless() external {
        vm.warp(vault.runtime().openEndTime + 1);

        // Anyone can call updateVaultState.
        vm.prank(makeAddr("anyone"));
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
    }

    // ──────────────────────────────────────────────────────────────────────
    // 2G — claimRaisedFunds
    // ──────────────────────────────────────────────────────────────────────

    function test_claimRaisedFunds_inLock() external {
        _depositAndLock(MAX_CAP);

        uint256 raised = vault.runtime().totalRaised;
        uint256 interestBefore = vault.outstandingDebt(); // interest only at Lock
        address recipient = makeAddr("recipient");

        vm.expectEmit(false, false, false, true);
        emit BaseVault.RaisedFundsClaimed(raised);

        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(recipient);

        assertEq(supply.balanceOf(recipient), raised);
        assertTrue(vault.runtime().fundsWithdrawn);
        assertEq(vault.outstandingDebt(), interestBefore + raised);
    }

    function test_claimRaisedFunds_revertsIfAlreadyClaimed() external {
        _depositAndLock(MAX_CAP);

        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        vm.prank(address(mockVaultController));
        vm.expectRevert(BaseVault.AlreadyWithdrawn.selector);
        vault.claimRaisedFunds(address(this));
    }

    function test_claimRaisedFunds_revertsIfNotLock() external {
        // In Fundraising state (not yet locked).
        vm.prank(address(mockVaultController));
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.claimRaisedFunds(address(this));
    }

    function test_debt_afterClaimAndPartialRepay() external {
        _depositAndLock(MAX_CAP);

        uint256 interest = vault.outstandingDebt(); // interest only
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        uint256 totalDebt = vault.outstandingDebt(); // interest + principal
        assertEq(totalDebt, interest + MAX_CAP);

        uint256 partialRepay = 50_000e18;
        supply.mint(address(this), partialRepay);
        supply.approve(address(vault), partialRepay);
        vault.repay(partialRepay);

        assertEq(vault.outstandingDebt(), totalDebt - partialRepay);
    }

    function test_debt_ifFundsNotWithdrawn() external {
        _depositAndLock(MAX_CAP);

        // Debt is interest-only until claimRaisedFunds is called.
        uint256 expectedInterest = _computeInterest(MAX_CAP);
        assertEq(vault.outstandingDebt(), expectedInterest);
    }

    /// @dev Sending supply tokens directly to the vault must not reduce outstanding debt.
    ///      Debt is tracked via _runtime.totalDebt (a counter decremented only by repay()).
    ///      A direct transfer cannot fake a repayment or trigger a state transition.
    function test_directSupplyTransfer_doesNotRepayDebt() external {
        _depositAndLock(MAX_CAP);
        vm.prank(address(mockVaultController));
        vault.claimRaisedFunds(address(this));

        uint256 debtBefore = vault.outstandingDebt();

        // Donate supply tokens directly — not via repay().
        uint256 donation = 50_000e18;
        supply.mint(address(this), donation);
        supply.transfer(address(vault), donation);

        // Debt counter must be unchanged.
        assertEq(vault.outstandingDebt(), debtBefore);
        // Vault must remain in Lock — donation cannot trigger a state transition.
        assertEq(uint8(vault.runtime().state), uint8(VaultState.Lock));
    }
}
