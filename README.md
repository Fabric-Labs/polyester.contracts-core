# polyester.contracts-core

Solidity source of the Polychain contracts behind Zipper bridge deposits and withdrawals, the `FundingAccount` uAsset ledger and its `GuardRegistry` approvals. The repository contains the contract source, the configuration needed to compile it, and scripts for a local deployment; tests, live deployment scripts and network configuration are maintained separately.

## Contracts

| File | Purpose |
| --- | --- |
| `src/active/bridge/ZipperEndpoint.sol` | Deposit and withdrawal requests, validation results, execution, burns and withdrawal refunds |
| `src/active/bridge/ZipperFactoryKey.sol` | Deposit addresses and their resolution to Polychain accounts, including address retirement |
| `src/active/bridge/ZipperFactoryFee.sol` | Base fees and the per-request fee locking and settlement for deposits and withdrawals |
| `src/active/bridge/ZipperFactoryToken.sol` | zToken creation, and zToken mint and burn for bridge requests |
| `src/active/bridge/ZipperFactoryChain.sol` | Supported chains and address encoding and validation |
| `src/active/bridge/DepositBatchRouter.sol` | Batched submission of deposit requests |
| `src/active/bridge/ZipperFactoryVault.sol` | Vault registry |
| `src/active/bridge/ZipperFactorySubVault.sol` | Sub-vault registry |
| `src/active/tokens/ZToken.sol` | The zToken ERC-20 |
| `src/active/tokens/SToken.sol` | Test token that stands in for a source-chain token in the local scripts; not part of the bridge |
| `src/active/account/FundingAccount.sol` | uAsset ledger: bridge mint credit, zToken deposit and withdrawal, internal transfers, withdrawal to chain, delegates and allowlists |
| `src/active/guard/GuardRegistry.sol` | Guard-signed approvals for protected `FundingAccount` actions |

Interfaces are under `src/active/*/interfaces/`, and shared helpers under `src/active/libs/` and `src/active/utils/`.

## Build

Requirements: Node.js and Yarn 1.

```bash
yarn install
yarn compile
```

The build uses Hardhat 2.26.3, Solidity 0.8.22 with the optimizer enabled at 200 runs, and OpenZeppelin `@openzeppelin/contracts` and `@openzeppelin/contracts-upgradeable` 5.1.0. Hardhat reads sources from `src/active`.

## Local deployment

The scripts run on the in-process Hardhat network only and refuse any other network. They use Hardhat's test accounts.

```bash
yarn deploy:local
yarn flow:local
```

- `scripts/deploy_local.js` deploys and links the contracts, registers one EVM chain with its address family, deploys an `SToken` as its source token, and creates and configures the zToken. It exports `deployLocal()`, which returns the accounts, the contracts and the configured values, so a Hardhat test can start from a fresh deployment.
- `scripts/flow_local.js` runs one deposit, from the source transfer to the uAsset credit, and one withdrawal, from `withdrawToChain` to the burn, and checks the resulting balances.

Test accounts take the relayer, validator and executor steps directly, without the off-chain checks. Validators vote with `validateRequest`. Each proxy has its own `ProxyAdmin`.

## Security

Report vulnerabilities through the Zipper bug bounty program. The program page defines the assets, impacts and rules in scope.
