// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseVault } from "../../src/BaseVault.sol";
import { VaultConfig, VaultRuntime, VaultState, PauseLevel } from "../../src/interfaces/IVaultTypes.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPSR } from "./mocks/MockPSR.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Minimal concrete vault — identical to TestVault in BaseVault.t.sol.
// Duplicated here because it is defined inside that test file and not importable.
// ──────────────────────────────────────────────────────────────────────────────

contract FuzzTestVault is BaseVault {
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
}

// ──────────────────────────────────────────────────────────────────────────────
// Minimal controller stub — identical to MockController in BaseVault.t.sol.
// ──────────────────────────────────────────────────────────────────────────────

contract FuzzMockController {
    address public protocolShareReserve;
    address public comptroller;

    constructor(
        address psr_,
        address comptroller_
    ) {
        protocolShareReserve = psr_;
        comptroller = comptroller_;
    }

    function callVault(
        address vault,
        bytes calldata data
    ) external returns (bytes memory) {
        (bool ok, bytes memory ret) = vault.call(data);
        require(ok, "FuzzMockController: vault call failed");
        return ret;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Fuzz + multi-lender redemption tests for BaseVault
// ──────────────────────────────────────────────────────────────────────────────

contract BaseVaultFuzzTest is Test {
    FuzzTestVault internal vault;
    FuzzMockController internal mockController;
    MockERC20 internal supply;
    MockPSR internal psr;

    address internal admin;
    address internal lender1;
    address internal lender2;
    address internal lender3;
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
        lender3 = makeAddr("lender3");
        proxyAdmin = makeAddr("proxyAdmin");

        supply = new MockERC20("Mock USDC", "mUSDC");
        psr = new MockPSR();

        address comptrollerAddr = makeAddr("comptroller");
        mockController = new FuzzMockController(address(psr), comptrollerAddr);

        _deployVault();
    }

    // ── Deployment
    // ───────────────────────────────────────────────────────

    function _deployVault() internal {
        FuzzTestVault impl = new FuzzTestVault();
        vault = FuzzTestVault(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    proxyAdmin,
                    abi.encodeCall(FuzzTestVault.initialize, (_buildConfig(), address(mockController)))
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
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
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

    /// @dev Full lifecycle: deposit, lock, claim, warp past lock, repay full debt, advance to Matured.
    ///      Deposits are performed by the provided lenders before calling this helper.
    function _fullLifecycleToMatured() internal {
        // Lock
        _warpToLock();

        // Claim raised funds
        vm.prank(address(mockController));
        vault.claimRaisedFunds(admin);

        // Warp past lock end
        vm.warp(vault.runtime().lockEndTime + 1);

        // Repay full debt
        uint256 debt = vault.outstandingDebt();
        supply.mint(admin, debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);

        // Advance to Matured
        vault.updateVaultState();
    }

    // ══════════════════════════════════════════════════════════════════════
    // Fuzz Tests
    // ══════════════════════════════════════════════════════════════════════

    // 1. testFuzz_deposit_anyAmount
    function testFuzz_deposit_anyAmount(
        uint256 amount
    ) external {
        amount = bound(amount, 1, MAX_CAP);

        uint256 expectedShares = vault.previewDeposit(amount);

        supply.mint(lender1, amount);
        vm.startPrank(lender1);
        supply.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, lender1);
        vm.stopPrank();

        assertEq(shares, expectedShares, "shares != previewDeposit");
        assertEq(vault.runtime().totalRaised, amount, "totalRaised mismatch");
        assertEq(supply.balanceOf(address(vault)), amount, "vault balance mismatch");
        assertEq(supply.balanceOf(lender1), 0, "lender balance should be 0");
    }

    // 2. testFuzz_deposit_twoLenders_sharesProRata
    function testFuzz_deposit_twoLenders_sharesProRata(
        uint256 a1,
        uint256 a2
    ) external {
        a1 = bound(a1, 1e18, MAX_CAP / 2);
        a2 = bound(a2, 1e18, MAX_CAP / 2);

        uint256 shares1 = _mintAndDeposit(lender1, a1);
        uint256 shares2 = _mintAndDeposit(lender2, a2);

        // During fundraising, shares are 1:1 with assets (totalAssets == totalRaised, no interest yet).
        // So shares should equal deposit amounts exactly.
        assertEq(shares1, a1, "lender1 shares != deposit amount");
        assertEq(shares2, a2, "lender2 shares != deposit amount");

        // Share ratio == deposit ratio (cross-multiply to avoid division-by-zero / rounding)
        assertEq(shares1 * a2, shares2 * a1, "share ratio != deposit ratio");

        assertEq(vault.runtime().totalRaised, a1 + a2, "totalRaised mismatch");
    }

    // 3. testFuzz_repay_partialAmounts
    function testFuzz_repay_partialAmounts(
        uint256 repayAmt
    ) external {
        _mintAndDeposit(lender1, MIN_CAP);
        _warpToLock();

        // Claim so totalDebt = interest + principal
        vm.prank(address(mockController));
        vault.claimRaisedFunds(admin);

        uint256 totalDebt = vault.outstandingDebt();
        repayAmt = bound(repayAmt, 1, totalDebt);

        supply.mint(admin, repayAmt);
        supply.approve(address(vault), repayAmt);
        vault.repay(repayAmt);

        assertEq(vault.outstandingDebt(), totalDebt - repayAmt, "outstanding debt mismatch after partial repay");
    }

    // 4. testFuzz_settlement_interestCalculation
    function testFuzz_settlement_interestCalculation(
        uint256 raised
    ) external {
        raised = bound(raised, MIN_CAP, MAX_CAP);

        _mintAndDeposit(lender1, raised);
        _warpToLock();

        uint256 expectedInterest = (raised * FIXED_APY * LOCK_DURATION) / (BPS * YEAR);
        // At Lock, totalDebt == interest (principal not yet claimed)
        assertEq(vault.outstandingDebt(), expectedInterest, "interest calculation mismatch");
    }

    // 5. testFuzz_settlement_protocolFee
    function testFuzz_settlement_protocolFee(
        uint256 raised
    ) external {
        raised = bound(raised, MIN_CAP, MAX_CAP);

        _mintAndDeposit(lender1, raised);

        // Lock
        _warpToLock();

        // Claim raised funds
        vm.prank(address(mockController));
        vault.claimRaisedFunds(admin);

        // Warp past lock end
        vm.warp(vault.runtime().lockEndTime + 1);

        // Repay full debt
        uint256 debt = vault.outstandingDebt();
        supply.mint(admin, debt);
        supply.approve(address(vault), debt);
        vault.repay(debt);

        // Advance to Matured (settlement happens here)
        vault.updateVaultState();

        uint256 interest = _computeInterest(raised);
        uint256 expectedFee = _computeProtocolFee(interest);
        uint256 totalOwed = raised + interest;
        uint256 expectedSettlement = totalOwed - expectedFee;

        assertEq(supply.balanceOf(address(psr)), expectedFee, "PSR balance != expected fee");
        assertEq(vault.runtime().settlementAmount, expectedSettlement, "settlementAmount mismatch");
    }

    // 6. testFuzz_redeem_inMatured_proRata
    function testFuzz_redeem_inMatured_proRata(
        uint256 deposit1,
        uint256 deposit2
    ) external {
        // Both deposits must sum to >= MIN_CAP for the vault to reach Lock (not Failed).
        deposit1 = bound(deposit1, MIN_CAP / 2, MAX_CAP / 2);
        deposit2 = bound(deposit2, MIN_CAP / 2, MAX_CAP / 2);

        _mintAndDeposit(lender1, deposit1);
        _mintAndDeposit(lender2, deposit2);

        _fullLifecycleToMatured();

        uint256 settlementAmount = vault.runtime().settlementAmount;
        uint256 totalShares = vault.totalSupply();

        uint256 shares1 = vault.balanceOf(lender1);
        uint256 shares2 = vault.balanceOf(lender2);

        // Lender1 redeems all
        vm.prank(lender1);
        uint256 assets1 = vault.redeem(shares1, lender1, lender1);

        // Lender2 redeems all
        vm.prank(lender2);
        uint256 assets2 = vault.redeem(shares2, lender2, lender2);

        // Pro-rata: each lender gets shares_i * settlementAmount / totalShares.
        // ERC-4626 rounds down per operation, so individual payouts may be up to 1 wei less.
        uint256 expected1 = (shares1 * settlementAmount) / totalShares;
        assertApproxEqAbs(assets1, expected1, 1, "lender1 pro-rata payout mismatch (1 wei rounding)");

        // Conservation: sum of payouts == settlementAmount (up to 1 wei rounding dust per redeem)
        uint256 totalWithdrawn = assets1 + assets2;
        assertApproxEqAbs(totalWithdrawn, settlementAmount, 2, "total withdrawn != settlementAmount (rounding)");

        // Vault supply token balance should be at most 1 wei dust
        assertLe(supply.balanceOf(address(vault)), 2, "vault dust should be <= 2 wei");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Multi-lender redemption tests (exact scenarios)
    // ══════════════════════════════════════════════════════════════════════

    // 7. test_redeem_threeLenders_matured_exactProRata
    function test_redeem_threeLenders_matured_exactProRata() external {
        uint256 d1 = 500_000e18;
        uint256 d2 = 300_000e18;
        uint256 d3 = 200_000e18;

        _mintAndDeposit(lender1, d1);
        _mintAndDeposit(lender2, d2);
        _mintAndDeposit(lender3, d3);

        _fullLifecycleToMatured();

        uint256 settlementAmount = vault.runtime().settlementAmount;
        uint256 totalShares = vault.totalSupply();

        uint256 shares1 = vault.balanceOf(lender1);
        uint256 shares2 = vault.balanceOf(lender2);
        uint256 shares3 = vault.balanceOf(lender3);

        // Compute expected payouts using the same sequential math the vault uses.
        // Lender1 redeems first: assets = shares1 * totalAssets / totalSupply (round down)
        // ERC-4626 rounds down, so individual payouts may be up to 1 wei less than ideal.
        uint256 expectedAssets1 = (shares1 * settlementAmount) / totalShares;

        vm.prank(lender1);
        uint256 assets1 = vault.redeem(shares1, lender1, lender1);
        assertApproxEqAbs(assets1, expectedAssets1, 1, "lender1 payout mismatch (1 wei rounding)");

        // After lender1: totalAssets and totalSupply have decreased
        uint256 settlementAfter1 = vault.runtime().settlementAmount;
        uint256 totalSharesAfter1 = vault.totalSupply();
        uint256 expectedAssets2 = (shares2 * settlementAfter1) / totalSharesAfter1;

        vm.prank(lender2);
        uint256 assets2 = vault.redeem(shares2, lender2, lender2);
        assertEq(assets2, expectedAssets2, "lender2 payout mismatch");

        // Lender3 is last — gets all remaining
        uint256 settlementAfter2 = vault.runtime().settlementAmount;

        vm.prank(lender3);
        uint256 assets3 = vault.redeem(shares3, lender3, lender3);
        // OZ ERC-4626 virtual shares may cause 1 wei rounding even for the last redeemer.
        assertApproxEqAbs(assets3, settlementAfter2, 1, "lender3 should get remaining (1 wei rounding)");

        // Conservation checks: ERC-4626 rounds down each redeem, so up to 1 wei dust per operation.
        uint256 totalWithdrawn = assets1 + assets2 + assets3;
        assertApproxEqAbs(totalWithdrawn, settlementAmount, 3, "total withdrawn != settlementAmount (rounding)");
        assertEq(vault.totalSupply(), 0, "totalSupply should be 0");
        assertLe(supply.balanceOf(address(vault)), 3, "vault dust should be <= 3 wei");
    }

    // 8. test_redeem_allButOne_thenLast
    function test_redeem_allButOne_thenLast() external {
        uint256 d1 = 400_000e18;
        uint256 d2 = 350_000e18;
        uint256 d3 = 250_000e18;

        _mintAndDeposit(lender1, d1);
        _mintAndDeposit(lender2, d2);
        _mintAndDeposit(lender3, d3);

        _fullLifecycleToMatured();

        uint256 settlementAmount = vault.runtime().settlementAmount;

        uint256 shares1 = vault.balanceOf(lender1);
        uint256 shares2 = vault.balanceOf(lender2);
        uint256 shares3 = vault.balanceOf(lender3);

        // First two redeem
        vm.prank(lender1);
        uint256 assets1 = vault.redeem(shares1, lender1, lender1);

        vm.prank(lender2);
        uint256 assets2 = vault.redeem(shares2, lender2, lender2);

        // Last lender gets the exact remaining settlementAmount
        uint256 remainingSettlement = vault.runtime().settlementAmount;

        vm.prank(lender3);
        uint256 assets3 = vault.redeem(shares3, lender3, lender3);

        // Last lender gets whatever settlementAmount remains. ERC-4626 with OZ virtual shares
        // may round down by 1 wei even for the last redeemer, so allow 1 wei tolerance.
        assertApproxEqAbs(
            assets3, remainingSettlement, 1, "last lender should get remaining settlement (1 wei rounding)"
        );

        // Conservation: total withdrawn ≈ settlementAmount (up to rounding dust)
        uint256 totalWithdrawn = assets1 + assets2 + assets3;
        assertApproxEqAbs(totalWithdrawn, settlementAmount, 3, "total withdrawn != settlementAmount (rounding)");
        assertLe(supply.balanceOf(address(vault)), 3, "vault dust should be <= 3 wei");
        assertEq(vault.totalSupply(), 0, "totalSupply should be 0");
    }

    // 9. test_redeem_singleWei_matured
    function test_redeem_singleWei_matured() external {
        // Deposit 1 wei. Since totalRaised starts at 0 and totalSupply starts at 0,
        // the first deposit gets 1:1 shares. 1 wei deposit => 1 wei share.
        supply.mint(lender1, 1);
        vm.startPrank(lender1);
        supply.approve(address(vault), 1);
        uint256 shares = vault.deposit(1, lender1);
        vm.stopPrank();

        // 1 wei is below MIN_CAP so vault will go to Failed (not Lock).
        // In Failed state, settlementAmount == totalRaised == 1 wei.
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed), "should be Failed");

        if (shares > 0) {
            vm.prank(lender1);
            uint256 assets = vault.redeem(shares, lender1, lender1);
            assertEq(assets, 1, "should redeem 1 wei");
            assertEq(supply.balanceOf(lender1), 1, "lender should have 1 wei back");
        }
    }

    // 10. test_withdraw_totalConservation_matured
    function test_withdraw_totalConservation_matured() external {
        uint256 d1 = 600_000e18;
        uint256 d2 = 400_000e18;

        _mintAndDeposit(lender1, d1);
        _mintAndDeposit(lender2, d2);

        _fullLifecycleToMatured();

        uint256 settlementAmount = vault.runtime().settlementAmount;

        // Both lenders withdraw their full maxWithdraw amount
        uint256 maxW1 = vault.maxWithdraw(lender1);
        vm.prank(lender1);
        vault.withdraw(maxW1, lender1, lender1);

        uint256 maxW2 = vault.maxWithdraw(lender2);
        vm.prank(lender2);
        vault.withdraw(maxW2, lender2, lender2);

        uint256 totalWithdrawn = supply.balanceOf(lender1) + supply.balanceOf(lender2);

        // ERC-4626 rounds down per-withdrawal, so total withdrawn may be up to 1 wei less per lender.
        assertApproxEqAbs(totalWithdrawn, settlementAmount, 2, "total withdrawn != settlementAmount (rounding)");
        assertLe(supply.balanceOf(address(vault)), 2, "vault dust should be <= 2 wei");
        assertEq(vault.totalSupply(), 0, "totalSupply should be 0");
    }
}
