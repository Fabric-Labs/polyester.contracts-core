// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./ZipperFactoryChain.sol";

contract ZipperFactoryVault is AccessControlUpgradeable {
  bytes32 internal constant CREATE_VAULT_ROLE = keccak256("CREATE_VAULT_ROLE");
  bytes32 internal constant CHANGE_VAULT_ROLE = keccak256("CHANGE_VAULT_ROLE");

  ZipperFactoryChain public chain;

  // tokenToVault[chainId][token] = Vault
  mapping(uint16 => mapping(bytes => bytes)) public tokenToVault;
  // vaultToToken[chainId][vault] = Token
  mapping(uint16 => mapping(bytes => bytes)) public vaultToToken;

  event VaultCreated(uint16 indexed chainId, bytes indexed token, bytes indexed vault);
  event VaultChanged(uint16 indexed chainId, bytes indexed token, bytes indexed vault, bytes oldVault);

  error InvalidTokenAddress();
  error InvalidVaultAddress();
  error VaultAlreadyExistsForToken();
  error VaultAlreadyExistsForAnotherToken();
  error VaultDoesNotExistForToken();
  error VaultIsTheSame();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperFactoryVaultInit(ZipperFactoryChain _chain) external initializer {
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);

    chain = _chain;
  }

  function createVault(uint16 chainId, bytes calldata token, bytes calldata vault) external onlyRole(CREATE_VAULT_ROLE) {
    if (!chain.validateEncodedAddress(chainId, token)) revert InvalidTokenAddress();
    if (!chain.validateEncodedAddress(chainId, vault)) revert InvalidVaultAddress();
    if (tokenToVault[chainId][token].length != 0) revert VaultAlreadyExistsForToken();
    if (vaultToToken[chainId][vault].length != 0) revert VaultAlreadyExistsForAnotherToken();

    tokenToVault[chainId][token] = vault;
    vaultToToken[chainId][vault] = token;

    emit VaultCreated(chainId, token, vault);
  }

  function changeVault(uint16 chainId, bytes calldata token, bytes calldata vault) external onlyRole(CHANGE_VAULT_ROLE) {
    if (!chain.validateEncodedAddress(chainId, token)) revert InvalidTokenAddress();
    if (!chain.validateEncodedAddress(chainId, vault)) revert InvalidVaultAddress();

    bytes memory oldVault = tokenToVault[chainId][token];
    if (oldVault.length == 0) revert VaultDoesNotExistForToken();
    if (keccak256(oldVault) == keccak256(vault)) revert VaultIsTheSame();
    if (vaultToToken[chainId][vault].length != 0) revert VaultAlreadyExistsForAnotherToken();

    tokenToVault[chainId][token] = vault;
    vaultToToken[chainId][vault] = token;
    delete vaultToToken[chainId][oldVault];

    emit VaultChanged(chainId, token, vault, oldVault);
  }
}
