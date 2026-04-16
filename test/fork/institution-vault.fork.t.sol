// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {
    AccessControlManager
} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlManager.sol";
import { ChainlinkOracle } from "@venusprotocol/oracle/contracts/oracles/ChainlinkOracle.sol";
import { ResilientOracle } from "@venusprotocol/oracle/contracts/ResilientOracle.sol";

import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { LiquidationAdapter } from "../../src/institutional-vault/LiquidationAdapter.sol";
import { InstitutionPositionToken } from "../../src/institutional-vault/InstitutionPositionToken.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { Addresses } from "../../src/lib/Addresses.sol";

import { VaultConfig, VaultRuntime, VaultState, PauseLevel } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalRuntime, LiquidationType } from "../../src/interfaces/IInstitutionalVaultTypes.sol";

import { MockERC20 } from "../institutional-vault/mocks/MockERC20.sol";
import { VaultTestBase } from "../institutional-vault/VaultTestBase.t.sol";

/**
 * @title InstitutionalLoanVaultForkTest
 */
contract InstitutionalLoanVaultForkTest is VaultTestBase {
    // ── Fork state
    // ────────────────────────────────────────────────────────
    uint256 bscFork;
    Addresses.NetworkAddresses internal addrs;

    // ── Actors
    // ────────────────────────────────────────────────────────────
    address internal lender3;
    address internal timelock;

    // ── Core contracts under test
    // ───────────────────────
    address internal psrAddress;

    // ──────────────────────────────────────────────────────────────────────
    // Setup
    // ──────────────────────────────────────────────────────────────────────

    function setUp() external {
        string memory forkEnabled = vm.envOr("FORK_ENABLED", string("false"));
        if (keccak256(bytes(forkEnabled)) != keccak256(bytes("true"))) {
            vm.skip(true);
            return;
        }

        bscFork = vm.createSelectFork("bsc_mainnet", 85_834_131);
        addrs = Addresses.getByChainId(block.chainid);
        _makeActors();
        lender3 = makeAddr("lender3");
        timelock = addrs.normalTimelock;
        _deployForkTokensAndOracle();
        _deployForkSystem();
        _createVault();
    }

    function _deployForkTokensAndOracle() internal {
        // Deploy fresh Position Token
        posToken = new InstitutionPositionToken();
        psrAddress = addrs.protocolShareReserve;

        // Reuse base token deploy helper.
        _deployTokens();

        // Deploy ChainlinkOracle for price control via setDirectPrice.
        ChainlinkOracle oracleImpl = new ChainlinkOracle();
        oracle = ChainlinkOracle(
            address(
                new TransparentUpgradeableProxy(
                    address(oracleImpl),
                    makeAddr("oracleProxyAdmin"),
                    abi.encodeCall(ChainlinkOracle.initialize, (addrs.accessControlManager))
                )
            )
        );
    }

    function _deployForkSystem() internal {
        // Deploy new vault implementation and proxy-backed core contracts
        InstitutionalLoanVault vaultImpl = new InstitutionalLoanVault();
        InstitutionalVaultController controllerImpl = new InstitutionalVaultController();
        LiquidationAdapter adapterImpl = new LiquidationAdapter();
        address proxyAdmin = makeAddr("proxyAdmin");
        TransparentUpgradeableProxy controllerProxy =
            new TransparentUpgradeableProxy(address(controllerImpl), proxyAdmin, bytes(""));
        TransparentUpgradeableProxy adapterProxy =
            new TransparentUpgradeableProxy(address(adapterImpl), proxyAdmin, bytes(""));
        controller = InstitutionalVaultController(address(controllerProxy));
        adapter = LiquidationAdapter(address(adapterProxy));

        // Grant ACM permissions via the timelock (DEFAULT_ADMIN_ROLE holder)
        _grantACMPermissions();

        // Configure ResilientOracle to route our tokens through our ChainlinkOracle
        _configureResilientOracle();

        // Set initial oracle prices ($1 each)
        oracle.setDirectPrice(address(supply), 1e18);
        oracle.setDirectPrice(address(collateral), 1e18);

        // Initialize adapter/controller proxies as in InitializeSystem script
        adapter.initialize(address(controller), PROTOCOL_LIQ_SHARE, CLOSE_FACTOR, addrs.accessControlManager);
        controller.initialize(
            address(vaultImpl),
            addrs.resilientOracle,
            psrAddress,
            addrs.unitroller,
            addrs.treasury,
            address(posToken),
            addrs.accessControlManager
        );

        // Wire adapter via setter (no longer part of initialize)
        controller.setLiquidationAdapter(address(adapter));

        // Transfer position token ownership to controller (Ownable2Step)
        posToken.transferOwnership(address(controller));
        // accept the position token ownership
        controller.acceptPositionTokenOwnership();

        // Register vault implementation on the controller
        controller.setVaultImplementation(address(vaultImpl));
    }

    // ──────────────────────────────────────────────────────────────────────
    // ACM permission grants (impersonate timelock — DEFAULT_ADMIN_ROLE holder)
    // ──────────────────────────────────────────────────────────────────────

    function _grantACMPermissions() internal {
        acm = AccessControlManager(addrs.accessControlManager);
        vm.startPrank(timelock);
        _grantAllPermissions();
        acm.giveCallPermission(address(0), "setDirectPrice(address,uint256)", address(this));
        acm.giveCallPermission(address(0), "setTokenConfig(TokenConfig)", timelock);
        vm.stopPrank();
    }

    /// @dev Configures the deployed ResilientOracle to route our MockERC20 tokens
    ///      through our freshly deployed ChainlinkOracle (main only, no pivot/fallback).
    function _configureResilientOracle() internal {
        ResilientOracle resilientOracle = ResilientOracle(addrs.resilientOracle);

        vm.startPrank(timelock);

        resilientOracle.setTokenConfig(
            ResilientOracle.TokenConfig({
                asset: address(supply),
                oracles: [address(oracle), address(0), address(0)],
                enableFlagsForOracles: [true, false, false],
                cachingEnabled: false
            })
        );

        resilientOracle.setTokenConfig(
            ResilientOracle.TokenConfig({
                asset: address(collateral),
                oracles: [address(oracle), address(0), address(0)],
                enableFlagsForOracles: [true, false, false],
                cachingEnabled: false
            })
        );

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Lifecycle helpers
    // ──────────────────────────────────────────────────────────────────────

    function _supplyAs(
        address lender,
        uint256 amount
    ) internal {
        supply.mint(lender, amount);
        vm.startPrank(lender);
        supply.approve(address(vault), amount);
        vault.deposit(amount, lender);
        vm.stopPrank();
    }

    function _topUpCollateralAndLock() internal {
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
    }

    function _claimFunds() internal {
        vm.prank(institution);
        vault.claimRaisedFunds();
    }

    function _warpPastLock() internal {
        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState();
    }

    function _repayAll() internal {
        uint256 debt = vault.outstandingDebt();
        supply.mint(institution, debt);
        vm.startPrank(institution);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();
    }

    function _repayAmount(
        address payer,
        uint256 amount
    ) internal {
        supply.mint(payer, amount);
        vm.startPrank(payer);
        supply.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();
    }

    function _whitelistLiquidator() internal {
        adapter.setLiquidatorWhitelist(liquidator, true);
    }

    function _whitelistSettler() internal {
        adapter.setSettlerWhitelist(settler, true);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 2. CANONICAL LIFECYCLE (HAPPY PATH)
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_happyPath_fullLifecycle() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        _claimFunds();
        _warpPastLock();

        assertEq(uint8(vault.state()), uint8(VaultState.PendingSettlement));

        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vault.withdrawCollateral(totalCol);
        assertEq(collateral.balanceOf(institution), IDEAL_COLLATERAL_AMOUNT);

        vm.expectEmit(address(vault));
        emit BaseVault.VaultClosed(VaultState.Matured);
        controller.closeVault(address(vault));
        assertEq(uint8(vault.runtime().state), uint8(VaultState.Closed));
    }

    function test_fork_happyPath_multiSupplier() external {
        _openVault();

        uint256 d1 = 300_000e18;
        uint256 d2 = 200_000e18;
        uint256 d3 = 500_000e18;
        _supplyAs(lender1, d1);
        _supplyAs(lender2, d2);
        _supplyAs(lender3, d3);

        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();
        _repayAll();
        vault.updateVaultState();

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        uint256 settlement = MAX_BORROW_CAP + interest - protocolFee;

        vm.startPrank(lender1);
        vault.redeem(vault.balanceOf(lender1), lender1, lender1);
        vm.stopPrank();
        vm.startPrank(lender2);
        vault.redeem(vault.balanceOf(lender2), lender2, lender2);
        vm.stopPrank();
        vm.startPrank(lender3);
        vault.redeem(vault.balanceOf(lender3), lender3, lender3);
        vm.stopPrank();

        assertApproxEqAbs(supply.balanceOf(lender1), (settlement * d1) / MAX_BORROW_CAP, 2);
        assertApproxEqAbs(supply.balanceOf(lender2), (settlement * d2) / MAX_BORROW_CAP, 2);
        assertApproxEqAbs(supply.balanceOf(lender3), (settlement * d3) / MAX_BORROW_CAP, 2);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 3. FAILURE PATHS
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_failPath_insufficientRaise() external {
        _openVault();
        _supplyAs(lender1, 100_000e18);

        vm.warp(vault.runtime().openEndTime + 1);
        vm.expectEmit(true, true, false, false, address(vault));
        emit BaseVault.StateTransition(VaultState.Fundraising, VaultState.Failed, 0);
        vm.expectEmit(address(vault));
        emit InstitutionalLoanVault.VaultFailed(100_000e18, MIN_BORROW_CAP);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertFalse(vault.institutionalRuntime().institutionDefaulted);

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vault.withdrawCollateral(totalCol);
        assertEq(collateral.balanceOf(institution), MARGIN_AMOUNT);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);
        assertEq(supply.balanceOf(lender1), 100_000e18);
    }

    function test_fork_failPath_institutionDefault_marginConfiscated() external {
        _openVault();

        uint256 d1 = 300_000e18;
        uint256 d2 = 200_000e18;
        _supplyAs(lender1, d1);
        _supplyAs(lender2, d2);

        vm.warp(vault.runtime().openEndTime + 1);
        vm.expectEmit(true, true, false, false, address(vault));
        emit BaseVault.StateTransition(VaultState.Fundraising, VaultState.Failed, 0);
        vm.expectEmit(address(vault));
        emit InstitutionalLoanVault.MarginConfiscated(MARGIN_AMOUNT);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertTrue(vault.institutionalRuntime().institutionDefaulted);

        uint256 confiscated = vault.institutionalRuntime().confiscatedMarginRemaining;
        uint256 totalRaised = vault.runtime().totalRaised;

        uint256 shares1 = vault.balanceOf(lender1);
        vm.expectEmit(true, false, false, false, address(vault));
        emit InstitutionalLoanVault.MarginCompensationClaimed(lender1, 0);
        vm.prank(lender1);
        vault.redeem(shares1, lender1, lender1);

        assertEq(supply.balanceOf(lender1), d1);
        assertApproxEqAbs(collateral.balanceOf(lender1), (confiscated * d1) / totalRaised, 1); // lender will receive
        // the confiscated margin proportionally to their shares

        uint256 shares2 = vault.balanceOf(lender2);
        vm.expectEmit(true, false, false, false, address(vault));
        emit InstitutionalLoanVault.MarginCompensationClaimed(lender2, 0);
        vm.prank(lender2);
        vault.redeem(shares2, lender2, lender2);

        assertEq(supply.balanceOf(lender2), d2);
        assertApproxEqAbs(collateral.balanceOf(lender2), (confiscated * d2) / totalRaised, 1);

        assertApproxEqAbs(vault.institutionalRuntime().confiscatedMarginRemaining, 0, 1);

        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vm.prank(institution);
        vault.withdrawCollateral(1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 4. BORROW & REPAYMENT VARIANTS
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_borrowFlow_normal() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        _claimFunds();
        assertEq(supply.balanceOf(institution), MAX_BORROW_CAP);

        _warpPastLock();
        _repayAll();
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vault.withdrawCollateral(totalCol);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);

        controller.closeVault(address(vault));
    }

    function test_fork_borrowFlow_excessCollateralWithdrawal() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);

        uint256 extraCollateral = 200_000e18;
        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT + extraCollateral;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        _claimFunds();

        uint256 minRequired = vault.institutionalRuntime().minimumCollateralRequired;
        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        uint256 withdrawable = totalCol - minRequired;
        assertEq(withdrawable, extraCollateral);

        vm.prank(institution);
        vault.withdrawCollateral(withdrawable);

        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 5. LIQUIDATION FLOWS
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_liquidation_healthFactorRecovery() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        (, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(shortfall, 0);

        uint256 topUp = 600_000e18;
        collateral.mint(institution, topUp);
        vm.startPrank(institution);
        collateral.approve(address(vault), topUp);
        vault.depositCollateral(topUp);
        vm.stopPrank();

        (uint256 liquidity, uint256 shortfallAfter) = vault.getVaultLiquidity();
        assertEq(shortfallAfter, 0, "shortfall should be zero after top-up");
        assertGt(liquidity, 0, "should have positive liquidity after top-up");

        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    function test_fork_liquidation_standardHF() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 debt = vault.outstandingDebt();
        uint256 liqRepay = 50_000e18;
        uint256 expectedSeize = vault.calculateSeizeAmount(liqRepay, LiquidationType.HF_BASED);

        supply.mint(liquidator, liqRepay);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), liqRepay);
        vm.expectEmit(true, false, false, true, address(vault));
        emit InstitutionalLoanVault.LiquidationExecuted(address(adapter), liqRepay, expectedSeize);
        adapter.liquidate(address(vault), liqRepay);
        vm.stopPrank();

        // LiquidationAdapter splits seized collateral: caller receives (totalSeized - protocolAmount).
        uint256 li = vault.riskConfig().liquidationIncentive;
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / li;
        uint256 incentiveAmount = expectedSeize - repayEquivalent;
        uint256 protocolAmount = (incentiveAmount * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 callerAmount = expectedSeize - protocolAmount;

        assertEq(collateral.balanceOf(liquidator), callerAmount);
        assertApproxEqAbs(adapter.protocolShareAccrued(address(collateral)), protocolAmount, 1);
        assertApproxEqAbs(collateral.balanceOf(address(adapter)), protocolAmount, 1);
        assertEq(vault.outstandingDebt(), debt - liqRepay);

        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    function test_fork_liquidation_partialMultipleRounds() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 debtBefore = vault.outstandingDebt();
        uint256 maxRepay1 = (debtBefore * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, maxRepay1);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), maxRepay1);
        adapter.liquidate(address(vault), maxRepay1);
        vm.stopPrank();

        uint256 debtAfter1 = vault.outstandingDebt();
        assertEq(debtAfter1, debtBefore - maxRepay1);

        (, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(shortfall, 0);
        uint256 maxRepay2 = (debtAfter1 * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, maxRepay2);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), maxRepay2);
        adapter.liquidate(address(vault), maxRepay2);
        vm.stopPrank();

        assertEq(vault.outstandingDebt(), debtAfter1 - maxRepay2);

        assertLt(vault.getCollateralValueUSD(), vault.getDebtValueUSD());
        assertGt(vault.outstandingDebt(), 0);

        uint256 remainingDebt = vault.outstandingDebt();
        uint256 totalInterest = _computeInterest(MAX_BORROW_CAP);
        uint256 badDebtCoverage = remainingDebt - totalInterest;
        supply.mint(address(this), badDebtCoverage);
        supply.approve(address(vault), badDebtCoverage);
        vault.repayBadDebt(badDebtCoverage);
        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));
    }

    function test_fork_liquidation_partialMultipleRounds_repayWithInterest() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 debtBefore = vault.outstandingDebt();
        uint256 maxRepay1 = (debtBefore * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, maxRepay1);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), maxRepay1);
        adapter.liquidate(address(vault), maxRepay1);
        vm.stopPrank();

        uint256 debtAfter1 = vault.outstandingDebt();
        assertEq(debtAfter1, debtBefore - maxRepay1);

        (, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(shortfall, 0);
        uint256 maxRepay2 = (debtAfter1 * CLOSE_FACTOR) / MANTISSA_ONE;

        supply.mint(liquidator, maxRepay2);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), maxRepay2);
        adapter.liquidate(address(vault), maxRepay2);
        vm.stopPrank();

        assertEq(vault.outstandingDebt(), debtAfter1 - maxRepay2);

        assertLt(vault.getCollateralValueUSD(), vault.getDebtValueUSD());
        assertGt(vault.outstandingDebt(), 0);

        // Repay full remaining debt (principal + interest) as bad debt
        uint256 remainingDebt = vault.outstandingDebt();
        supply.mint(address(this), remainingDebt);
        supply.approve(address(vault), remainingDebt);
        vault.repayBadDebt(remainingDebt);
        assertEq(vault.outstandingDebt(), 0);
        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));
    }

    function test_fork_liquidation_overduePartialRepay() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _warpPastLock();

        uint256 partialRepay = 200_000e18;
        _repayAmount(institution, partialRepay);

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        adapter.setCloseFactor(1e18);
        _whitelistSettler();

        uint256 debt = vault.outstandingDebt();
        uint256 expectedSeize = vault.calculateSeizeAmount(debt, LiquidationType.DEADLINE);
        supply.mint(settler, debt);
        vm.startPrank(settler);
        supply.approve(address(adapter), debt);
        vm.expectEmit(true, false, false, true, address(vault));
        emit InstitutionalLoanVault.OverdueLiquidationExecuted(address(adapter), debt, expectedSeize);
        adapter.liquidateOverdueVault(address(vault), debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        assertApproxEqAbs(supply.balanceOf(psrAddress), protocolFee, 1);

        uint256 shares = vault.balanceOf(lender1);
        vm.startPrank(lender1);
        uint256 balBefore = supply.balanceOf(lender1);
        uint256 expectedAssets = vault.previewRedeem(shares);
        vault.redeem(shares, lender1, lender1);
        vm.stopPrank();
        assertEq(supply.balanceOf(lender1), balBefore + expectedAssets);
    }

    function test_fork_liquidation_overdueNoRepay() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vm.expectEmit(true, true, false, false, address(vault));
        emit BaseVault.StateTransition(VaultState.PendingSettlement, VaultState.SettlementDeadlineExceeded, 0);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        adapter.setCloseFactor(1e18);
        _whitelistSettler();

        uint256 debt = vault.outstandingDebt();
        uint256 expectedSeize = vault.calculateSeizeAmount(debt, LiquidationType.DEADLINE);
        supply.mint(settler, debt);
        vm.startPrank(settler);
        supply.approve(address(adapter), debt);
        vm.expectEmit(true, false, false, true, address(vault));
        emit InstitutionalLoanVault.OverdueLiquidationExecuted(address(adapter), debt, expectedSeize);
        adapter.liquidateOverdueVault(address(vault), debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        // LiquidationAdapter splits totalSeized into caller vs protocol split.
        uint256 li = vault.riskConfig().latePenaltyRate;
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / li;
        uint256 incentiveAmount = expectedSeize - repayEquivalent;
        uint256 protocolAmount = (incentiveAmount * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 callerAmount = expectedSeize - protocolAmount;
        assertEq(collateral.balanceOf(settler), callerAmount);

        uint256 shares = vault.balanceOf(lender1);
        vm.startPrank(lender1);
        uint256 balBefore = supply.balanceOf(lender1);
        uint256 expectedAssets = vault.previewRedeem(shares);
        vault.redeem(shares, lender1, lender1);
        vm.stopPrank();
        assertEq(supply.balanceOf(lender1), balBefore + expectedAssets);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 6. SETTLEMENT EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_settlement_deadlineExceeded_fullRepay() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
    }

    function test_fork_settlement_partialRepay_thenDeadline_thenLiquidation() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _warpPastLock();

        uint256 partialRepay = 300_000e18;
        _repayAmount(institution, partialRepay);

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        adapter.setCloseFactor(1e18);
        _whitelistSettler();

        uint256 debt = vault.outstandingDebt();
        supply.mint(settler, debt);
        vm.startPrank(settler);
        supply.approve(address(adapter), debt);
        adapter.liquidateOverdueVault(address(vault), debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));
    }

    function test_fork_settlement_institutionNeverBorrows() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        assertEq(vault.outstandingDebt(), interest);

        _warpPastLock();

        _repayAmount(institution, interest);

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 protocolFee = _computeProtocolFee(interest);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 7. FUNDRAISING EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_fundraising_maxCapExactlyHit_nextReverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);

        assertEq(vault.runtime().totalRaised, MAX_BORROW_CAP);

        supply.mint(lender2, 1e18);
        vm.startPrank(lender2);
        supply.approve(address(vault), 1e18);
        vm.expectRevert(BaseVault.ExceedsMaxCap.selector);
        vault.deposit(1e18, lender2);
        vm.stopPrank();
    }

    function test_fork_fundraising_claimAtLockEndBoundary_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        uint256 lockEnd = vault.runtime().lockEndTime;
        vm.warp(lockEnd);

        vm.expectRevert(BaseVault.InvalidState.selector);
        vm.prank(institution);
        vault.claimRaisedFunds();
    }

    function test_fork_fundraising_claimBoundary_beforeAndAtLockEnd() external {
        // t = lockEnd - 1 -> claim succeeds.
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        vm.warp(vault.runtime().lockEndTime - 1);
        vm.prank(institution);
        vault.claimRaisedFunds();
        assertTrue(vault.runtime().fundsWithdrawn);
        assertEq(vault.outstandingDebt(), MAX_BORROW_CAP + _computeInterest(MAX_BORROW_CAP));

        // Fresh vault for t = lockEnd revert case and rollback checks.
        _createVault();
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        uint256 debtBefore = vault.outstandingDebt();
        bool withdrawnBefore = vault.runtime().fundsWithdrawn;
        vm.warp(vault.runtime().lockEndTime);

        vm.prank(institution);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.claimRaisedFunds();

        // Reverting tx rolls back state transition and all mutations.
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));
        assertEq(vault.outstandingDebt(), debtBefore);
        assertEq(vault.runtime().fundsWithdrawn, withdrawnBefore);
    }

    function test_fork_settlementDeadline_exactBoundary_transition() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();

        uint256 repayAmt = 10_000e18;
        _repayAmount(institution, repayAmt);

        // Exact boundary must remain PendingSettlement (strict > check in state machine).
        vm.warp(vault.runtime().settlementDeadline);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.PendingSettlement));

        _whitelistSettler();
        supply.mint(settler, repayAmt);
        vm.startPrank(settler);
        supply.approve(address(adapter), repayAmt);
        vm.expectRevert(InstitutionalLoanVault.InvalidStateForOverdueLiquidation.selector);
        adapter.liquidateOverdueVault(address(vault), repayAmt);
        vm.stopPrank();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        uint256 debtBefore = vault.outstandingDebt();
        supply.mint(settler, repayAmt);
        vm.startPrank(settler);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidateOverdueVault(address(vault), repayAmt);
        vm.stopPrank();
        assertEq(vault.outstandingDebt(), debtBefore - repayAmt);
    }

    function test_fork_riskUpdate_lt_flipHealth_midLifecycle() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        (, uint256 shortfallBefore) = vault.getVaultLiquidity();
        assertEq(shortfallBefore, 0);

        // update liquidation threshold mid lifecycle
        controller.setLiquidationThreshold(address(vault), 0.7e18);
        (, uint256 shortfallAfter) = vault.getVaultLiquidity();
        assertGt(shortfallAfter, 0);

        _whitelistLiquidator();
        uint256 repayAmt = 50_000e18;
        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt); // able to liquidate
        vm.stopPrank();
    }

    function test_fork_riskUpdate_li_changesSeize_midLifecycle() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        uint256 repayAmt = 50_000e18;

        uint256 seizeBefore = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        controller.setLiquidationIncentive(address(vault), 1.2e18);
        uint256 seizeAfter = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        assertGt(seizeAfter, seizeBefore);

        _whitelistLiquidator();
        uint256 collateralBefore = vault.institutionalRuntime().totalCollateralDeposited;
        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 seized = collateralBefore - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(seized, seizeAfter);
        assertEq(seized, collateral.balanceOf(liquidator) + adapter.protocolShareAccrued(address(collateral)));
    }

    function test_fork_riskUpdate_latePenalty_appliesToOverdueLiquidation() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        uint256 repayAmt = 50_000e18;
        uint256 seizeBefore = vault.calculateSeizeAmount(repayAmt, LiquidationType.DEADLINE);
        controller.setLatePenaltyRate(address(vault), 1.25e18);
        uint256 seizeAfter = vault.calculateSeizeAmount(repayAmt, LiquidationType.DEADLINE);
        assertGt(seizeAfter, seizeBefore);

        _whitelistSettler();
        uint256 collateralBefore = vault.institutionalRuntime().totalCollateralDeposited;
        uint256 debtBefore = vault.outstandingDebt();
        supply.mint(settler, repayAmt);
        vm.startPrank(settler);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidateOverdueVault(address(vault), repayAmt);
        vm.stopPrank();

        uint256 seized = collateralBefore - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(seized, seizeAfter);
        assertEq(seized, collateral.balanceOf(settler) + adapter.protocolShareAccrued(address(collateral)));
        assertEq(vault.outstandingDebt(), debtBefore - repayAmt);
    }

    function test_fork_partialLiquidation_multiStep_withCloseFactorUpdate() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAboveOldCF = (debt * 60) / 100; // above default CF=50%

        supply.mint(liquidator, repayAboveOldCF);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAboveOldCF);
        vm.expectRevert(InstitutionalLoanVault.ExceedsCloseFactor.selector);
        adapter.liquidate(address(vault), repayAboveOldCF);
        vm.stopPrank();

        adapter.setCloseFactor(0.8e18);
        uint256 debtBefore = vault.outstandingDebt();
        supply.mint(liquidator, repayAboveOldCF);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAboveOldCF);
        adapter.liquidate(address(vault), repayAboveOldCF);
        vm.stopPrank();
        assertEq(vault.outstandingDebt(), debtBefore - repayAboveOldCF);
    }

    function test_fork_positionTransfer_revokeBeforeTransfer_blocksMove() external {
        _openVault();
        address newHolder = makeAddr("newHolder");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        controller.approvePositionTransfer(address(vault));
        controller.revokePositionTransfer(address(vault));

        vm.prank(institution);
        vm.expectRevert();
        posToken.safeTransferFrom(institution, newHolder, tokenId);
    }

    function test_fork_positionTransfer_pendingSettlement_newHolderControlsRepayAndWithdraw() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();

        assertEq(uint8(vault.state()), uint8(VaultState.PendingSettlement));

        address newHolder = makeAddr("newHolder");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        controller.approvePositionTransfer(address(vault));
        vm.prank(institution);
        posToken.safeTransferFrom(institution, newHolder, tokenId);

        vm.prank(institution);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.withdrawCollateral(1);

        uint256 debt = vault.outstandingDebt();
        supply.mint(newHolder, debt);
        vm.startPrank(newHolder);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(newHolder);
        vault.withdrawCollateral(totalCol);
        assertEq(collateral.balanceOf(newHolder), IDEAL_COLLATERAL_AMOUNT);
    }

    function test_fork_positionTransfer_newHolderCompletesCycle() external {
        _openVault();

        controller.approvePositionTransfer(address(vault));
        address newHolder = makeAddr("newHolder");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        vm.prank(institution);
        posToken.safeTransferFrom(institution, newHolder, tokenId);
        assertEq(posToken.ownerOf(tokenId), newHolder);

        _supplyAs(lender1, MAX_BORROW_CAP);

        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(newHolder, remaining);
        vm.startPrank(newHolder);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        vm.prank(newHolder);
        vault.claimRaisedFunds();
        assertEq(supply.balanceOf(newHolder), MAX_BORROW_CAP);

        vm.warp(vault.runtime().lockEndTime + 1);
        vault.updateVaultState();

        uint256 debt = vault.outstandingDebt();
        uint256 interestOwed = debt - MAX_BORROW_CAP;
        supply.mint(newHolder, interestOwed);
        vm.startPrank(newHolder);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(newHolder);
        vault.withdrawCollateral(totalCol);
        assertEq(collateral.balanceOf(newHolder), IDEAL_COLLATERAL_AMOUNT);
        assertEq(collateral.balanceOf(institution), 0);
    }

    function test_fork_pause_unpause_completeCycle() external {
        _openVault();

        controller.partialPauseVault(address(vault));

        supply.mint(lender1, MAX_BORROW_CAP);
        vm.startPrank(lender1);
        supply.approve(address(vault), MAX_BORROW_CAP);
        vm.expectRevert(BaseVault.PartiallyPaused.selector);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        controller.unpauseVault(address(vault));

        vm.startPrank(lender1);
        vault.deposit(MAX_BORROW_CAP, lender1);
        vm.stopPrank();

        assertEq(vault.runtime().totalRaised, MAX_BORROW_CAP);

        uint256 remaining = IDEAL_COLLATERAL_AMOUNT - MARGIN_AMOUNT;
        collateral.mint(institution, remaining);
        vm.startPrank(institution);
        collateral.approve(address(vault), remaining);
        vault.depositCollateral(remaining);
        vm.stopPrank();
        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        _claimFunds();
        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);
        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);
        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);
    }

    function test_fork_fundraising_lenderEarlyRedeem_reverts() external {
        _openVault();
        _supplyAs(lender1, 100e18); // mint shares while the vault is in Fundraising

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.redeem(shares, lender1, lender1);

        vm.prank(lender1);
        vm.expectRevert(BaseVault.InvalidState.selector);
        vault.withdraw(1e18, lender1, lender1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 8. COLLATERAL & LIQUIDATION EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_collateral_overSeizureProtection() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.1e18);
        _whitelistLiquidator();

        uint256 debt = vault.outstandingDebt();
        uint256 maxRepay = (debt * CLOSE_FACTOR) / MANTISSA_ONE;

        uint256 seizePreview = vault.calculateSeizeAmount(maxRepay, LiquidationType.HF_BASED);
        uint256 collateralBalance = vault.institutionalRuntime().totalCollateralDeposited;
        assertGt(seizePreview, collateralBalance);

        supply.mint(liquidator, maxRepay);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), maxRepay);
        vm.expectRevert(
            abi.encodeWithSelector(
                InstitutionalLoanVault.InsufficientCollateralForSeize.selector, seizePreview, collateralBalance
            )
        );
        adapter.liquidate(address(vault), maxRepay);
        vm.stopPrank();
    }

    function test_fork_collateral_liquidatorRefund() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.8e18);
        _whitelistLiquidator();

        uint256 debt = vault.outstandingDebt();
        uint256 excess = 100_000e18;
        uint256 totalSend = debt + excess;

        adapter.setCloseFactor(1e18);

        supply.mint(liquidator, totalSend);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), totalSend);
        adapter.liquidate(address(vault), totalSend);
        vm.stopPrank();

        // Since repayAmount = debt + excess, InstitutionalLoanVault clamps actualRepay to `debt`,
        // so LiquidationAdapter refunds exactly `excess` supply asset back to the caller.
        assertEq(supply.balanceOf(liquidator), excess);
    }

    function test_fork_collateral_liquidationIncentiveSplit() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 liqRepay = 50_000e18;
        uint256 expectedSeize = vault.calculateSeizeAmount(liqRepay, LiquidationType.HF_BASED);
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / LI;
        uint256 incentiveAmount = expectedSeize - repayEquivalent;
        uint256 protocolAmount = (incentiveAmount * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 callerAmount = expectedSeize - protocolAmount;

        supply.mint(liquidator, liqRepay);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), liqRepay);
        vm.expectEmit(true, false, false, true, address(vault));
        emit InstitutionalLoanVault.LiquidationExecuted(address(adapter), liqRepay, expectedSeize);
        vm.expectEmit(address(adapter));
        emit LiquidationAdapter.LiquidationCollateralSplit(expectedSeize, protocolAmount, callerAmount);
        adapter.liquidate(address(vault), liqRepay);
        vm.stopPrank();

        assertApproxEqAbs(collateral.balanceOf(liquidator), callerAmount, 1);
        assertApproxEqAbs(adapter.protocolShareAccrued(address(collateral)), protocolAmount, 1);
        assertApproxEqAbs(collateral.balanceOf(address(adapter)), protocolAmount, 1);
    }

    function test_fork_collateral_overdueLiquidationIncentiveSplit() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        _whitelistSettler();

        uint256 liqRepay = 50_000e18;
        uint256 expectedSeize = vault.calculateSeizeAmount(liqRepay, LiquidationType.DEADLINE);
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / LATE_PENALTY_RATE;
        uint256 incentiveAmount = expectedSeize - repayEquivalent;
        uint256 protocolAmount = (incentiveAmount * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        uint256 callerAmount = expectedSeize - protocolAmount;

        supply.mint(settler, liqRepay);
        vm.startPrank(settler);
        supply.approve(address(adapter), liqRepay);
        vm.expectEmit(true, false, false, true, address(vault));
        emit InstitutionalLoanVault.OverdueLiquidationExecuted(address(adapter), liqRepay, expectedSeize);
        vm.expectEmit(address(adapter));
        emit LiquidationAdapter.LiquidationCollateralSplit(expectedSeize, protocolAmount, callerAmount);
        adapter.liquidateOverdueVault(address(vault), liqRepay);
        vm.stopPrank();

        assertApproxEqAbs(collateral.balanceOf(settler), callerAmount, 1);
        assertApproxEqAbs(adapter.protocolShareAccrued(address(collateral)), protocolAmount, 1);
        assertApproxEqAbs(collateral.balanceOf(address(adapter)), protocolAmount, 1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 9. LENDER ACCOUNTING EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_lenderAccounting_marginCompensation_orderDependent() external {
        _openVault();

        uint256 d1 = 300_000e18;
        uint256 d2 = 200_000e18;
        _supplyAs(lender1, d1);
        _supplyAs(lender2, d2);

        vm.warp(vault.runtime().openEndTime + 1);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.Failed));
        assertTrue(vault.institutionalRuntime().institutionDefaulted);

        uint256 confiscated = vault.institutionalRuntime().confiscatedMarginRemaining;

        uint256 shares1 = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares1, lender1, lender1);
        uint256 comp1 = collateral.balanceOf(lender1);

        uint256 shares2 = vault.balanceOf(lender2);
        vm.prank(lender2);
        vault.redeem(shares2, lender2, lender2);
        uint256 comp2 = collateral.balanceOf(lender2);

        assertApproxEqAbs(comp1 + comp2, confiscated, 1);
        assertGt(comp1, comp2);
    }

    function test_fork_lenderAccounting_protocolFee_fullRepayment() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        uint256 expectedProtocolFee = (interest * RESERVE_FACTOR) / MANTISSA_ONE;
        assertEq(protocolFee, expectedProtocolFee);
        assertEq(supply.balanceOf(psrAddress), protocolFee);
    }

    function test_fork_lenderAccounting_protocolFee_partialInterest() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 partialRepay = MAX_BORROW_CAP + interest / 2;
        _repayAmount(institution, partialRepay);

        _setPrice(address(collateral), 0.01e18);

        uint256 remainingDebt = vault.outstandingDebt();
        uint256 totalInterest = _computeInterest(MAX_BORROW_CAP);

        // Repay bad debt with either the exact coverage needed (when remainingDebt > totalInterest)
        // or a minimal 1 wei (when remainingDebt <= totalInterest) to avoid underflow while still
        // producing the shortfall liquidation path.
        uint256 badDebtCoverage = remainingDebt > totalInterest ? (remainingDebt - totalInterest) : 1;
        supply.mint(address(this), badDebtCoverage);
        supply.approve(address(vault), badDebtCoverage);
        vault.repayBadDebt(badDebtCoverage);

        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));

        uint256 available = supply.balanceOf(address(vault));
        assertGt(available, MAX_BORROW_CAP);

        // Protocol share settlement already ran on Liquidated transition, so vault balance here is post-fee.
        // For this path, gross interest settled is exactly half interest (principal + interest/2 repaid).
        uint256 expectedFee = _computeProtocolFee(interest / 2);

        uint256 psrBalance = supply.balanceOf(psrAddress);
        assertApproxEqAbs(psrBalance, expectedFee, 3);
    }

    function test_fork_lenderAccounting_protocolFee_lossScenario() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();

        _repayAmount(institution, 600_000e18);

        _setPrice(address(collateral), 0.3e18);

        assertLt(vault.getCollateralValueUSD(), vault.getDebtValueUSD());

        uint256 remainingDebt = vault.outstandingDebt();
        uint256 totalInterest = _computeInterest(MAX_BORROW_CAP);
        uint256 badDebtCoverage = remainingDebt - totalInterest;

        supply.mint(address(this), badDebtCoverage);
        supply.approve(address(vault), badDebtCoverage);
        vm.expectEmit(true, true, false, false, address(vault));
        emit BaseVault.StateTransition(VaultState.PendingSettlement, VaultState.Liquidated, 0);
        vault.repayBadDebt(badDebtCoverage);

        assertEq(uint8(vault.state()), uint8(VaultState.Liquidated));

        assertEq(supply.balanceOf(psrAddress), 0);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);
        assertEq(supply.balanceOf(lender1), MAX_BORROW_CAP);

        vm.expectEmit(address(vault));
        emit BaseVault.VaultClosed(VaultState.Liquidated);
        controller.closeVault(address(vault));
        assertEq(uint8(vault.runtime().state), uint8(VaultState.Closed));
    }

    // ══════════════════════════════════════════════════════════════════════
    // ADDITIONAL STATE MACHINE EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_depositCollateral_belowMargin_reverts() external {
        uint256 tooLittle = MARGIN_AMOUNT - 1;
        collateral.mint(institution, tooLittle);
        vm.startPrank(institution);
        collateral.approve(address(vault), tooLittle);
        vm.expectRevert(InstitutionalLoanVault.InsufficientCollateral.selector);
        vault.depositCollateral(tooLittle);
        vm.stopPrank();
    }

    function test_fork_repay_zeroAmount_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        vm.expectRevert(BaseVault.ZeroRepayAmount.selector);
        vault.repay(0);
    }

    function test_fork_withdrawCollateral_breachLT_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        uint256 minRequired = vault.institutionalRuntime().minimumCollateralRequired;
        uint256 maxWithdrawable = totalCol - minRequired;

        vm.prank(institution);
        vm.expectRevert();
        vault.withdrawCollateral(maxWithdrawable + 1);
    }

    function test_fork_updateVaultState_permissionless() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));

        vm.warp(vault.runtime().lockEndTime + 1);

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        vault.updateVaultState();

        assertEq(uint8(vault.state()), uint8(VaultState.PendingSettlement));
    }

    function test_fork_closeVault_nonTerminal_reverts() external {
        _openVault();

        vm.expectRevert(BaseVault.InvalidState.selector);
        controller.closeVault(address(vault));
    }

    function test_fork_liquidation_notLiquidatable_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _whitelistLiquidator();

        supply.mint(liquidator, 50_000e18);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), 50_000e18);
        vm.expectRevert(InstitutionalLoanVault.NotLiquidatable.selector);
        adapter.liquidate(address(vault), 50_000e18);
        vm.stopPrank();
    }

    function test_fork_overdueLiquidation_wrongState_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _whitelistSettler();

        supply.mint(settler, 50_000e18);
        vm.startPrank(settler);
        supply.approve(address(adapter), 50_000e18);
        vm.expectRevert(InstitutionalLoanVault.InvalidStateForOverdueLiquidation.selector);
        adapter.liquidateOverdueVault(address(vault), 50_000e18);
        vm.stopPrank();
    }

    function test_fork_liquidation_exceedsCloseFactor_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 debt = vault.outstandingDebt();
        uint256 maxRepay = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
        uint256 tooMuch = maxRepay + 1;

        supply.mint(liquidator, tooMuch);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), tooMuch);
        vm.expectRevert(InstitutionalLoanVault.ExceedsCloseFactor.selector);
        adapter.liquidate(address(vault), tooMuch);
        vm.stopPrank();
    }

    function test_fork_repayBadDebt_notBadDebt_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        supply.mint(address(this), 100_000e18);
        supply.approve(address(vault), 100_000e18);
        vm.expectRevert(InstitutionalLoanVault.NotBadDebt.selector);
        vault.repayBadDebt(100_000e18);
    }

    function test_fork_claimRaisedFunds_twice_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        vm.prank(institution);
        vault.claimRaisedFunds();

        vm.expectRevert(InstitutionalLoanVault.ClaimWouldBreachLT.selector);
        vm.prank(institution);
        vault.claimRaisedFunds();
    }

    function test_fork_nonPositionHolder_depositCollateral_reverts() external {
        address randomUser = makeAddr("randomUser");
        collateral.mint(randomUser, 1e18);
        vm.startPrank(randomUser);
        collateral.approve(address(vault), 1e18);
        vm.expectRevert(InstitutionalLoanVault.NotPositionHolder.selector);
        vault.depositCollateral(1e18);
        vm.stopPrank();
    }

    function test_fork_repayBadDebt_insufficientRepayment_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();

        _setPrice(address(collateral), 0.3e18);

        supply.mint(address(this), 1e18);
        supply.approve(address(vault), 1e18);
        vm.expectRevert(InstitutionalLoanVault.InsufficientRepayment.selector);
        vault.repayBadDebt(1e18);
    }

    function test_fork_positionTransfer_withoutApproval_reverts() external {
        _openVault();

        address newHolder = makeAddr("newHolder");
        uint256 tokenId = vault.institutionalConfig().positionTokenId;

        // No controller.approvePositionTransfer(address(vault)) call: transferApproved[tokenId] stays false.
        vm.prank(institution);
        vm.expectRevert(abi.encodeWithSelector(InstitutionPositionToken.TransferNotApproved.selector, tokenId));
        posToken.safeTransferFrom(institution, newHolder, tokenId);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 10. WHITELIST ENFORCEMENT (LIQUIDATION)
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_liquidation_nonWhitelistedLiquidator_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        (, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(shortfall, 0);

        uint256 liqRepay = 50_000e18;
        address nonWhitelisted = makeAddr("nonWhitelistedLiquidator");
        supply.mint(nonWhitelisted, liqRepay);

        vm.startPrank(nonWhitelisted);
        supply.approve(address(adapter), liqRepay);
        vm.expectRevert(LiquidationAdapter.NotWhitelistedLiquidator.selector);
        adapter.liquidate(address(vault), liqRepay);
        vm.stopPrank();
    }

    function test_fork_liquidation_overdue_nonWhitelistedSettler_reverts() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();

        vm.warp(vault.runtime().settlementDeadline + 1);
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.SettlementDeadlineExceeded));

        adapter.setCloseFactor(1e18);

        uint256 debt = vault.outstandingDebt();
        address nonWhitelisted = makeAddr("nonWhitelistedSettler");
        supply.mint(nonWhitelisted, debt);

        vm.startPrank(nonWhitelisted);
        supply.approve(address(adapter), debt);
        vm.expectRevert(LiquidationAdapter.NotWhitelistedSettler.selector);
        adapter.liquidateOverdueVault(address(vault), debt);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    // 11. REPAYMENT EDGE CASES
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_repay_overpay_clampsAndKeepsExcess() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock(); // Vault is in Lock

        uint256 debt = vault.outstandingDebt();
        uint256 extra = 10_000e18;
        uint256 overpay = debt + extra;

        uint256 balBefore = supply.balanceOf(institution);
        supply.mint(institution, overpay);

        vm.startPrank(institution);
        supply.approve(address(vault), overpay);
        vault.repay(overpay);
        vm.stopPrank();

        assertEq(vault.outstandingDebt(), 0);
        // Overpaid amount beyond clamped debt must remain with the payer.
        assertEq(supply.balanceOf(institution), balBefore + extra);
    }

    function test_fork_repay_permissionless_thirdParty_maturesVault() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();

        _claimFunds();
        _warpPastLock(); // → PendingSettlement
        assertEq(uint8(vault.state()), uint8(VaultState.PendingSettlement));

        uint256 debt = vault.outstandingDebt();
        address thirdParty = makeAddr("thirdParty");
        supply.mint(thirdParty, debt);

        vm.startPrank(thirdParty);
        supply.approve(address(vault), debt);
        vault.repay(debt);
        vm.stopPrank();

        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        uint256 interest = _computeInterest(MAX_BORROW_CAP);
        uint256 protocolFee = _computeProtocolFee(interest);

        uint256 shares = vault.balanceOf(lender1);
        vm.prank(lender1);
        vault.redeem(shares, lender1, lender1);

        assertApproxEqAbs(supply.balanceOf(lender1), MAX_BORROW_CAP + interest - protocolFee, 1);

        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        vm.prank(institution);
        vault.withdrawCollateral(totalCol);
        assertEq(collateral.balanceOf(institution), IDEAL_COLLATERAL_AMOUNT);

        controller.closeVault(address(vault));
        assertEq(uint8(vault.runtime().state), uint8(VaultState.Closed));
    }

    // ══════════════════════════════════════════════════════════════════════
    // 12. ORACLE PRICE VARIATION (SUPPLY PRICE)
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_liquidation_supplyPriceLower_reducesSeizeAmount() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _setPrice(address(supply), 1e18);
        (, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(shortfall, 0);

        _whitelistLiquidator();
        uint256 repayAmt = 50_000e18;
        uint256 expectedSeizeA = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 collateralBeforeA = vault.institutionalRuntime().totalCollateralDeposited;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 seizedA = collateralBeforeA - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(seizedA, expectedSeizeA);

        // Fresh vault: supply price lower → repayValueUSD lower → seize lower.
        _createVault();
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        // Reset oracle prices before claim so LT check passes (prices are global and persist across scenarios).
        _setPrice(address(collateral), 1e18);
        _setPrice(address(supply), 1e18);
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _setPrice(address(supply), 0.8e18);
        (, uint256 shortfallLower) = vault.getVaultLiquidity();
        assertGt(shortfallLower, 0);

        uint256 expectedSeizeB = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 collateralBeforeB = vault.institutionalRuntime().totalCollateralDeposited;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 seizedB = collateralBeforeB - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(seizedB, expectedSeizeB);
        assertLt(seizedB, seizedA);
    }

    function test_fork_liquidation_supplyPriceHigher_increasesSeizeAmount() external {
        // Baseline: supply price = 1.0
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _setPrice(address(supply), 1e18);
        (, uint256 shortfall) = vault.getVaultLiquidity();
        assertGt(shortfall, 0);

        _whitelistLiquidator();
        uint256 repayAmt = 50_000e18;
        uint256 expectedSeizeBase = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 collateralBeforeBase = vault.institutionalRuntime().totalCollateralDeposited;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 seizedBase = collateralBeforeBase - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(seizedBase, expectedSeizeBase);

        // Fresh vault: supply price higher → repayValueUSD higher → seize higher.
        _createVault();
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        // Reset oracle prices before claim so LT check passes (prices are global and persist across scenarios).
        _setPrice(address(collateral), 1e18);
        _setPrice(address(supply), 1e18);
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _setPrice(address(supply), 2e18);
        (, uint256 shortfallHigher) = vault.getVaultLiquidity();
        assertGt(shortfallHigher, 0);

        uint256 expectedSeizeHigher = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 collateralBeforeHigher = vault.institutionalRuntime().totalCollateralDeposited;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 seizedHigher = collateralBeforeHigher - vault.institutionalRuntime().totalCollateralDeposited;
        assertEq(seizedHigher, expectedSeizeHigher);
        assertGt(seizedHigher, seizedBase);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 13. DONATION / COUNTER-INVARIANCE ATTACKS
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_directSupplyDonation_doesNotInflateSharePrice() external {
        _openVault();

        address attacker = makeAddr("attacker");

        // Attacker becomes first depositor with 1 wei.
        supply.mint(attacker, 1);
        vm.startPrank(attacker);
        supply.approve(address(vault), 1);
        vault.deposit(1, attacker);
        vm.stopPrank();

        // Donate directly to try to inflate share price.
        uint256 donation = 1_000_000e18;
        supply.mint(attacker, donation);
        vm.prank(attacker);
        supply.transfer(address(vault), donation);

        // Next lender deposit must not be affected by donation.
        uint256 depositAmt = 100_000e18;
        supply.mint(lender1, depositAmt);
        vm.startPrank(lender1);
        supply.approve(address(vault), depositAmt);
        uint256 sharesReceived = vault.deposit(depositAmt, lender1);
        vm.stopPrank();

        assertEq(sharesReceived, depositAmt);
        assertEq(vault.balanceOf(lender1), depositAmt);
    }

    function test_fork_directSupplyTransfer_doesNotRepayDebt_orAdvanceState() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock(); // → Lock

        _claimFunds(); // adds principal to totalDebt (interest + principal)
        uint256 debtBefore = vault.outstandingDebt();

        uint256 donation = 50_000e18;
        supply.mint(institution, donation);
        vm.prank(institution);
        supply.transfer(address(vault), donation);

        // Direct transfers must not reduce the debt counter tracked by the vault.
        assertEq(vault.outstandingDebt(), debtBefore);
        // Donation is just token movement; it must not change vault state.
        assertEq(uint8(vault.state()), uint8(VaultState.Lock));
    }

    // ══════════════════════════════════════════════════════════════════════
    // 14. GOVERNANCE SWEEPS
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_sweepProtocolShareToReserve_basic() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();

        _setPrice(address(collateral), 0.7e18);
        _whitelistLiquidator();

        uint256 debt = vault.outstandingDebt();
        uint256 repayAmt = 50_000e18;
        // Ensure repay is within closeFactor constraints for this vault state.
        uint256 maxRepay = (debt * CLOSE_FACTOR) / MANTISSA_ONE;
        if (repayAmt > maxRepay) repayAmt = maxRepay;

        supply.mint(liquidator, repayAmt);
        vm.startPrank(liquidator);
        supply.approve(address(adapter), repayAmt);
        adapter.liquidate(address(vault), repayAmt);
        vm.stopPrank();

        uint256 accrued = adapter.protocolShareAccrued(address(collateral));
        uint256 expectedSeize = vault.calculateSeizeAmount(repayAmt, LiquidationType.HF_BASED);
        uint256 li = vault.riskConfig().liquidationIncentive;
        uint256 repayEquivalent = (expectedSeize * MANTISSA_ONE) / li;
        uint256 incentiveAmount = expectedSeize - repayEquivalent;
        uint256 expectedProtocolAmount = (incentiveAmount * PROTOCOL_LIQ_SHARE) / MANTISSA_ONE;
        assertEq(accrued, expectedProtocolAmount);

        // Make this deterministic: LiquidationAdapter does not try/catch PSR updates,
        // so we route sweeps into the local MockPSR (it will accept mock token addresses).
        controller.setProtocolShareReserve(address(psr));
        uint256 psrBalBefore = collateral.balanceOf(address(psr));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit LiquidationAdapter.ProtocolShareSweptToReserve(address(collateral), accrued);
        adapter.sweepProtocolShareToReserve(address(collateral));

        assertEq(adapter.protocolShareAccrued(address(collateral)), 0);
        assertEq(collateral.balanceOf(address(psr)), psrBalBefore + accrued);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 15. BaseVault.sweep() (onlyController)
    // ══════════════════════════════════════════════════════════════════════

    function test_fork_sweep_transfersFullBalanceToTreasury_whenClosed() external {
        // Mature + close the vault so sweep is allowed.
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        assertEq(uint8(vault.state()), uint8(VaultState.Matured));

        controller.closeVault(address(vault));
        assertEq(uint8(vault.runtime().state), uint8(VaultState.Closed));

        // Mint an unrelated token directly to the vault (stuck tokens scenario).
        MockERC20 extra = new MockERC20("Extra", "EXTRA");
        uint256 amount = 123_456e18;
        extra.mint(address(vault), amount);

        address treasury = addrs.treasury;
        uint256 treasuryBefore = extra.balanceOf(treasury);

        // Only the controller address can call sweep().
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaseVault.TokensSwept(address(extra), treasury, amount);
        vm.prank(address(controller));
        vault.sweep(address(extra));

        assertEq(extra.balanceOf(address(vault)), 0);
        assertEq(extra.balanceOf(treasury), treasuryBefore + amount);
    }

    function test_fork_sweep_succeedsWhileVaultActive() external {
        // Vault is active after opening.
        _openVault();
        assertEq(uint8(vault.runtime().state), uint8(VaultState.Fundraising));

        MockERC20 extra = new MockERC20("Extra", "EXTRA");
        uint256 amount = 1e18;
        extra.mint(address(vault), amount);

        address treasury = addrs.treasury;
        uint256 treasuryBefore = extra.balanceOf(treasury);

        vm.prank(address(controller));
        vault.sweep(address(extra));

        assertEq(extra.balanceOf(address(vault)), 0);
        assertEq(extra.balanceOf(treasury), treasuryBefore + amount);
    }

    function test_fork_sweep_revertsIfNothingToSweep() external {
        // Get to closed state first.
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        controller.closeVault(address(vault));

        MockERC20 extra = new MockERC20("Extra", "EXTRA");
        // No mint to vault => balance is zero.
        vm.prank(address(controller));
        vm.expectRevert(BaseVault.NothingToSweep.selector);
        vault.sweep(address(extra));
    }

    function test_fork_sweep_revertsIfNotController() external {
        _openVault();
        _supplyAs(lender1, MAX_BORROW_CAP);
        _topUpCollateralAndLock();
        _claimFunds();
        _warpPastLock();
        _repayAll();
        vault.updateVaultState();
        controller.closeVault(address(vault));

        MockERC20 extra = new MockERC20("Extra", "EXTRA");
        extra.mint(address(vault), 1e18);

        vm.prank(lender1);
        vm.expectRevert(BaseVault.Unauthorized.selector);
        vault.sweep(address(extra));
    }
}
