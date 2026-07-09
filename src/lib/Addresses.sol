// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

library Addresses {
    struct NetworkAddresses {
        address proxyAdmin;
        address normalTimelock;
        address accessControlManager;
        address resilientOracle;
        address protocolShareReserve;
        address unitroller;
        address treasury;
    }

    function bscMainnet() internal pure returns (NetworkAddresses memory) {
        return NetworkAddresses({
            proxyAdmin: 0x6beb6D2695B67FEb73ad4f172E8E2975497187e4,
            normalTimelock: 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396,
            accessControlManager: 0x4788629ABc6cFCA10F9f969efdEAa1cF70c23555,
            resilientOracle: 0x6592b5DE802159F3E74B2486b091D11a8256ab8A,
            protocolShareReserve: 0xCa01D5A9A248a830E9D93231e791B1afFed7c446,
            unitroller: 0xfD36E2c2a6789Db23113685031d7F16329158384,
            treasury: 0xF322942f644A996A617BD29c16bd7d231d9F35E9
        });
    }

    function bscTestnet() internal pure returns (NetworkAddresses memory) {
        return NetworkAddresses({
            proxyAdmin: 0x7877fFd62649b6A1557B55D4c20fcBaB17344C91,
            normalTimelock: 0xce10739590001705F7FF231611ba4A48B2820327,
            accessControlManager: 0x45f8a08F534f34A97187626E05d4b6648Eeaa9AA,
            resilientOracle: 0x3cD69251D04A28d887Ac14cbe2E14c52F3D57823,
            protocolShareReserve: 0x25c7c7D6Bf710949fD7f03364E9BA19a1b3c10E3,
            unitroller: 0x94d1820b2D1c7c7452A163983Dc888CEC546b77D,
            treasury: 0x8b293600C50D6fbdc6Ed4251cc75ECe29880276f
        });
    }

    function getByChainId(
        uint256 chainId
    ) internal pure returns (NetworkAddresses memory) {
        if (chainId == 56) return bscMainnet();
        if (chainId == 97) return bscTestnet();
        revert("Addresses: unsupported chain");
    }
}
