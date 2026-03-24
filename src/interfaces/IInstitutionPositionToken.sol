// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IInstitutionPositionToken
/// @notice Interface for the singleton ERC-721 that represents institution positions in Institutional Vaults.
interface IInstitutionPositionToken is IERC721 {
    // ──────────────────────────────────────────────────────────────────────
    // Minting (VaultController only)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Mints a new token to `to` for the given vault. Called during createVault().
     * @param to The initial institution operator address.
     * @param vault The vault address this token represents.
     * @return tokenId The minted token ID.
     * @custom:event PositionTokenMinted Emitted with vault, tokenId, and institution.
     */
    function mint(
        address to,
        address vault
    ) external returns (uint256 tokenId);

    // ──────────────────────────────────────────────────────────────────────
    // Transfer Governance (VaultController only)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets `transferApproved[tokenId] = true`. Required before any transfer can occur.
     * @param tokenId The token ID to approve for transfer.
     * @custom:event PositionTransferApproved Emitted with the token ID.
     */
    function approveTransfer(
        uint256 tokenId
    ) external;

    /**
     * @notice Revokes a previously granted transfer approval.
     * @param tokenId The token ID to revoke approval for.
     * @custom:event PositionTransferRevoked Emitted with the token ID.
     */
    function revokeTransferApproval(
        uint256 tokenId
    ) external;

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns the vault address associated with a token ID.
    function tokenIdToVault(
        uint256 tokenId
    ) external view returns (address);

    /// @notice Returns the token ID associated with a vault address.
    function vaultToTokenId(
        address vault
    ) external view returns (uint256);

    /// @notice Whether governance has approved the transfer of a specific token.
    function transferApproved(
        uint256 tokenId
    ) external view returns (bool);
}
