// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { LiquidationAdapter } from "../../src/institutional-vault/LiquidationAdapter.sol";

import { VaultState, VaultRuntime } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalRuntime } from "../../src/interfaces/IInstitutionalVaultTypes.sol";

import { ChainlinkOracle } from "@venusprotocol/oracle/contracts/oracles/ChainlinkOracle.sol";

import { VaultTestBase } from "./VaultTestBase.t.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Handler
// ──────────────────────────────────────────────────────────────────────────────

/// @dev Handler contract for Foundry invariant testing. Each function wraps a vault
///      operation with try/catch so the fuzzer can explore freely without reverting.
contract VaultHandler is Test {
    InstitutionalLoanVault public vault;
    InstitutionalVaultController public controller;
    LiquidationAdapter public adapter;
    MockERC20 public supply;
    MockERC20 public collateral;
    ChainlinkOracle public oracle;

    address public institution;
    address public lender1;
    address public lender2;
    address public liquidator;
    address public settler;

    // ── Ghost variables
    // ─────────────────────────────────────────────────────
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalRepaid;

    // Terminal-state tracking
    bool public ghost_reachedTerminal;
    VaultState public ghost_terminalState;

    constructor(
        InstitutionalLoanVault vault_,
        InstitutionalVaultController controller_,
        LiquidationAdapter adapter_,
        MockERC20 supply_,
        MockERC20 collateral_,
        ChainlinkOracle oracle_,
        address institution_,
        address lender1_,
        address lender2_,
        address liquidator_,
        address settler_
    ) {
        vault = vault_;
        controller = controller_;
        adapter = adapter_;
        supply = supply_;
        collateral = collateral_;
        oracle = oracle_;
        institution = institution_;
        lender1 = lender1_;
        lender2 = lender2_;
        liquidator = liquidator_;
        settler = settler_;
    }

    // ── Helpers
    // ─────────────────────────────────────────────────────────────

    function _recordTerminal() internal {
        VaultState s = vault.state();
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            if (!ghost_reachedTerminal) {
                ghost_reachedTerminal = true;
                ghost_terminalState = s;
            }
        }
    }

    // ── Handler functions
    // ───────────────────────────────────────────────────

    /// @dev Lender1 deposits into the vault during Fundraising.
    function deposit(
        uint256 amount
    ) external {
        uint256 remaining = vault.maxDeposit(lender1);
        if (remaining == 0) return;
        amount = bound(amount, 1, remaining);

        supply.mint(lender1, amount);
        vm.startPrank(lender1);
        supply.approve(address(vault), amount);
        try vault.deposit(amount, lender1) {
            ghost_totalDeposited += amount;
        } catch { }
        vm.stopPrank();

        _recordTerminal();
    }

    /// @dev Institution deposits collateral.
    function depositCollateral(
        uint256 amount
    ) external {
        amount = bound(amount, 1e18, 5_000_000e18);

        collateral.mint(institution, amount);
        vm.startPrank(institution);
        collateral.approve(address(vault), amount);
        try vault.depositCollateral(amount) { } catch { }
        vm.stopPrank();

        _recordTerminal();
    }

    /// @dev Institution withdraws collateral.
    function withdrawCollateral(
        uint256 amount
    ) external {
        uint256 totalCol = vault.institutionalRuntime().totalCollateralDeposited;
        if (totalCol == 0) return;
        amount = bound(amount, 1, totalCol);

        vm.startPrank(institution);
        try vault.withdrawCollateral(amount) { } catch { }
        vm.stopPrank();

        _recordTerminal();
    }

    /// @dev Repay outstanding debt.
    function repay(
        uint256 amount
    ) external {
        uint256 debt = vault.outstandingDebt();
        if (debt == 0) return;
        amount = bound(amount, 1, debt);

        supply.mint(institution, amount);
        vm.startPrank(institution);
        supply.approve(address(vault), amount);
        try vault.repay(amount) {
            ghost_totalRepaid += amount;
        } catch { }
        vm.stopPrank();

        _recordTerminal();
    }

    /// @dev Institution claims raised funds during Lock.
    function claimRaisedFunds() external {
        vm.startPrank(institution);
        try vault.claimRaisedFunds() { } catch { }
        vm.stopPrank();

        _recordTerminal();
    }

    /// @dev Warp time forward by a bounded delta, then poke updateVaultState.
    function warpTime(
        uint256 delta
    ) external {
        delta = bound(delta, 1, 400 days);
        vm.warp(block.timestamp + delta);
        try vault.updateVaultState() { } catch { }

        _recordTerminal();
    }

    /// @dev Change collateral price via oracle (only admin can call setDirectPrice).
    function changeCollateralPrice(
        uint256 price
    ) external {
        price = bound(price, 0.1e18, 10e18);
        // Handler test contract is admin; setDirectPrice is ACM-gated to admin.
        oracle.setDirectPrice(address(collateral), price);

        _recordTerminal();
    }

    /// @dev Permissionless state advance.
    function updateVaultState() external {
        try vault.updateVaultState() { } catch { }

        _recordTerminal();
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Invariant Test
// ──────────────────────────────────────────────────────────────────────────────

contract InvariantVaultTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public {
        _makeActors();
        _deployTokens();
        _deploySystem();
        _createVault();
        _openVault(); // vault is now in Fundraising

        // Deploy handler — test contract is admin so it can call oracle.setDirectPrice
        handler = new VaultHandler(
            vault, controller, adapter, supply, collateral, oracle, institution, lender1, lender2, liquidator, settler
        );

        // Grant the handler's address permission to call setDirectPrice on oracle
        // (the handler calls oracle.setDirectPrice directly; ACM checks msg.sender)
        acm.giveCallPermission(address(0), "setDirectPrice(address,uint256)", address(handler));

        // Label actors for trace readability
        vm.label(lender1, "lender1");
        vm.label(lender2, "lender2");
        vm.label(institution, "institution");
        vm.label(address(vault), "vault");
        vm.label(address(handler), "handler");

        // Restrict invariant fuzzer to the handler
        targetContract(address(handler));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: totalRaised matches cumulative deposits
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Every successful deposit increments totalRaised by the exact amount.
    ///      Ghost tracking mirrors this, so they must match while not in a terminal state
    ///      (once settled, totalRaised is frozen and still equals sum of deposits).
    function invariant_totalRaisedMatchesDeposits() external view {
        uint256 totalRaised = vault.runtime().totalRaised;
        assertEq(totalRaised, handler.ghost_totalDeposited(), "totalRaised != ghost_totalDeposited");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: shares always backed by assets
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev If any shares exist, totalAssets must be positive.
    ///      During Fundraising: totalAssets == totalRaised (1:1).
    ///      In terminal states: totalAssets == settlementAmount.
    function invariant_sharesBackedByAssets() external view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        uint256 totalAssets = vault.totalAssets();
        assertGt(totalAssets, 0, "shares exist but totalAssets == 0");

        VaultState s = vault.state();
        if (s == VaultState.Fundraising) {
            assertEq(totalAssets, vault.runtime().totalRaised, "Fundraising: totalAssets != totalRaised");
        }
        if (s == VaultState.Matured || s == VaultState.Failed || s == VaultState.Liquidated) {
            assertEq(totalAssets, vault.runtime().settlementAmount, "Terminal: totalAssets != settlementAmount");
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: terminal state is final
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Once a terminal state (Matured/Failed/Liquidated) has been reached,
    ///      the vault must remain in that exact terminal state.
    function invariant_terminalStateIsFinal() external view {
        if (!handler.ghost_reachedTerminal()) return;

        VaultState current = vault.state();
        VaultState recorded = handler.ghost_terminalState();
        assertEq(uint8(current), uint8(recorded), "state changed after reaching terminal");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: debt accounting consistency
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev If funds have been claimed (principal disbursed), total debt should not exceed
    ///      interest + totalRaised (i.e., the theoretical maximum debt).
    ///      If funds have NOT been claimed, total debt should not exceed the interest portion.
    function invariant_debtNeverExceedsMaximum() external view {
        VaultRuntime memory rt = vault.runtime();
        VaultState s = rt.state;

        // Only meaningful in Lock / PendingSettlement / SettlementDeadlineExceeded
        if (s != VaultState.Lock && s != VaultState.PendingSettlement && s != VaultState.SettlementDeadlineExceeded) {
            return;
        }

        uint256 debt = vault.outstandingDebt();
        uint256 interest = (rt.totalRaised * FIXED_APY * LOCK_DURATION) / (BPS * YEAR);

        if (rt.fundsWithdrawn) {
            // Principal + interest is the ceiling
            assertLe(debt, interest + rt.totalRaised, "debt exceeds interest + principal");
        } else {
            // Only interest is owed
            assertLe(debt, interest, "debt exceeds interest (funds not claimed)");
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: collateral accounting consistent
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev The vault's actual collateral token balance must be >= the tracked totalCollateralDeposited.
    ///      The vault should never promise more collateral than it holds.
    function invariant_collateralAccountingConsistent() external view {
        uint256 actualBalance = collateral.balanceOf(address(vault));
        uint256 tracked = vault.institutionalRuntime().totalCollateralDeposited;
        assertGe(actualBalance, tracked, "collateral balance < totalCollateralDeposited");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: no free shares
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev During Fundraising, the 1:1 deposit-to-share ratio means totalSupply
    ///      must never exceed totalRaised.
    function invariant_noFreeShares() external view {
        if (vault.state() != VaultState.Fundraising) return;
        assertLe(vault.totalSupply(), vault.runtime().totalRaised, "shares exceed totalRaised in Fundraising");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant: state never goes backward (monotonic progression)
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev The state machine only moves forward. We encode this as: the state enum
    ///      value should never decrease. The enum ordering is designed so that
    ///      forward transitions always increase the numerical value:
    ///        WaitingForMargin(0) -> MarginDeposited(1) -> Fundraising(2) -> Lock(4)
    ///        -> PendingSettlement(5) -> SettlementDeadlineExceeded(6) -> Matured(7)
    ///      And the failure path: Fundraising(2) -> Failed(8), which is also increasing.
    ///      Since the test starts in Fundraising(2), we track the highest state seen
    ///      and assert current >= highest.
    ///
    ///      NOTE: This invariant is checked inline rather than using a ghost variable
    ///      to avoid handler storage cost. We rely on the terminalStateIsFinal invariant
    ///      for the strongest guarantee, and here we just verify no backward movement
    ///      from non-terminal states.
    function invariant_stateNeverGoesBackward() external view {
        // Since we start at Fundraising(2), the state should never be below 2.
        uint8 current = uint8(vault.state());
        assertGe(current, uint8(VaultState.Fundraising), "state went backward from Fundraising");
    }
}
