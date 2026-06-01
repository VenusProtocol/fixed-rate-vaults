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
            vaultImpl: 0x10d63B1203E5A0719AbbE927C8BFc87135b2F129,
            positionToken: 0x3Ed56f6937fc8549f9325405d1e8E650739647Fa,
            controllerImpl: 0x9e1ECb2671AfabE9eaAA2e74Cb2318a9b6A2Eb5d,
            controllerProxy: 0x6D9e91cB766259af42619c14c994E694E57e6E85,
            adapterImpl: 0xdC888D97d6cBA15d2733ce14bF292F8ae6e0450e,
            adapterProxy: 0x17A6222fB8b4b6D852cA54f5bc376a6A2c6224Bd
        });
    }

    function bscTestnet() internal pure returns (Deployments memory) {
        return Deployments({
            vaultImpl: 0x1e311a618e748367D40F84cdb32211F1376B996F,
            positionToken: 0x71dA473257a96e975558C8edD8491AD0880EFCe5,
            controllerImpl: 0xb92CEd5Fc18b58323B056168764fb5320eDfD1aF,
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
