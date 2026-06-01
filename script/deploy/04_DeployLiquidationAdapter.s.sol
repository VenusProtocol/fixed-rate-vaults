// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LiquidationAdapter } from "../../src/institutional-vault/LiquidationAdapter.sol";
import { Addresses } from "../../src/lib/Addresses.sol";
import { InstitutionalVaultDeployments } from "../../src/lib/InstitutionalVaultDeployments.sol";

/**
 * @title DeployLiquidationAdapter
 * @notice Deploys LiquidationAdapter behind a TransparentUpgradeableProxy and initializes it.
 *         Reads the prerequisite controller proxy address from
 *         src/lib/InstitutionalVaultDeployments.sol — update that file by hand after running
 *         03_DeployController.s.sol before running this script.
 *
 *         Governance still needs to execute after deployment:
 *           1. controller.setLiquidationAdapter(<adapterProxy>)
 *           2. controller.acceptPositionTokenOwnership()
 */
contract DeployLiquidationAdapter is Script {
    /// @dev Initial protocol liquidation share — review before mainnet
    uint256 internal constant PROTOCOL_LIQUIDATION_SHARE = 0.5e18;
    /// @dev Initial close factor — review before mainnet
    uint256 internal constant CLOSE_FACTOR = 0.5e18;

    error ControllerProxyMissing();

    function run() public returns (address adapterImpl, address adapterProxy) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        (adapterImpl, adapterProxy) = deploy(block.chainid);
        vm.stopBroadcast();
    }

    /// @notice Deploys the adapter implementation and proxy, and initializes the proxy.
    function deploy(
        uint256 chainId
    ) public returns (address adapterImpl, address adapterProxy) {
        Addresses.NetworkAddresses memory addrs = Addresses.getByChainId(chainId);
        InstitutionalVaultDeployments.Deployments memory d = InstitutionalVaultDeployments.getByChainId(block.chainid);

        // Prerequisite: controller proxy must be deployed first (script 03)
        if (d.controllerProxy == address(0)) revert ControllerProxyMissing();

        // Skip if already deployed on this chain
        if (d.adapterImpl != address(0)) {
            adapterImpl = d.adapterImpl;
            adapterProxy = d.adapterProxy;
            console.log("LiquidationAdapterImpl already deployed:", adapterImpl);
            console.log("LiquidationAdapterProxy already deployed:", adapterProxy);
        } else {
            // 1. Deploy implementation
            adapterImpl = address(new LiquidationAdapter());
            console.log("LiquidationAdapterImpl:", adapterImpl);

            if (d.adapterProxy == address(0)) {
                // 2. Deploy proxy and initialize with controller reference
                bytes memory initData = abi.encodeCall(
                    LiquidationAdapter.initialize,
                    (d.controllerProxy, PROTOCOL_LIQUIDATION_SHARE, CLOSE_FACTOR, addrs.accessControlManager)
                );
                adapterProxy = address(new TransparentUpgradeableProxy(adapterImpl, addrs.proxyAdmin, initData));
                console.log("LiquidationAdapterProxy:", adapterProxy);
            }
        }

        if (adapterProxy == address(0) && d.adapterProxy != address(0)) {
            adapterProxy = d.adapterProxy;
        }

        // 3. Transfer adapter ownership to normalTimelock (skip if already transferred)
        //    Governance completes via acceptOwnership() on the adapter
        address adapterOwner = LiquidationAdapter(adapterProxy).owner();
        if (adapterOwner != addrs.normalTimelock) {
            LiquidationAdapter(adapterProxy).transferOwnership(addrs.normalTimelock);
            console.log("adapter.transferOwnership ->", addrs.normalTimelock);
        } else {
            console.log("adapter ownership already transferred");
        }
    }
}
