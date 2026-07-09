// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";

import { InstitutionPositionToken } from "../../src/institutional-vault/InstitutionPositionToken.sol";
import { InstitutionalVaultDeployments } from "../../src/lib/InstitutionalVaultDeployments.sol";

/**
 * @title DeployInstitutionPositionToken
 * @notice Deploys the standalone InstitutionPositionToken (ERC-721, Ownable2Step). Ownership
 *         transfer to the VaultController happens in the orchestrator script after the
 *         controller proxy address is known.
 */
contract DeployInstitutionPositionToken is Script {
    function run() public returns (address token) {
        // Skip if already deployed on this chain
        InstitutionalVaultDeployments.Deployments memory d = InstitutionalVaultDeployments.getByChainId(block.chainid);
        if (d.positionToken != address(0)) {
            console.log("InstitutionPositionToken already deployed:", d.positionToken);
            return d.positionToken;
        }

        // Deploy standalone ERC-721 (deployer is initial owner)
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        token = address(new InstitutionPositionToken());
        vm.stopBroadcast();
        console.log("InstitutionPositionToken:", token);
    }
}
