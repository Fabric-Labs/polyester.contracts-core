# polyester.contracts-core

Solidity source of the Polychain contracts behind Zipper bridge deposits and withdrawals, the `FundingAccount` uAsset ledger and its `GuardRegistry` approvals. The repository contains only the contract source and the configuration needed to compile it; tests, deployment scripts and network configuration are maintained separately.

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

## Security

Report vulnerabilities through the Zipper bug bounty program. The program page defines the assets, impacts and rules in scope.
