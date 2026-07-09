// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IProtocolShareReserve } from "../../../src/interfaces/IProtocolShareReserve.sol";

/// @dev PSR mock that records calls and can be forced to revert.
contract MockPSR is IProtocolShareReserve {
    uint256 public callCount;
    bool public shouldRevert;

    function setShouldRevert(
        bool flag
    ) external {
        shouldRevert = flag;
    }

    function updateAssetsState(
        address,
        address,
        IncomeType
    ) external override {
        if (shouldRevert) revert("MockPSR: forced revert");
        ++callCount;
    }
}
