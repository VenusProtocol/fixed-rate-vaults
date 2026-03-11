// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { Counter } from "../src/Counter.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IAccessControlManagerV8 } from
    "@venusprotocol/governance-contracts/contracts/Governance/IAccessControlManagerV8.sol";

contract CounterForkTest is Test {
    Counter public counter;
    uint256 bscFork;

    address public proxyAdmin = makeAddr("proxyAdmin");
    address public accessControlManager = makeAddr("acm");
    address public user = makeAddr("user");

    function setUp() public {
        bscFork = vm.createFork("bsc_mainnet", 85834131);
        vm.selectFork(bscFork);

        // Mock ACM to allow all calls
        vm.mockCall(
            accessControlManager,
            abi.encodeWithSelector(IAccessControlManagerV8.isAllowedToCall.selector),
            abi.encode(true)
        );

        // Deploy implementation + proxy
        Counter implementation = new Counter();
        bytes memory initData = abi.encodeCall(Counter.initialize, (accessControlManager));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), proxyAdmin, initData);

        counter = Counter(address(proxy));
    }

    function test_ForkIsActive() public view {
        assertEq(vm.activeFork(), bscFork);
        assertEq(block.chainid, 56);
    }

    function test_DeployAndIncrement() public {
        assertEq(counter.number(), 0);

        vm.prank(user);
        counter.increment();
        assertEq(counter.number(), 1);

        vm.prank(user);
        counter.increment();
        assertEq(counter.number(), 2);
    }

    function test_SetNumber() public {
        vm.prank(user);
        counter.setNumber(42);
        assertEq(counter.number(), 42);
    }
}
