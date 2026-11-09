// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Script, console } from "forge-std/Script.sol";

import { CustodyReceiptToken } from "../../src/CustodyReceiptToken.sol";
import { Addresses } from "../../src/lib/Addresses.sol";

/**
 * @title DeployCustodyReceiptToken
 * @notice Deploys a standalone CustodyReceiptToken — a mint/burn ERC-20 that mirrors an asset held
 *         in off-chain custody, gated by the Venus AccessControlManager.
 *         The deployer is the initial owner; ownership is transferred to the NormalTimelock so
 *         governance controls `setAccessControlManager`. Mint/burn permissions are granted separately
 *         via the AccessControlManager.
 */
contract DeployCustodyReceiptToken is Script {
    /// @notice Name of the receipt token to deploy.
    string internal constant TOKEN_NAME = "Ceffu Custody BTC for Venus";

    /// @notice Symbol of the receipt token to deploy.
    string internal constant TOKEN_SYMBOL = "vceBTC";

    /// @notice Decimals of the receipt token to deploy.
    uint8 internal constant TOKEN_DECIMALS = 18;

    function run() public returns (address token) {
        Addresses.NetworkAddresses memory addrs = Addresses.getByChainId(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        CustodyReceiptToken receiptToken =
            new CustodyReceiptToken(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, addrs.accessControlManager);

        // Hand ownership to governance; the transfer is completed by NormalTimelock via acceptOwnership.
        receiptToken.transferOwnership(addrs.normalTimelock);

        vm.stopBroadcast();

        token = address(receiptToken);
        console.log("CustodyReceiptToken:", token);
    }
}
