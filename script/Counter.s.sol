// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { Counter } from "../src/Counter.sol";
import { Addresses } from "../src/lib/Addresses.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract CounterScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Addresses.NetworkAddresses memory addrs = Addresses.getByChainId(block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        Counter implementation = new Counter();
        console.log("Implementation deployed at:", address(implementation));

        // Deploy proxy with initialize call
        bytes memory initData = abi.encodeCall(Counter.initialize, (addrs.accessControlManager));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), addrs.proxyAdmin, initData);
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();
    }
}
