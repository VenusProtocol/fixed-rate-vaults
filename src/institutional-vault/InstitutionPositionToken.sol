// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title InstitutionPositionToken
 * @notice Singleton ERC-721 representing institution positions in Institutional Vaults.
 *         One token per vault. Holder = institution operator. Governance-gated transfers.
 * @dev Owner is VaultController (sole minter, transfer governance gateway).
 *      Not upgradeable — logic is minimal and immutable.
 *      Deployed with msg.sender as owner, then ownership transferred to VaultController.
 */
contract InstitutionPositionToken is ERC721, Ownable2Step {
    // ──────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Auto-incrementing token ID counter (starts at 1).
    uint256 public nextTokenId;

    /// @notice Maps token ID to its vault address.
    mapping(uint256 => address) public tokenIdToVault;

    /// @notice Maps vault address to its token ID.
    mapping(address => uint256) public vaultToTokenId;

    /// @notice Whether governance has approved the transfer of a specific token.
    mapping(uint256 => bool) public transferApproved;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event PositionTokenMinted(address indexed vault, uint256 indexed tokenId, address indexed institution);
    event PositionTransferApproved(uint256 indexed tokenId);
    event PositionTransferRevoked(uint256 indexed tokenId);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error TransferNotApproved(uint256 tokenId);
    error OwnershipCannotBeRenounced();

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    constructor() ERC721("Venus Institution Position", "vINST") {
        nextTokenId = 1;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Ownership
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Disabled — renouncing ownership would permanently brick minting and transfer governance.
     * @custom:error OwnershipCannotBeRenounced Always reverts.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ──────────────────────────────────────────────────────────────────────
    // External — Owner-Gated (State-Changing)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Mints a new token to `to` for the given vault.
     * @param to The initial institution operator address.
     * @param vault The vault address this token represents.
     * @return tokenId The minted token ID.
     * @custom:event PositionTokenMinted
     */
    function mint(
        address to,
        address vault
    ) external onlyOwner returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        tokenIdToVault[tokenId] = vault;
        vaultToTokenId[vault] = tokenId;
        _mint(to, tokenId);
        emit PositionTokenMinted(vault, tokenId, to);
    }

    /**
     * @notice Approves a token for transfer. One-time — resets after transfer.
     * @param tokenId The token ID to approve for transfer.
     * @custom:event PositionTransferApproved
     */
    function approveTransfer(
        uint256 tokenId
    ) external onlyOwner {
        transferApproved[tokenId] = true;
        emit PositionTransferApproved(tokenId);
    }

    /**
     * @notice Revokes a previously granted transfer approval.
     * @param tokenId The token ID to revoke approval for.
     * @custom:event PositionTransferRevoked
     */
    function revokeTransferApproval(
        uint256 tokenId
    ) external onlyOwner {
        transferApproved[tokenId] = false;
        emit PositionTransferRevoked(tokenId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal — Transfer Control
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Overrides _beforeTokenTransfer to enforce governance-gated transfers.
     *      Minting (from == address(0)) is always allowed.
     *      Transfers require transferApproved[tokenId] == true (one-time use).
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

        // Allow minting
        if (from != address(0)) {
            if (!transferApproved[firstTokenId]) revert TransferNotApproved(firstTokenId);
            transferApproved[firstTokenId] = false; // one-time use
        }
    }
}
