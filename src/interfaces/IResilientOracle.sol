// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

/// @notice Minimal interface for Venus ResilientOracle price queries.
interface IResilientOracle {
    /// @notice Returns the USD price of the given asset, scaled to 36 - asset.decimals().
    function getPrice(address asset) external view returns (uint256);
}
