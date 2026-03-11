# Fixed Rate Vaults

Smart contracts for fixed-rate lending vaults built on the [Venus Protocol](https://venus.io) ecosystem.

## Overview

Fixed Rate Vaults enable users to lock in fixed interest rates for borrowing and lending within the Venus Protocol. These contracts provide predictable yield and borrowing costs by abstracting the variable-rate nature of the underlying Venus markets.

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity 0.8.25

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Environment Setup

Copy `.env.example` to `.env` and fill in your values:

```shell
cp .env.example .env
```

Required variables:
- `PRIVATE_KEY` — deployer private key
- `ETHERSCAN_API_KEY` — for contract verification (Etherscan V2 API key works across chains)
- `RPC_URL_*` — RPC endpoints for each network

### Deploy

The `PRIVATE_KEY` is loaded from `.env` inside the deploy script via `vm.envUint("PRIVATE_KEY")`, so no need to pass it on the command line:

```solidity
uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
vm.startBroadcast(deployerPrivateKey);
```

```shell
forge script script/Counter.s.sol:CounterScript --rpc-url bsc_testnet --broadcast --verify
```

Alternatively, you can skip `vm.envUint` in the script and pass the key directly:

```shell
forge script script/Counter.s.sol:CounterScript --rpc-url bsc_testnet --private-key $PRIVATE_KEY --broadcast --verify
```

### Verify

```shell
forge verify-contract <contract-address> <ContractName> --chain bsc_testnet
```

## Links

- [Venus Protocol](https://venus.io)
- [Venus GitHub](https://github.com/VenusProtocol)
- [Foundry Book](https://book.getfoundry.sh/)
