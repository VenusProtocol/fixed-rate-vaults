// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

/**
 * @title InstitutionalVaultDeployments
 * @notice Manually-maintained registry of deployed Institutional Vault contract addresses per chain.
 *         Update this file by hand after each deployment so downstream scripts can pick the
 *         correct addresses for cross-contract wiring (e.g. controller + adapter init).
 */
library InstitutionalVaultDeployments {
    struct Deployments {
        address vaultImpl;
        address positionToken;
        address controllerImpl;
        address controllerProxy;
        address adapterImpl;
        address adapterProxy;
    }

    function bscMainnet() internal pure returns (Deployments memory) {
        return Deployments({
            vaultImpl: address(0),
            positionToken: address(0),
            controllerImpl: address(0),
            controllerProxy: address(0),
            adapterImpl: address(0),
            adapterProxy: address(0)
        });
    }

    function bscTestnet() internal pure returns (Deployments memory) {
        return Deployments({
            vaultImpl: 0x8100e5323946cbBB1eeBc5275BCD7b064908eeEc,
            positionToken: 0x377180882397718D4061d815Df32CF7DF8492f4F,
            controllerImpl: 0xA42E7af0df4E8A74d6Aa8b3054537EFae77515dd,
            controllerProxy: 0x36bA78812Ffff64B9ec060a1F07FcFa2012f6F89,
            adapterImpl: 0xDD834A8360Ce77293613886b5B1c9a0A0EB3Dca4,
            adapterProxy: 0x69d79D60abD5A7080C9f178a44c5f1bf1A461541
        });
    }

    function getByChainId(
        uint256 chainId
    ) internal pure returns (Deployments memory) {
        if (chainId == 56) return bscMainnet();
        if (chainId == 97) return bscTestnet();
        revert("InstitutionalVaultDeployments: unsupported chain");
    }
}
