// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";

import { InstitutionalLoanVault } from "../../src/institutional-vault/InstitutionalLoanVault.sol";
import { InstitutionalVaultDeployments } from "../../src/lib/InstitutionalVaultDeployments.sol";

/**
 * @title DeployInstitutionalLoanVault
 * @notice Deploys the InstitutionalLoanVault implementation. Used as a logic template for
 *         EIP-1167 minimal proxy clones — NOT wrapped in TransparentUpgradeableProxy.
 */
contract DeployInstitutionalLoanVault is Script {
    function run() public returns (address impl) {
        // Skip if already deployed on this chain
        InstitutionalVaultDeployments.Deployments memory d = InstitutionalVaultDeployments.getByChainId(block.chainid);
        if (d.vaultImpl != address(0)) {
            console.log("InstitutionalLoanVault impl already deployed:", d.vaultImpl);
            return d.vaultImpl;
        }

        // Deploy implementation (clone template, not behind a proxy)
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        impl = address(new InstitutionalLoanVault());
        vm.stopBroadcast();
        console.log("InstitutionalLoanVault impl:", impl);
    }
}
