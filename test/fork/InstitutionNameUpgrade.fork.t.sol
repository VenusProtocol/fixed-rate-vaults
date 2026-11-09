// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    AccessControlManager
} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlManager.sol";

import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { IInstitutionalLoanVault } from "../../src/interfaces/IInstitutionalLoanVault.sol";
import { Addresses } from "../../src/lib/Addresses.sol";

import { VaultConfig, VaultState } from "../../src/interfaces/IVaultTypes.sol";
import { InstitutionalConfig, RiskConfig, VaultStateInfo } from "../../src/interfaces/IInstitutionalVaultTypes.sol";

/// @title InstitutionNameUpgradeForkTest
/// @notice Upgrades the live BSC mainnet InstitutionalVaultController proxy to the current implementation in-test,
///         then exercises only the code paths the institutionName change introduced or modified:
///         setInstitutionNameOverride, institutionNameOverride, the vault-level institutionName getter, the
///         name-resolving getAggregatedVaultStates, setInstitutionName, and createVault's new name parameter —
///         against both the already-deployed legacy vault (predates the field) and a freshly created vault.
contract InstitutionNameUpgradeForkTest is Test {
    // ── Fork block: latest state with exactly the one legacy vault registered.
    uint256 internal constant FORK_BLOCK = 107_403_822;

    // ── Live deployed addresses (created before institutionName existed).
    address internal constant CONTROLLER = 0x6D9e91cB766259af42619c14c994E694E57e6E85;
    address internal constant LEGACY_VAULT = 0x7D80A10bEdD13638888e7A946B82878E21fbB820;
    address internal constant LEGACY_OPERATOR = 0x459b68d370006E2f6a301F10EEE21f3Ae4048036;

    // ── Real BSC mainnet tokens, already priced by the live ResilientOracle, for the fresh-vault path.
    address internal constant SUPPLY_ASSET = 0x55d398326f99059fF775485246999027B3197955; // USDT
    address internal constant COLLATERAL_ASSET = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // BTCB

    // ── Known legacy vault state at FORK_BLOCK (verified via cast).
    uint256 internal constant LEGACY_TOTAL_RAISED = 1_000_000e18;

    // ── New-vault config constants.
    uint256 internal constant NEW_MIN_CAP = 1000e18;
    uint256 internal constant NEW_MAX_CAP = 10_000e18;
    uint256 internal constant NEW_IDEAL_COLLATERAL = 15_000e18;

    Addresses.NetworkAddresses internal addrs;
    AccessControlManager internal acm;
    InstitutionalVaultController internal controller;

    address internal forkInstitution;

    // Mirror of the controller events under test (concrete type does not re-export them for expectEmit topics).
    event VaultCreated(address indexed vault, address indexed institution);
    event InstitutionNameUpdated(address indexed vault, string oldName, string newName);
    event InstitutionNameOverrideUpdated(address indexed vault, string oldName, string newName);

    function setUp() external {
        string memory forkEnabled = vm.envOr("FORK_ENABLED", string("false"));
        if (keccak256(bytes(forkEnabled)) != keccak256(bytes("true"))) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("bsc_mainnet", FORK_BLOCK);

        addrs = Addresses.getByChainId(block.chainid);
        acm = AccessControlManager(addrs.accessControlManager);
        controller = InstitutionalVaultController(CONTROLLER);
        forkInstitution = makeAddr("forkInstitution");

        _upgradeController();
        _grantControllerPermissions();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Setup helpers
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Deploys the current controller implementation and points the live proxy at it via the real
    ///      governance path (ProxyAdmin.upgrade, called by its timelock owner).
    function _upgradeController() internal {
        address newImpl = address(new InstitutionalVaultController());
        vm.prank(addrs.normalTimelock);
        (bool ok,) = addrs.proxyAdmin.call(abi.encodeWithSignature("upgrade(address,address)", CONTROLLER, newImpl));
        assertTrue(ok, "controller proxy upgrade failed");
    }

    /// @dev Grants this test contract permission to call the new / affected controller entrypoints.
    function _grantControllerPermissions() internal {
        vm.startPrank(addrs.normalTimelock);
        acm.giveCallPermission(address(0), "setVaultImplementation(address)", address(this));
        acm.giveCallPermission(
            address(0), "createVault(VaultConfig,InstitutionalConfig,RiskConfig,string,string,string)", address(this)
        );
        acm.giveCallPermission(address(0), "setInstitutionName(address,string)", address(this));
        acm.giveCallPermission(address(0), "setInstitutionNameOverride(address,string)", address(this));
        vm.stopPrank();
    }

    /// @dev Registers the current vault implementation so a fresh vault can be created post-upgrade. Kept
    ///      separate from _createFreshVault so tests can arm expectEmit around only the createVault call.
    function _setFreshVaultImpl() internal {
        controller.setVaultImplementation(address(new InstitutionalLoanVault()));
    }

    /// @dev Creates a fresh vault via the new createVault signature, using real oracle-priced BSC tokens
    ///      (createVault only validates that both assets are priced — it never moves tokens). Requires
    ///      _setFreshVaultImpl() first.
    function _createFreshVault(
        string memory instName
    ) internal returns (address) {
        VaultConfig memory vc = VaultConfig({
            supplyAsset: IERC20(SUPPLY_ASSET),
            fixedAPY: 800,
            reserveFactor: 0.1e18,
            minBorrowCap: NEW_MIN_CAP,
            maxBorrowCap: NEW_MAX_CAP,
            minSupplierDeposit: 0,
            openDuration: 7 days,
            lockDuration: 365 days,
            settlementWindow: 30 days
        });
        InstitutionalConfig memory ic = InstitutionalConfig({
            collateralAsset: IERC20(COLLATERAL_ASSET),
            idealCollateralAmount: NEW_IDEAL_COLLATERAL,
            marginRate: 0.1e18,
            institutionOperator: forkInstitution,
            positionTokenId: 0
        });
        RiskConfig memory rc =
            RiskConfig({ liquidationThreshold: 0.75e18, liquidationIncentive: 1.1e18, latePenaltyRate: 1.15e18 });

        return controller.createVault(vc, ic, rc, "Fork Vault", "FV", instName);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Legacy vault (predates the field)
    // ──────────────────────────────────────────────────────────────────────

    /// @dev institutionName was moved out of InstitutionalConfig so the legacy vault's institutionalConfig()
    ///      ABI is unchanged: the raw return is still the 5-field static tuple and decodes cleanly.
    function test_fork_legacy_institutionalConfigStillDecodes() external view {
        (bool ok, bytes memory raw) = LEGACY_VAULT.staticcall(abi.encodeWithSignature("institutionalConfig()"));
        assertTrue(ok);
        assertEq(raw.length, 160);

        InstitutionalConfig memory cfg = IInstitutionalLoanVault(LEGACY_VAULT).institutionalConfig();
        assertEq(cfg.institutionOperator, LEGACY_OPERATOR);
        assertEq(cfg.positionTokenId, 1);
    }

    /// @dev getAggregatedVaultStates reverts on the legacy vault (its institutionName() getter does not exist,
    ///      so _resolveInstitutionName reverts), and works perfectly once an override is set — returning the
    ///      override as the resolved name with all other fields matching live on-chain reads.
    function test_fork_getAggregatedVaultStates_revertsThenResolvesAfterOverride() external {
        // Before the override: the resolver falls through to the missing vault getter and reverts.
        vm.expectRevert();
        controller.getAggregatedVaultStates();

        // Set the override for the legacy vault.
        string memory name = "Legacy Institutional Vault";
        assertEq(controller.institutionNameOverride(LEGACY_VAULT), "");
        vm.expectEmit(true, false, false, true, CONTROLLER);
        emit InstitutionNameOverrideUpdated(LEGACY_VAULT, "", name);
        controller.setInstitutionNameOverride(LEGACY_VAULT, name);
        assertEq(controller.institutionNameOverride(LEGACY_VAULT), name);

        // After the override: the call succeeds and resolves the name from the override.
        VaultStateInfo[] memory infos = controller.getAggregatedVaultStates();
        assertEq(infos.length, 1);
        assertEq(infos[0].vault, LEGACY_VAULT);
        assertEq(infos[0].institutionName, name);
        assertEq(uint8(infos[0].state), uint8(VaultState.Lock));
        assertEq(infos[0].institutionOperator, LEGACY_OPERATOR);
        assertEq(infos[0].totalRaised, LEGACY_TOTAL_RAISED);
        assertEq(infos[0].outstandingDebt, IInstitutionalLoanVault(LEGACY_VAULT).outstandingDebt());
    }

    /// @dev setInstitutionName cannot be used on the legacy vault: it reads the vault's institutionName() to
    ///      compute the old value, and that read reverts before any state change (hence the override path).
    function test_fork_setInstitutionName_revertsOnLegacyVault() external {
        vm.expectRevert();
        controller.setInstitutionName(LEGACY_VAULT, "Anything");
    }

    /// @dev setInstitutionNameOverride validations: unchanged name (including clearing an unset override) and
    ///      unregistered vault revert; an empty string is the documented way to clear an existing override.
    function test_fork_setInstitutionNameOverride_validations() external {
        // No override set yet, so "" (the clear value) equals the current value and reverts as unchanged.
        vm.expectRevert(InstitutionalVaultController.InstitutionNameUnchanged.selector);
        controller.setInstitutionNameOverride(LEGACY_VAULT, "");

        controller.setInstitutionNameOverride(LEGACY_VAULT, "Legacy Co");
        vm.expectRevert(InstitutionalVaultController.InstitutionNameUnchanged.selector);
        controller.setInstitutionNameOverride(LEGACY_VAULT, "Legacy Co");

        vm.expectRevert(InstitutionalVaultController.VaultNotRegistered.selector);
        controller.setInstitutionNameOverride(makeAddr("notAVault"), "Ghost");

        // Empty string clears an existing override.
        vm.expectEmit(true, false, false, true, CONTROLLER);
        emit InstitutionNameOverrideUpdated(LEGACY_VAULT, "Legacy Co", "");
        controller.setInstitutionNameOverride(LEGACY_VAULT, "");
        assertEq(controller.institutionNameOverride(LEGACY_VAULT), "");
    }

    // ──────────────────────────────────────────────────────────────────────
    // Fresh vault (created post-upgrade with the on-chain field)
    // ──────────────────────────────────────────────────────────────────────

    /// @dev A vault created via the new createVault signature stores institutionName on-chain, is resolved via
    ///      its own getter (no override), and coexists with the override-resolved legacy vault.
    function test_fork_newVault_storesAndResolvesNameViaGetter() external {
        // Legacy vault needs an override so the aggregator does not revert on it.
        controller.setInstitutionNameOverride(LEGACY_VAULT, "Legacy Co");
        _setFreshVaultImpl();

        address predicted = controller.predictVaultAddress(forkInstitution);
        vm.expectEmit(true, true, false, false, CONTROLLER);
        emit VaultCreated(predicted, forkInstitution);
        address newVault = _createFreshVault("Newco Capital");
        assertEq(newVault, predicted);
        assertTrue(controller.isRegistered(newVault));

        // Stored on the vault itself; no override set for it.
        assertEq(IInstitutionalLoanVault(newVault).institutionName(), "Newco Capital");
        assertEq(controller.institutionNameOverride(newVault), "");

        VaultStateInfo[] memory infos = controller.getAggregatedVaultStates();
        assertEq(infos.length, 2);
        // Legacy resolves via override, new vault resolves via its on-chain getter.
        assertEq(infos[0].institutionName, "Legacy Co");
        assertEq(infos[1].vault, newVault);
        assertEq(infos[1].institutionName, "Newco Capital");
        assertEq(infos[1].institutionOperator, forkInstitution);
        assertEq(uint8(infos[1].state), uint8(VaultState.WaitingForMargin));
    }

    /// @dev Renaming a fresh vault via setInstitutionName updates the vault's on-chain name and is reflected in
    ///      aggregated states without any override.
    function test_fork_newVault_renameReflectedInAggregatedStates() external {
        controller.setInstitutionNameOverride(LEGACY_VAULT, "Legacy Co");
        _setFreshVaultImpl();
        address newVault = _createFreshVault("Newco Capital");

        vm.expectEmit(true, false, false, true, CONTROLLER);
        emit InstitutionNameUpdated(newVault, "Newco Capital", "Renamed Inc");
        controller.setInstitutionName(newVault, "Renamed Inc");

        assertEq(IInstitutionalLoanVault(newVault).institutionName(), "Renamed Inc");
        assertEq(controller.institutionNameOverride(newVault), "");

        VaultStateInfo[] memory infos = controller.getAggregatedVaultStates();
        assertEq(infos[1].vault, newVault);
        assertEq(infos[1].institutionName, "Renamed Inc");
    }
}
