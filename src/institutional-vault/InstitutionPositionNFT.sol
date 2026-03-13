// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title InstitutionPositionNFT
/// @notice Singleton ERC-721 representing institution positions in FRIV vaults.
///         One NFT per vault. Holder = institution operator. Governance-gated transfers.
/// @dev Owner is VaultController (sole minter, transfer governance gateway).
///      Not upgradeable — logic is minimal and immutable.
///      Deployed with msg.sender as owner, then ownership transferred to VaultController.
contract InstitutionPositionNFT is ERC721, Ownable2Step {
    // ──────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Auto-incrementing token ID counter (starts at 1).
    uint256 private _nextTokenId;

    /// @notice Maps token ID to its vault address.
    mapping(uint256 => address) private _tokenIdToVault;

    /// @notice Maps vault address to its token ID.
    mapping(address => uint256) private _vaultToTokenId;

    /// @notice Whether governance has approved the transfer of a specific token.
    mapping(uint256 => bool) private _transferApproved;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event PositionNFTMinted(address indexed vault, uint256 indexed tokenId, address indexed institution);
    event PositionTransferApproved(uint256 indexed tokenId);
    event PositionTransferRevoked(uint256 indexed tokenId);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error TransferNotApproved(uint256 tokenId);

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    constructor() ERC721("Venus Institution Position", "vINST") {
        _nextTokenId = 1;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Minting (Owner/VaultController only)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Mints a new NFT to `to` for the given vault.
    /// @param to The initial institution operator address.
    /// @param vault The vault address this NFT represents.
    /// @return tokenId The minted token ID.
    function mint(address to, address vault) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _tokenIdToVault[tokenId] = vault;
        _vaultToTokenId[vault] = tokenId;
        _safeMint(to, tokenId);
        emit PositionNFTMinted(vault, tokenId, to);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Transfer Governance (Owner/VaultController only)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Approves a token for transfer. One-time — resets after transfer.
    /// @param tokenId The token ID to approve for transfer.
    function approveTransfer(uint256 tokenId) external onlyOwner {
        _transferApproved[tokenId] = true;
        emit PositionTransferApproved(tokenId);
    }

    /// @notice Revokes a previously granted transfer approval.
    /// @param tokenId The token ID to revoke approval for.
    function revokeTransferApproval(uint256 tokenId) external onlyOwner {
        _transferApproved[tokenId] = false;
        emit PositionTransferRevoked(tokenId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Transfer Control
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Overrides _beforeTokenTransfer to enforce governance-gated transfers.
    ///      Minting (from == address(0)) is always allowed.
    ///      Transfers require transferApproved[tokenId] == true (one-time use).
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

        // Allow minting
        if (from != address(0)) {
            if (!_transferApproved[firstTokenId]) revert TransferNotApproved(firstTokenId);
            _transferApproved[firstTokenId] = false; // one-time use
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns the vault address associated with a token ID.
    function tokenIdToVault(uint256 tokenId) external view returns (address) {
        return _tokenIdToVault[tokenId];
    }

    /// @notice Returns the token ID associated with a vault address.
    function vaultToTokenId(address vault) external view returns (uint256) {
        return _vaultToTokenId[vault];
    }

    /// @notice Whether governance has approved the transfer of a specific token.
    function transferApproved(uint256 tokenId) external view returns (bool) {
        return _transferApproved[tokenId];
    }
}
