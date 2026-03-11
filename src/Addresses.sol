// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

library Addresses {
    struct NetworkAddresses {
        address proxyAdmin;
        address normalTimelock;
        address accessControlManager;
    }

    function bscMainnet() internal pure returns (NetworkAddresses memory) {
        return NetworkAddresses({
            proxyAdmin: 0x6beb6D2695B67FEb73ad4f172E8E2975497187e4,
            normalTimelock: 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396,
            accessControlManager: 0x4788629ABc6cFCA10F9f969efdEAa1cF70c23555
        });
    }

    function bscTestnet() internal pure returns (NetworkAddresses memory) {
        return NetworkAddresses({
            proxyAdmin: 0x7877fFd62649b6A1557B55D4c20fcBaB17344C91,
            normalTimelock: 0xce10739590001705F7FF231611ba4A48B2820327,
            accessControlManager: 0x45f8a08F534f34A97187626E05d4b6648Eeaa9AA
        });
    }

    function getByChainId(uint256 chainId) internal pure returns (NetworkAddresses memory) {
        if (chainId == 56) return bscMainnet();
        if (chainId == 97) return bscTestnet();
        revert("Addresses: unsupported chain");
    }
}
