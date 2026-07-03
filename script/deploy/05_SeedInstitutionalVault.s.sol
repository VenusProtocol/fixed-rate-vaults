// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    IAccessControlManagerV8
} from "@venusprotocol/governance-contracts/contracts/Governance/IAccessControlManagerV8.sol";

import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { InstitutionalVaultDeployments } from "../../src/lib/InstitutionalVaultDeployments.sol";
import { IResilientOracle } from "../../src/interfaces/IResilientOracle.sol";

import { VaultConfig, VaultState } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig } from "../../src/interfaces/IInstitutionalVaultTypes.sol";

/**
 * @title SeedInstitutionalVault
 * @notice End-to-end testnet helper that creates a fresh InstitutionalLoanVault on the *already deployed*
 *         controller and drives it through the pre-lock lifecycle with three distinct signers:
 *
 *           1. PRIVATE_KEY              (governance/operator) — createVault + openVault (ACM-gated)
 *           2. INSTITUTION_PRIVATE_KEY  (institution)        — deposits margin, then tops up to full collateral
 *           3. DEPOSITOR_PRIVATE_KEY    (lender)             — deposits the loan (supply asset)
 *
 *         Flow (default "seed" mode):
 *           createVault  ->  institution deposits margin  ->  openVault  ->  institution tops up to
 *           idealCollateral  ->  depositor supplies the loan. The vault ends in Fundraising, fully
 *           collateralized with the loan supplied.
 *
 *         Reaching Lock requires `block.timestamp >= openEndTime`. A single `forge script --broadcast`
 *         submits every tx in one burst and cannot wait, and the funding txs MUST land before openEndTime
 *         (otherwise `_checkAndAdvanceState` would fail the vault). So locking is a SEPARATE step: after the
 *         open window elapses, set `FINALIZE_ONLY = true` and `VAULT` in the CONFIG block below and re-run —
 *         this calls the permissionless `updateVaultState()` to transition Fundraising -> Lock.
 *
 *         Only the three signer keys are read from the environment. Everything else (tokens, caps, timing,
 *         rates, risk, mode) is set in the CONFIG block at the top of this contract, so a run is fully
 *         reproducible from source — edit the constants there before running.
 *
 * @dev Preconditions (reuse-existing-controller model):
 *        - PRIVATE_KEY holds live-ACM permission for createVault + openVault on the controller.
 *        - SUPPLY_TOKEN and COLLATERAL_TOKEN are both priced by the controller's ResilientOracle.
 *        - Institution holds >= idealCollateral of COLLATERAL_TOKEN; depositor holds >= deposit amount
 *          of SUPPLY_TOKEN. Both must be regular (non fee-on-transfer) ERC-20s.
 *
 *      Run (fund the vault) — with FINALIZE_ONLY = false in CONFIG:
 *        forge script script/deploy/05_SeedInstitutionalVault.s.sol --rpc-url bsc_testnet --broadcast
 *      Run (lock it) — after the open window passes, set FINALIZE_ONLY = true and VAULT in CONFIG, then:
 *        forge script script/deploy/05_SeedInstitutionalVault.s.sol --rpc-url bsc_testnet --broadcast
 */
