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
            vaultImpl: 0xC25b2B657D24380eDd1a1Cff5296385541e85204,
            positionToken: 0x3Ed56f6937fc8549f9325405d1e8E650739647Fa,
            controllerImpl: 0xBD9df626c642591cef3612586CC5e45E9767360f,
            controllerProxy: 0x6D9e91cB766259af42619c14c994E694E57e6E85,
            adapterImpl: 0xdC888D97d6cBA15d2733ce14bF292F8ae6e0450e,
            adapterProxy: 0x17A6222fB8b4b6D852cA54f5bc376a6A2c6224Bd
        });
    }

    function bscTestnet() internal pure returns (Deployments memory) {
        return Deployments({
            vaultImpl: 0xB677627eB4B9D8bfB793966e266C899E7FD484C5,
            positionToken: 0x71dA473257a96e975558C8edD8491AD0880EFCe5,
            controllerImpl: 0xC36dFaCc7a125859C106F29b9F2d874CCF29A55A,
            controllerProxy: 0xf77dED2A00F94e33C392126238360D4642c16Ba2,
            adapterImpl: 0xE789128A050Ba33Ca9f0F690B4157Cac32E97D99,
            adapterProxy: 0x4b302b56315Ca16A0A4565108e62404496916491
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
