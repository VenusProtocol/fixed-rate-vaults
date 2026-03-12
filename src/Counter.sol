// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

contract Counter is AccessControlledV8 {
    uint256 public number;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address accessControlManager_
    ) external initializer {
        __AccessControlled_init(accessControlManager_);
        number = 0;
    }

    function setNumber(
        uint256 newNumber
    ) external {
        _checkAccessAllowed("setNumber(uint256)");
        number = newNumber;
    }

    function increment() external {
        _checkAccessAllowed("increment()");
        number++;
    }
}
