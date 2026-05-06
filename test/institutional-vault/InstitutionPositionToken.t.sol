// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";

import { InstitutionPositionToken } from "../../src/institutional-vault/InstitutionPositionToken.sol";

contract InstitutionPositionTokenTest is Test {
    InstitutionPositionToken internal posToken;

    address internal owner; // acts as controller (sole owner)
    address internal institution;
    address internal other;
    address internal newInstitution;

    function setUp() external {
        owner = address(this);
        institution = makeAddr("institution");
        other = makeAddr("other");
        newInstitution = makeAddr("newInstitution");

        posToken = new InstitutionPositionToken();
        // test contract is already the owner (constructor sets msg.sender as owner)
    }

    // ──────────────────────────────────────────────────────────────────────
    // Mint
    // ──────────────────────────────────────────────────────────────────────

    function test_mint_byOwner() external {
        address vaultAddr = makeAddr("vault");

        vm.expectEmit(true, true, true, true);
        emit InstitutionPositionToken.PositionTokenMinted(vaultAddr, 1, institution);

        uint256 tokenId = posToken.mint(institution, vaultAddr);

        assertEq(tokenId, 1);
        assertEq(posToken.ownerOf(1), institution);
        assertEq(posToken.tokenIdToVault(1), vaultAddr);
        assertEq(posToken.vaultToTokenId(vaultAddr), 1);
        assertEq(posToken.nextTokenId(), 2);
    }

    function test_mint_incrementsTokenId() external {
        address vault1 = makeAddr("vault1");
        address vault2 = makeAddr("vault2");

        uint256 id1 = posToken.mint(institution, vault1);
        uint256 id2 = posToken.mint(institution, vault2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(posToken.nextTokenId(), 3);
    }

    function test_mint_revertsIfNotOwner() external {
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        posToken.mint(institution, makeAddr("vault"));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Transfer approval
    // ──────────────────────────────────────────────────────────────────────

    function test_approveTransfer_byOwner() external {
        posToken.mint(institution, makeAddr("vault"));

        vm.expectEmit(true, true, false, false);
        emit InstitutionPositionToken.PositionTransferApproved(1, newInstitution);

        posToken.approveTransfer(1, newInstitution);

        assertEq(posToken.approvedRecipient(1), newInstitution);
    }

    function test_approveTransfer_revertsIfNotOwner() external {
        posToken.mint(institution, makeAddr("vault"));

        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        posToken.approveTransfer(1, newInstitution);
    }

    function test_approveTransfer_revertsForZeroRecipient() external {
        posToken.mint(institution, makeAddr("vault"));

        vm.expectRevert(InstitutionPositionToken.ZeroAddress.selector);
        posToken.approveTransfer(1, address(0));
    }

    function test_revokeTransferApproval() external {
        posToken.mint(institution, makeAddr("vault"));
        posToken.approveTransfer(1, newInstitution);
        assertEq(posToken.approvedRecipient(1), newInstitution);

        vm.expectEmit(true, false, false, false);
        emit InstitutionPositionToken.PositionTransferRevoked(1);

        posToken.revokeTransferApproval(1);

        assertEq(posToken.approvedRecipient(1), address(0));
    }

    function test_revokeTransferApproval_revertsIfNotOwner() external {
        posToken.mint(institution, makeAddr("vault"));
        posToken.approveTransfer(1, newInstitution);

        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        posToken.revokeTransferApproval(1);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Transfer mechanics
    // ──────────────────────────────────────────────────────────────────────

    function test_transferFrom_withApproval() external {
        posToken.mint(institution, makeAddr("vault"));
        posToken.approveTransfer(1, newInstitution);

        vm.prank(institution);
        posToken.transferFrom(institution, newInstitution, 1);

        assertEq(posToken.ownerOf(1), newInstitution);
    }

    function test_transferFrom_withoutApproval_reverts() external {
        posToken.mint(institution, makeAddr("vault"));

        vm.prank(institution);
        vm.expectRevert(abi.encodeWithSelector(InstitutionPositionToken.TransferNotApproved.selector, 1));
        posToken.transferFrom(institution, newInstitution, 1);
    }

    function test_transferFrom_revertsForUnapprovedRecipient() external {
        posToken.mint(institution, makeAddr("vault"));
        // Approval is bound to `newInstitution`; sending to `other` must revert.
        posToken.approveTransfer(1, newInstitution);

        vm.prank(institution);
        vm.expectRevert(abi.encodeWithSelector(InstitutionPositionToken.TransferNotApproved.selector, 1));
        posToken.transferFrom(institution, other, 1);
    }

    function test_approvalConsumedAfterTransfer() external {
        posToken.mint(institution, makeAddr("vault"));
        posToken.approveTransfer(1, newInstitution);

        vm.prank(institution);
        posToken.transferFrom(institution, newInstitution, 1);

        // Recipient slot must be cleared after the transfer.
        assertEq(posToken.approvedRecipient(1), address(0));

        // A second transfer should now revert until governance re-approves.
        posToken.approveTransfer(1, other);
        posToken.revokeTransferApproval(1);
        vm.prank(newInstitution);
        vm.expectRevert(abi.encodeWithSelector(InstitutionPositionToken.TransferNotApproved.selector, 1));
        posToken.transferFrom(newInstitution, other, 1);
    }

    function test_safeTransferFrom_withApproval() external {
        posToken.mint(institution, makeAddr("vault"));
        posToken.approveTransfer(1, newInstitution);

        vm.prank(institution);
        posToken.safeTransferFrom(institution, newInstitution, 1);

        assertEq(posToken.ownerOf(1), newInstitution);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Ownership mechanics
    // ──────────────────────────────────────────────────────────────────────

    function test_ownershipTransfer_twoStep() external {
        address newOwner = makeAddr("newOwner");

        posToken.transferOwnership(newOwner);
        // Ownership not yet transferred — pending.
        assertEq(posToken.owner(), owner);
        assertEq(posToken.pendingOwner(), newOwner);

        vm.prank(newOwner);
        posToken.acceptOwnership();

        assertEq(posToken.owner(), newOwner);
    }

    function test_cannotRenounceOwnership() external {
        vm.expectRevert(InstitutionPositionToken.OwnershipCannotBeRenounced.selector);
        posToken.renounceOwnership();
    }
}
