// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { Counter } from "../src/Counter.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    IAccessControlManagerV8
} from "@venusprotocol/governance-contracts/contracts/Governance/IAccessControlManagerV8.sol";

contract CounterTest is Test {
    Counter public counter;
    address public proxyAdmin = makeAddr("proxyAdmin");
    address public accessControlManager = makeAddr("acm");
    address public user = makeAddr("user");

    function setUp() public {
        // Mock ACM to allow all calls
        vm.mockCall(
            accessControlManager,
            abi.encodeWithSelector(IAccessControlManagerV8.isAllowedToCall.selector),
            abi.encode(true)
        );

        // Deploy implementation
        Counter implementation = new Counter();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(Counter.initialize, (accessControlManager));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), proxyAdmin, initData);

        counter = Counter(address(proxy));
    }

    function test_Initialize() public view {
        assertEq(counter.number(), 0);
        assertEq(address(counter.accessControlManager()), accessControlManager);
    }

    function test_Increment() public {
        vm.prank(user);
        counter.increment();
        assertEq(counter.number(), 1);
    }

    function test_SetNumber() public {
        vm.prank(user);
        counter.setNumber(42);
        assertEq(counter.number(), 42);
    }

    function testFuzz_SetNumber(
        uint256 x
    ) public {
        vm.prank(user);
        counter.setNumber(x);
        assertEq(counter.number(), x);
    }

    function test_RevertWhenNotAllowed() public {
        // Override mock to deny access
        vm.mockCall(
            accessControlManager,
            abi.encodeWithSelector(IAccessControlManagerV8.isAllowedToCall.selector),
            abi.encode(false)
        );

        vm.prank(user);
        vm.expectRevert();
        counter.increment();
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        counter.initialize(accessControlManager);
    }

    function test_ImplementationCannotBeInitialized() public {
        Counter implementation = new Counter();
        vm.expectRevert();
        implementation.initialize(accessControlManager);
    }
}
