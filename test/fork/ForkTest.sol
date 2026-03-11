// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";

/// @notice Base contract for fork tests. Automatically skips when FOUNDRY_PROFILE != "ci".
abstract contract ForkTest is Test {
    function setUp() public virtual {
        string memory profile = vm.envOr("FOUNDRY_PROFILE", string("default"));
        if (keccak256(bytes(profile)) != keccak256(bytes("ci"))) {
            vm.skip(true);
        }
    }
}
