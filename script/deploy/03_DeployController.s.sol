// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { InstitutionPositionToken } from "../../src/institutional-vault/InstitutionPositionToken.sol";

import { InstitutionalVaultController } from "../../src/institutional-vault/InstitutionalVaultController.sol";
import { Addresses } from "../../src/lib/Addresses.sol";
import { InstitutionalVaultDeployments } from "../../src/lib/InstitutionalVaultDeployments.sol";

/**
 * @title DeployController
 * @notice Deploys InstitutionalVaultController behind a TransparentUpgradeableProxy and
 *         initializes it. Reads the prerequisite vault impl and position token addresses from
 *         src/lib/InstitutionalVaultDeployments.sol — update that file by hand after the
 *         standalone deployments (scripts 01 and 02) before running this script.
 *
 *         After running, record the returned controllerImpl and controllerProxy addresses in
 *         InstitutionalVaultDeployments.sol before running 04_DeployLiquidationAdapter.s.sol.
 */
contract DeployController is Script {
    error VaultImplMissing();
    error PositionTokenMissing();

    function run() public returns (address controllerImpl, address controllerProxy) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        (controllerImpl, controllerProxy) = deploy(block.chainid);
        vm.stopBroadcast();
    }

    /// @notice Deploys the controller implementation and proxy, and initializes the proxy.
    function deploy(
        uint256 chainId
    ) public returns (address controllerImpl, address controllerProxy) {
        Addresses.NetworkAddresses memory addrs = Addresses.getByChainId(chainId);
        InstitutionalVaultDeployments.Deployments memory d = InstitutionalVaultDeployments.getByChainId(block.chainid);

        // Prerequisites: vault impl and position token must be deployed first (scripts 01, 02)
        if (d.vaultImpl == address(0)) revert VaultImplMissing();
        if (d.positionToken == address(0)) revert PositionTokenMissing();

        // Skip if already deployed on this chain
        if (d.controllerImpl != address(0)) {
            controllerImpl = d.controllerImpl;
            controllerProxy = d.controllerProxy;
            console.log("VaultControllerImpl already deployed:", controllerImpl);
            console.log("VaultControllerProxy already deployed:", controllerProxy);
        } else {
            // 1. Deploy implementation
            controllerImpl = address(new InstitutionalVaultController());
            console.log("VaultControllerImpl:", controllerImpl);

            if (d.controllerProxy == address(0)) {
                // 2. Deploy proxy and initialize in one step
                bytes memory initData = abi.encodeCall(
                    InstitutionalVaultController.initialize,
                    (
                        d.vaultImpl,
                        addrs.resilientOracle,
                        addrs.protocolShareReserve,
                        addrs.unitroller,
                        addrs.treasury,
                        d.positionToken,
                        addrs.accessControlManager
                    )
                );
                controllerProxy = address(new TransparentUpgradeableProxy(controllerImpl, addrs.proxyAdmin, initData));
                console.log("VaultControllerProxy:", controllerProxy);
            }
        }

        // 3. Transfer position token ownership to controller (skip if already transferred)
        address tokenOwner = InstitutionPositionToken(d.positionToken).owner();
        if (tokenOwner != addrs.normalTimelock) {
            InstitutionPositionToken(d.positionToken).transferOwnership(controllerProxy);
            console.log("positionToken.transferOwnership ->", controllerProxy);
        } else {
            console.log("positionToken ownership already transferred, owner:", tokenOwner);
        }

        // 4. Transfer controller ownership to normalTimelock (skip if already transferred)
        //    Governance completes via acceptOwnership() on the controller
        address controllerOwner = InstitutionalVaultController(controllerProxy).owner();
        if (controllerOwner != addrs.normalTimelock) {
            InstitutionalVaultController(controllerProxy).transferOwnership(addrs.normalTimelock);
            console.log("controller.transferOwnership ->", addrs.normalTimelock);
        } else {
            console.log("controller ownership already transferred");
        }
    }
}