contract SeedInstitutionalVault is Script {
    /* ══════════════════════════════════════════════════════════════════════════════════════════════
     *                                CONFIG  —  EDIT THESE BEFORE RUNNING
     * ══════════════════════════════════════════════════════════════════════════════════════════════
     *  Only the three signer keys live in .env (PRIVATE_KEY, INSTITUTION_PRIVATE_KEY, DEPOSITOR_PRIVATE_KEY).
     *  Every other input is set here so a run is fully reproducible from source. Fill in the token
     *  addresses + pick a mode below, then run the forge command in the header comment.
     * ══════════════════════════════════════════════════════════════════════════════════════════════ */

    // ── Mode ──
    bool internal constant FINALIZE_ONLY = false; // false = create + fund a new vault; true = lock VAULT below
    address internal constant VAULT = address(0); // FINALIZE_ONLY target (the vault to lock); ignored when seeding

    // ── Vault economics (seed mode) ──
    address internal constant SUPPLY_TOKEN = 0xA11c8D9DC9b66E209Ef60F0C8D969D3CD988782c; // USDT 6dp (bsctestnet)
    address internal constant COLLATERAL_TOKEN = 0xC337Dd0390FdFD0Ee5D2b682E425986EDD7b59da; // SOL 18dp (bsctestnet)
    uint256 internal constant MAX_CAP_WHOLE = 100; // loan size / max borrow cap, in whole supply tokens (100 USDT)
    uint256 internal constant IDEAL_COLLATERAL_WHOLE = 5; // collateral the institution posts, in whole tokens (5 SOL)
    uint40 internal constant OPEN_DURATION = 600; // fundraising window, in seconds
    string internal constant SHARE_NAME = "Testnet Inst Vault"; // ERC-20 share token name
    string internal constant SHARE_SYMBOL = "tIV"; // ERC-20 share token symbol
    string internal constant INSTITUTION_NAME = "Testnet Institution"; // on-chain institution label (must be non-empty)

    // ── Rates & risk (mirror the canonical vault configuration) ──
    uint256 internal constant FIXED_APY = 800; // 8% in BPS
    uint256 internal constant RESERVE_FACTOR = 0.1e18; // 10%
    uint40 internal constant LOCK_DURATION = 24 hours; // vault stays locked ~24h, then enters settlement
    uint40 internal constant SETTLEMENT_WINDOW = 30 days;
    uint256 internal constant MARGIN_RATE = 0.1e18; // 10% of idealCollateral
    uint256 internal constant LT = 0.75e18; // liquidation threshold
    uint256 internal constant LI = 1.1e18; // liquidation incentive (10%)
    uint256 internal constant LATE_PENALTY_RATE = 1.15e18; // 15%
    /* ══════════════════════════════════════════════════════════════════════════════════════════════
     *                                        END CONFIG
     * ══════════════════════════════════════════════════════════════════════════════════════════════ */

    // minBorrowCap is derived as 50% of maxBorrowCap in _seed(); collateral is sized independently
    // (IDEAL_COLLATERAL_WHOLE) because the collateral (SOL) and supply (USDT) assets are different tokens.
    uint256 internal constant MANTISSA_ONE = 1e18;

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error OraclePriceZero(address token);
    error NotAuthorized(address account, string functionSig);
    error InsufficientBalance(address account, address token, uint256 have, uint256 need);
    error VaultNotProvided();

    function run() external {
        InstitutionalVaultDeployments.Deployments memory d = InstitutionalVaultDeployments.getByChainId(block.chainid);
        InstitutionalVaultController controller = InstitutionalVaultController(d.controllerProxy);

        // FINALIZE_ONLY path: just advance an existing vault (permissionless) — use this after the
        // open window has elapsed to transition Fundraising -> Lock.
        if (FINALIZE_ONLY) {
            _finalize(vm.envUint("PRIVATE_KEY"));
            return;
        }

        _seed(controller);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Seed: create + fund the vault up to (but not including) Lock.
    // ──────────────────────────────────────────────────────────────────────

    function _seed(
        InstitutionalVaultController controller
    ) internal {
        uint256 govPk = vm.envUint("PRIVATE_KEY");
        uint256 instPk = vm.envUint("INSTITUTION_PRIVATE_KEY");
        uint256 depPk = vm.envUint("DEPOSITOR_PRIVATE_KEY");
        address gov = vm.addr(govPk);
        address institution = vm.addr(instPk);
        address depositor = vm.addr(depPk);

        address supplyToken = SUPPLY_TOKEN;
        address collateralToken = COLLATERAL_TOKEN;

        // Derive amounts from a whole-token cap, scaled to each token's decimals.
        uint256 supplyUnit = 10 ** IERC20Metadata(supplyToken).decimals();
        uint256 collateralUnit = 10 ** IERC20Metadata(collateralToken).decimals();

        uint256 maxBorrowCap = MAX_CAP_WHOLE * supplyUnit;
        uint256 minBorrowCap = maxBorrowCap / 2;
        uint256 idealCollateral = IDEAL_COLLATERAL_WHOLE * collateralUnit; // institution's posted collateral (SOL)
        uint256 margin = (idealCollateral * MARGIN_RATE) / MANTISSA_ONE; // 10% of idealCollateral
        uint256 remainingCollateral = idealCollateral - margin;
        uint256 depositAmount = maxBorrowCap; // fill the cap; guaranteed >= minBorrowCap

        _preflight(
            controller, gov, institution, depositor, supplyToken, collateralToken, idealCollateral, depositAmount
        );

        VaultConfig memory vaultConfig = VaultConfig({
            supplyAsset: IERC20(supplyToken),
            fixedAPY: FIXED_APY,
            reserveFactor: RESERVE_FACTOR,
            minBorrowCap: minBorrowCap,
            maxBorrowCap: maxBorrowCap,
            minSupplierDeposit: 0,
            openDuration: OPEN_DURATION,
            lockDuration: LOCK_DURATION,
            settlementWindow: SETTLEMENT_WINDOW
        });
        InstitutionalConfig memory instConfig = InstitutionalConfig({
            collateralAsset: IERC20(collateralToken),
            idealCollateralAmount: idealCollateral,
            marginRate: MARGIN_RATE,
            institutionOperator: institution,
            positionTokenId: 0 // assigned by the controller on createVault
        });
        RiskConfig memory riskConfig =
            RiskConfig({ liquidationThreshold: LT, liquidationIncentive: LI, latePenaltyRate: LATE_PENALTY_RATE });

        // 1. Governance creates the vault clone.
        vm.startBroadcast(govPk);
        address vaultAddr =
            controller.createVault(vaultConfig, instConfig, riskConfig, SHARE_NAME, SHARE_SYMBOL, INSTITUTION_NAME);
        vm.stopBroadcast();
        InstitutionalLoanVault vault = InstitutionalLoanVault(vaultAddr);
        console.log("Vault created:", vaultAddr);

        // 2. Institution deposits the margin (WaitingForMargin -> MarginDeposited).
        vm.startBroadcast(instPk);
        IERC20(collateralToken).approve(vaultAddr, margin);
        vault.depositCollateral(margin);
        vm.stopBroadcast();
        console.log("Margin deposited:", margin);

        // 3. Governance opens the vault (MarginDeposited -> Fundraising).
        vm.startBroadcast(govPk);
        controller.openVault(vaultAddr);
        vm.stopBroadcast();
        uint256 openEndTime = vault.runtime().openEndTime;
        console.log("Vault opened; openEndTime:", openEndTime);

        // 4. Institution tops up to the full ideal collateral (during Fundraising).
        vm.startBroadcast(instPk);
        IERC20(collateralToken).approve(vaultAddr, remainingCollateral);
        vault.depositCollateral(remainingCollateral);
        vm.stopBroadcast();
        console.log("Collateral topped up to ideal:", idealCollateral);

        // 5. Depositor supplies the loan (during Fundraising).
        vm.startBroadcast(depPk);
        IERC20(supplyToken).approve(vaultAddr, depositAmount);
        uint256 shares = vault.deposit(depositAmount, depositor);
        vm.stopBroadcast();
        console.log("Loan deposited:", depositAmount);
        console.log("Shares minted to depositor:", shares);

        console.log("--------------------------------------------------------------");
        console.log("Vault is funded and in Fundraising. To lock it, wait until the");
        console.log("open window elapses (unix ts >=):", openEndTime);
        console.log("then set FINALIZE_ONLY = true and VAULT in this script's CONFIG");
        console.log("block to the address below, and re-run:");
        console.log("  VAULT =", vaultAddr);
        console.log("--------------------------------------------------------------");
    }

    // ──────────────────────────────────────────────────────────────────────
    // Finalize: advance an already-funded vault to Lock once the window passed.
    // ──────────────────────────────────────────────────────────────────────

    function _finalize(
        uint256 pk
    ) internal {
        if (VAULT == address(0)) revert VaultNotProvided();
        InstitutionalLoanVault vault = InstitutionalLoanVault(VAULT);

        // updateVaultState() is permissionless; any key works.
        vm.startBroadcast(pk);
        vault.updateVaultState();
        vm.stopBroadcast();

        VaultState s = vault.state();
        console.log("updateVaultState() called on:", VAULT);
        console.log("Vault state (see VaultState enum) is now:", uint256(s));
        if (s != VaultState.Lock) {
            console.log("Not locked yet - the open window has not elapsed. Retry after openEndTime.");
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Pre-flight — fail fast with readable errors instead of deep reverts.
    // ──────────────────────────────────────────────────────────────────────

    function _preflight(
        InstitutionalVaultController controller,
        address gov,
        address institution,
        address depositor,
        address supplyToken,
        address collateralToken,
        uint256 idealCollateral,
        uint256 depositAmount
    ) internal view {
        // Governance key must be ACM-authorized for the gated calls. Use hasPermission (scoped to the
        // controller) rather than isAllowedToCall, which scopes to msg.sender — here the script, not the
        // controller — and would report a false negative.
        IAccessControlManagerV8 acm = IAccessControlManagerV8(address(controller.accessControlManager()));
        address controllerAddr = address(controller);
        if (!acm.hasPermission(
                gov, controllerAddr, "createVault(VaultConfig,InstitutionalConfig,RiskConfig,string,string,string)"
            )) {
            revert NotAuthorized(gov, "createVault(VaultConfig,InstitutionalConfig,RiskConfig,string,string,string)");
        }
        if (!acm.hasPermission(gov, controllerAddr, "openVault(address)")) {
            revert NotAuthorized(gov, "openVault(address)");
        }

        // Both assets must be priced by the controller's oracle (createVault would revert otherwise).
        IResilientOracle oracle = IResilientOracle(controller.oracle());
        if (oracle.getPrice(supplyToken) == 0) revert OraclePriceZero(supplyToken);
        if (oracle.getPrice(collateralToken) == 0) revert OraclePriceZero(collateralToken);

        // Balances must cover the flow.
        uint256 instBal = IERC20(collateralToken).balanceOf(institution);
        if (instBal < idealCollateral) {
            revert InsufficientBalance(institution, collateralToken, instBal, idealCollateral);
        }
        uint256 depBal = IERC20(supplyToken).balanceOf(depositor);
        if (depBal < depositAmount) revert InsufficientBalance(depositor, supplyToken, depBal, depositAmount);
    }
}
