// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";

import { CustodyReceiptToken } from "../../src/CustodyReceiptToken.sol";
import { Addresses } from "../../src/lib/Addresses.sol";

/**
 * @title DeployCustodyReceiptToken
 * @notice Deploys the CustodyReceiptTokens listed in `_tokens` — mint/burn ERC-20s that mirror an asset held
 *         in off-chain custody, gated by the Venus AccessControlManager.
 *         The deployer is the initial owner; ownership is transferred to the NormalTimelock so
 *         governance controls `setAccessControlManager`. Mint/burn permissions are granted separately
 *         via the AccessControlManager.
 * @dev To deploy a new token, append it to `_tokens` and re-run. A token already recorded under its symbol in
 *      `deployments/<network>_addresses.json` is skipped, so the earlier ones are not deployed again.
 */
contract DeployCustodyReceiptToken is Script {
    struct Token {
        string name;
        string symbol;
        uint8 decimals;
    }

    /// @notice Thrown when the script runs on a chain with no deployments file.
    error UnsupportedChain(uint256 chainId);

    function run() public {
        Addresses.NetworkAddresses memory addrs = Addresses.getByChainId(block.chainid);
        string memory deployments = vm.readFile(_deploymentsFile(block.chainid));
        Token[] memory tokens = _tokens();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        for (uint256 i; i < tokens.length; ++i) {
            Token memory t = tokens[i];
            string memory key = string.concat(".addresses.", t.symbol);
            if (vm.keyExistsJson(deployments, key)) {
                console.log("Already deployed:", t.symbol, vm.parseJsonAddress(deployments, key));
                continue;
            }

            CustodyReceiptToken token =
                new CustodyReceiptToken(t.name, t.symbol, t.decimals, addrs.accessControlManager);

            // Ownable2Step, so this only nominates; the NormalTimelock accepts in a VIP.
            token.transferOwnership(addrs.normalTimelock);
            console.log("Deployed:", t.symbol, address(token));
        }

        vm.stopBroadcast();
    }

    function _tokens() internal pure returns (Token[] memory tokens) {
        tokens = new Token[](2);
        tokens[0] = Token("Ceffu Custody BTC for Venus", "vceBTC", 18);
        // Collateral of the LTP institutional vault
        tokens[1] = Token("Custodian BTC", "ctBTC", 18);
    }

    /**
     * @notice Returns the deployments file of `chainId`, read to skip tokens already deployed there.
     * @param chainId The chain the script runs on.
     * @return The path of that chain's deployments file.
     * @custom:error UnsupportedChain if `chainId` is not BSC mainnet (56) or BSC testnet (97).
     */
    function _deploymentsFile(
        uint256 chainId
    ) internal pure returns (string memory) {
        if (chainId == 56) return "deployments/bsc_mainnet_addresses.json";
        if (chainId == 97) return "deployments/bsc_testnet_addresses.json";
        revert UnsupportedChain(chainId);
    }
}
