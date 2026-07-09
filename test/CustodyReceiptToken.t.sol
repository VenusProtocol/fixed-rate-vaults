// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    AccessControlManager
} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlManager.sol";

import { CustodyReceiptToken } from "../src/CustodyReceiptToken.sol";

contract CustodyReceiptTokenTest is Test {
    AccessControlManager internal acm;
    CustodyReceiptToken internal token;

    address internal minter;
    address internal burner;
    address internal alice;
    address internal bob;

    string internal constant TOKEN_NAME = "Ceffu Custody BTC for Venus";
    string internal constant TOKEN_SYMBOL = "vceBTC";
    string internal constant MINT_SIG = "mint(address,uint256)";
    string internal constant BURN_SIG = "burn(address,uint256)";

    function setUp() external {
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // The test contract deploys the ACM, so it becomes DEFAULT_ADMIN and can grant permissions.
        acm = new AccessControlManager();
        // The test contract also deploys the token, so it is the initial owner.
        token = _deployToken(18);
    }

    /// @dev Deploy helper so tests can exercise the overridden `decimals()` for several values.
    function _deployToken(
        uint8 decimals_
    ) internal returns (CustodyReceiptToken) {
        return new CustodyReceiptToken(TOKEN_NAME, TOKEN_SYMBOL, decimals_, address(acm));
    }

    // ──────────────────────────────────────────────────────────────────────
    // constructor
    // ──────────────────────────────────────────────────────────────────────

    function test_constructor_setsStateAndAssignsOwnershipToDeployer() external view {
        assertEq(token.name(), TOKEN_NAME);
        assertEq(token.symbol(), TOKEN_SYMBOL);
        assertEq(token.accessControlManager(), address(acm));
        assertEq(token.owner(), address(this));
        assertEq(token.totalSupply(), 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // decimals() override — returns the constructor value instead of the hard-coded 18.
    // ──────────────────────────────────────────────────────────────────────

    function test_decimals_returnsValueSuppliedAtConstruction() external {
        assertEq(_deployToken(6).decimals(), 6);
        assertEq(_deployToken(8).decimals(), 8);
        assertEq(_deployToken(18).decimals(), 18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // mint() — new function gated by the AccessControlManager.
    // ──────────────────────────────────────────────────────────────────────

    function test_mint_revertsWithUnauthorizedWhenCallerHasNoPermission() external {
        vm.prank(minter);
        vm.expectRevert(CustodyReceiptToken.Unauthorized.selector);
        token.mint(alice, 1e18);
    }

    function test_mint_mintsToTargetWhenCallerIsAllowed() external {
        acm.giveCallPermission(address(0), MINT_SIG, minter);
        uint256 amount = 10e18;

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), alice, amount);
        vm.prank(minter);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);
    }

    function test_mint_revertsWhenMintingToZeroAddress() external {
        acm.giveCallPermission(address(0), MINT_SIG, minter);
        vm.prank(minter);
        vm.expectRevert("ERC20: mint to the zero address");
        token.mint(address(0), 1e18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // burn() — gated by the ACM and, unlike ERC20 burnFrom, destroys tokens from an arbitrary
    // holder without an allowance (confiscation behaviour).
    // ──────────────────────────────────────────────────────────────────────

    function test_burn_revertsWithUnauthorizedWhenCallerHasNoPermission() external {
        vm.prank(burner);
        vm.expectRevert(CustodyReceiptToken.Unauthorized.selector);
        token.burn(alice, 1e18);
    }

    function test_burn_burnsFromArbitraryHolderWithoutAllowance() external {
        acm.giveCallPermission(address(0), MINT_SIG, minter);
        acm.giveCallPermission(address(0), BURN_SIG, burner);
        uint256 amount = 10e18;
        vm.prank(minter);
        token.mint(alice, amount);

        // burner (not alice) burns alice's tokens with no approval from alice.
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, address(0), amount);
        vm.prank(burner);
        token.burn(alice, amount);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_burn_revertsWhenAmountExceedsBalance() external {
        acm.giveCallPermission(address(0), BURN_SIG, burner);
        vm.prank(burner);
        vm.expectRevert("ERC20: burn amount exceeds balance");
        token.burn(alice, 1e18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // setAccessControlManager()
    // ──────────────────────────────────────────────────────────────────────

    function test_setAccessControlManager_revertsWhenCallerIsNotOwner() external {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setAccessControlManager(bob);
    }

    function test_setAccessControlManager_revertsWhenNewAcmIsZeroAddress() external {
        vm.expectRevert(CustodyReceiptToken.ZeroAddressNotAllowed.selector);
        token.setAccessControlManager(address(0));
    }

    function test_setAccessControlManager_updatesAndEmitsEvent() external {
        AccessControlManager newAcm = new AccessControlManager();

        vm.expectEmit(true, true, false, true, address(token));
        emit CustodyReceiptToken.NewAccessControlManager(address(acm), address(newAcm));
        token.setAccessControlManager(address(newAcm));

        assertEq(token.accessControlManager(), address(newAcm));
    }

    // ──────────────────────────────────────────────────────────────────────
    // renounceOwnership() override — empty body so ownership can never be given up
    // (which would permanently lock setAccessControlManager).
    // ──────────────────────────────────────────────────────────────────────

    function test_renounceOwnership_isNoOpAndKeepsCurrentOwner() external {
        token.renounceOwnership();
        assertEq(token.owner(), address(this));
    }
}
