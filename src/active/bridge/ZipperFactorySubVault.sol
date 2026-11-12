// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./ZipperFactoryChain.sol";

contract ZipperFactorySubVault is AccessControlUpgradeable {
  bytes32 internal constant ADD_SUB_VAULT_ROLE = keccak256("ADD_SUB_VAULT_ROLE");
  bytes32 internal constant EDITOR_ROLE = keccak256("EDITOR_ROLE");

  uint8 public constant MAX_SUB_VAULTS = 50;

  struct SubVaultEntry {
    bytes vault;
    bool isEnabled;
  }

  ZipperFactoryChain public chain;

  // tokenToSubVaults[chainId][token] = SubVaultEntry[]
  mapping(uint16 => mapping(bytes => SubVaultEntry[])) internal _tokenToSubVaults;
  // subVaultToToken[chainId][vault] = token
  mapping(uint16 => mapping(bytes => bytes)) public subVaultToToken;

  event SubVaultAdded(uint16 indexed chainId, bytes indexed token, bytes indexed vault, uint256 index);
  event SubVaultDisabled(uint16 indexed chainId, bytes indexed token, uint256 index);
  event SubVaultEnabled(uint16 indexed chainId, bytes indexed token, uint256 index);

  error InvalidTokenAddress();
  error InvalidVaultAddress();
  error EmptyVaultsArray();
  error IndexOutOfBounds();
  error AlreadyDisabled();
  error AlreadyEnabled();
  error MaxSubVaultsReached();
  error VaultAlreadyRegistered();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperFactorySubVaultInit(ZipperFactoryChain _chain) external initializer {
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(EDITOR_ROLE, sender_);

    chain = _chain;
  }

  function addSubVault(uint16 chainId, bytes calldata token, bytes calldata vault) external onlyRole(ADD_SUB_VAULT_ROLE) {
    _addSubVault(chainId, token, vault);
  }

  function addSubVaults(uint16 chainId, bytes calldata token, bytes[] calldata vaults) external onlyRole(ADD_SUB_VAULT_ROLE) {
    if (vaults.length == 0) revert EmptyVaultsArray();
    for (uint256 i = 0; i < vaults.length; i++) {
      _addSubVault(chainId, token, vaults[i]);
    }
  }

  function disableSubVault(uint16 chainId, bytes calldata token, uint256 index) external onlyRole(EDITOR_ROLE) {
    SubVaultEntry[] storage entries = _tokenToSubVaults[chainId][token];
    if (index >= entries.length) revert IndexOutOfBounds();
    if (!entries[index].isEnabled) revert AlreadyDisabled();
    entries[index].isEnabled = false;
    emit SubVaultDisabled(chainId, token, index);
  }

  function enableSubVault(uint16 chainId, bytes calldata token, uint256 index) external onlyRole(EDITOR_ROLE) {
    SubVaultEntry[] storage entries = _tokenToSubVaults[chainId][token];
    if (index >= entries.length) revert IndexOutOfBounds();
    if (entries[index].isEnabled) revert AlreadyEnabled();
    entries[index].isEnabled = true;
    emit SubVaultEnabled(chainId, token, index);
  }

  function getSubVaults(uint16 chainId, bytes calldata token) external view returns (SubVaultEntry[] memory) {
    return _tokenToSubVaults[chainId][token];
  }

  function getEnabledSubVaults(uint16 chainId, bytes calldata token) external view returns (SubVaultEntry[] memory) {
    SubVaultEntry[] storage all = _tokenToSubVaults[chainId][token];
    uint256 count = 0;
    for (uint256 i = 0; i < all.length; i++) {
      if (all[i].isEnabled) count++;
    }
    SubVaultEntry[] memory result = new SubVaultEntry[](count);
    uint256 idx = 0;
    for (uint256 i = 0; i < all.length; i++) {
      if (all[i].isEnabled) {
        result[idx] = all[i];
        idx++;
      }
    }
    return result;
  }

  function isAllowedVault(uint16 chainId, bytes calldata token, bytes calldata vault) external view returns (bool) {
    SubVaultEntry[] storage entries = _tokenToSubVaults[chainId][token];
    bytes32 vaultHash = keccak256(vault);
    for (uint256 i = 0; i < entries.length; i++) {
      if (entries[i].isEnabled && keccak256(entries[i].vault) == vaultHash) {
        return true;
      }
    }
    return false;
  }

  function getSubVaultCount(uint16 chainId, bytes calldata token) external view returns (uint256) {
    return _tokenToSubVaults[chainId][token].length;
  }

  function _addSubVault(uint16 chainId, bytes calldata token, bytes calldata vault) internal {
    if (!chain.validateEncodedAddress(chainId, token)) revert InvalidTokenAddress();
    if (!chain.validateEncodedAddress(chainId, vault)) revert InvalidVaultAddress();

    SubVaultEntry[] storage entries = _tokenToSubVaults[chainId][token];
    if (entries.length >= MAX_SUB_VAULTS) revert MaxSubVaultsReached();
    if (subVaultToToken[chainId][vault].length != 0) revert VaultAlreadyRegistered();

    entries.push(SubVaultEntry({ vault: vault, isEnabled: true }));
    subVaultToToken[chainId][vault] = token;

    emit SubVaultAdded(chainId, token, vault, entries.length - 1);
  }
}
