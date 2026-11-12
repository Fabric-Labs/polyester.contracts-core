// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./ZipperFactoryChain.sol";

contract ZipperFactoryKey is AccessControlUpgradeable {
  bytes32 internal constant CREATE_KEY_ROLE = keccak256("CREATE_KEY_ROLE");
  bytes32 internal constant CHANGE_KEY_ROLE = keccak256("CHANGE_KEY_ROLE");
  bytes32 internal constant RETIRE_KEY_ROLE = keccak256("RETIRE_KEY_ROLE");

  ZipperFactoryChain public chain;

  // accountToDepositAddress[chainId][account] = deposit address
  mapping(uint16 => mapping(address => bytes)) public accountToDepositAddress;
  // depositAddressToAccount[chainId][depositAddress] = account
  mapping(uint16 => mapping(bytes => address)) public depositAddressToAccount;
  // accountToAddressFamilyDepositAddress[familyId][account] = shared deposit address
  mapping(uint16 => mapping(address => bytes)) public accountToAddressFamilyDepositAddress;
  // addressFamilyDepositAddressToAccount[familyId][depositAddress] = account
  mapping(uint16 => mapping(bytes => address)) public addressFamilyDepositAddressToAccount;

  // Global across chains; registered bytes retain destination tags.
  mapping(bytes => bool) private retiredDepositAddresses;

  event DepositAddressRetired(uint16 indexed chainId, address indexed previousAccount, bytes depositAddress);
  event DepositAddressCreated(uint16 indexed chainId, address indexed account, bytes indexed depositAddress);
  event DepositAddressChanged(uint16 indexed chainId, address indexed account, bytes indexed depositAddress, bytes oldDepositAddress);
  event AddressFamilyDepositAddressCreated(uint16 indexed familyId, uint16 indexed chainId, address indexed account, bytes depositAddress);
  event AddressFamilyDepositAddressChanged(
    uint16 indexed familyId,
    uint16 indexed chainId,
    address indexed account,
    bytes depositAddress,
    bytes oldDepositAddress
  );

  error InvalidArrayLengths();
  error InvalidKey();
  error DepositAddressAlreadyExistsForAccount();
  error DepositAddressAlreadyExistsForAnotherAccount();
  error DepositAddressDoesNotExistForAccount();
  error DepositAddressIsTheSame();
  error FamilyDepositAddressExistsForAccount();
  error FamilyDepositAddressExistsForOtherAccount();
  error DepositAddressIsRetired();
  error InconsistentDepositAddressLink();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperFactoryKeyInit(ZipperFactoryChain _chain) external initializer {
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);

    chain = _chain;
  }

  function createDepositAddress(uint16 chainId, address account, bytes memory depositAddress) external onlyRole(CREATE_KEY_ROLE) {
    _createDepositAddress(chainId, account, depositAddress);
  }

  function createDepositAddresses(
    uint16[] calldata chainIds,
    address[] calldata accounts,
    bytes[] calldata depositAddresses
  ) external onlyRole(CREATE_KEY_ROLE) {
    if (chainIds.length == 0 || chainIds.length != accounts.length || chainIds.length != depositAddresses.length) revert InvalidArrayLengths();

    for (uint256 i = 0; i < chainIds.length; ) {
      _createDepositAddress(chainIds[i], accounts[i], depositAddresses[i]);

      unchecked {
        ++i;
      }
    }
  }

  function changeDepositAddress(uint16 chainId, address account, bytes memory depositAddress) external onlyRole(CHANGE_KEY_ROLE) {
    _changeDepositAddress(chainId, account, depositAddress);
  }

  function changeDepositAddresses(
    uint16[] calldata chainIds,
    address[] calldata accounts,
    bytes[] calldata depositAddresses
  ) external onlyRole(CHANGE_KEY_ROLE) {
    if (chainIds.length == 0 || chainIds.length != accounts.length || chainIds.length != depositAddresses.length) revert InvalidArrayLengths();

    for (uint256 i = 0; i < chainIds.length; ) {
      _changeDepositAddress(chainIds[i], accounts[i], depositAddresses[i]);

      unchecked {
        ++i;
      }
    }
  }

  function isDepositAddressRetired(bytes memory depositAddress) public view returns (bool) {
    return retiredDepositAddresses[depositAddress];
  }

  function retireDepositAddress(uint16 chainId, bytes memory depositAddress) external onlyRole(RETIRE_KEY_ROLE) {
    // Other namespaces can retain inactive raw links. A global retry must never unlink a replacement.
    if (retiredDepositAddresses[depositAddress]) return;
    if (!chain.validateEncodedAddress(chainId, depositAddress)) revert InvalidKey();

    (address account, uint16 familyId) = _activeDepositAddressLink(chainId, depositAddress);
    if (account != address(0)) {
      bytes memory current = familyId == 0 ? accountToDepositAddress[chainId][account] : accountToAddressFamilyDepositAddress[familyId][account];
      if (keccak256(current) != keccak256(depositAddress)) revert InconsistentDepositAddressLink();
      if (familyId == 0) {
        delete accountToDepositAddress[chainId][account];
        delete depositAddressToAccount[chainId][depositAddress];
      } else {
        delete accountToAddressFamilyDepositAddress[familyId][account];
        delete addressFamilyDepositAddressToAccount[familyId][depositAddress];
      }
    }
    retiredDepositAddresses[depositAddress] = true;
    emit DepositAddressRetired(chainId, account, depositAddress);
  }

  function resolveAccount(uint16 chainId, bytes memory depositAddress) external view returns (address) {
    if (isDepositAddressRetired(depositAddress)) return address(0);
    (address account, ) = _activeDepositAddressLink(chainId, depositAddress);
    return account;
  }

  function _activeDepositAddressLink(uint16 chainId, bytes memory depositAddress) private view returns (address account, uint16 familyId) {
    familyId = chain.addressFamilyIds(chainId);
    if (familyId == 0) return (depositAddressToAccount[chainId][depositAddress], 0);

    account = addressFamilyDepositAddressToAccount[familyId][depositAddress];
    if (account != address(0)) return (account, familyId);

    account = depositAddressToAccount[chainId][depositAddress];
    if (account != address(0) && accountToAddressFamilyDepositAddress[familyId][account].length == 0) return (account, 0);
    return (address(0), 0);
  }

  function resolveDepositAddress(uint16 chainId, address account) external view returns (bytes memory) {
    uint16 familyId = chain.addressFamilyIds(chainId);
    bytes memory depositAddress = familyId == 0 ? accountToDepositAddress[chainId][account] : accountToAddressFamilyDepositAddress[familyId][account];
    if (familyId != 0 && depositAddress.length == 0) {
      depositAddress = accountToDepositAddress[chainId][account];
    }
    if (isDepositAddressRetired(depositAddress)) return bytes("");
    return depositAddress;
  }

  function _createDepositAddress(uint16 chainId, address account, bytes memory depositAddress) private {
    if (!chain.validateEncodedAddress(chainId, depositAddress)) revert InvalidKey();
    if (retiredDepositAddresses[depositAddress]) revert DepositAddressIsRetired();

    uint16 familyId = chain.addressFamilyIds(chainId);
    if (familyId != 0) {
      _createAddressFamilyDepositAddress(familyId, chainId, account, depositAddress);
      return;
    }

    _createChainDepositAddress(chainId, account, depositAddress);
  }

  function _createChainDepositAddress(uint16 chainId, address account, bytes memory depositAddress) private {
    bytes memory existing = accountToDepositAddress[chainId][account];
    if (existing.length != 0) {
      if (!isDepositAddressRetired(existing)) revert DepositAddressAlreadyExistsForAccount();
      if (depositAddressToAccount[chainId][existing] == account) delete depositAddressToAccount[chainId][existing];
    }
    if (depositAddressToAccount[chainId][depositAddress] != address(0)) revert DepositAddressAlreadyExistsForAnotherAccount();

    accountToDepositAddress[chainId][account] = depositAddress;
    depositAddressToAccount[chainId][depositAddress] = account;

    emit DepositAddressCreated(chainId, account, depositAddress);
  }

  function _changeDepositAddress(uint16 chainId, address account, bytes memory depositAddress) private {
    if (!chain.validateEncodedAddress(chainId, depositAddress)) revert InvalidKey();
    if (retiredDepositAddresses[depositAddress]) revert DepositAddressIsRetired();

    uint16 familyId = chain.addressFamilyIds(chainId);
    if (familyId != 0) {
      _changeAddressFamilyDepositAddress(familyId, chainId, account, depositAddress);
      return;
    }

    _changeChainDepositAddress(chainId, account, depositAddress);
  }

  function _changeChainDepositAddress(uint16 chainId, address account, bytes memory depositAddress) private {
    bytes memory oldDepositAddress = accountToDepositAddress[chainId][account];
    if (oldDepositAddress.length == 0) revert DepositAddressDoesNotExistForAccount();
    if (keccak256(oldDepositAddress) == keccak256(depositAddress)) revert DepositAddressIsTheSame();
    if (depositAddressToAccount[chainId][depositAddress] != address(0)) revert DepositAddressAlreadyExistsForAnotherAccount();

    accountToDepositAddress[chainId][account] = depositAddress;
    depositAddressToAccount[chainId][depositAddress] = account;
    if (depositAddressToAccount[chainId][oldDepositAddress] == account) delete depositAddressToAccount[chainId][oldDepositAddress];

    emit DepositAddressChanged(chainId, account, depositAddress, oldDepositAddress);
  }

  function _createAddressFamilyDepositAddress(uint16 familyId, uint16 chainId, address account, bytes memory depositAddress) private {
    bytes memory existingDepositAddress = accountToAddressFamilyDepositAddress[familyId][account];
    if (existingDepositAddress.length != 0) {
      if (!isDepositAddressRetired(existingDepositAddress)) revert FamilyDepositAddressExistsForAccount();
      if (addressFamilyDepositAddressToAccount[familyId][existingDepositAddress] == account) {
        delete addressFamilyDepositAddressToAccount[familyId][existingDepositAddress];
      }
    }
    if (addressFamilyDepositAddressToAccount[familyId][depositAddress] != address(0)) revert FamilyDepositAddressExistsForOtherAccount();

    accountToAddressFamilyDepositAddress[familyId][account] = depositAddress;
    addressFamilyDepositAddressToAccount[familyId][depositAddress] = account;

    emit AddressFamilyDepositAddressCreated(familyId, chainId, account, depositAddress);
  }

  function _changeAddressFamilyDepositAddress(uint16 familyId, uint16 chainId, address account, bytes memory depositAddress) private {
    bytes memory oldDepositAddress = accountToAddressFamilyDepositAddress[familyId][account];
    if (oldDepositAddress.length == 0) revert DepositAddressDoesNotExistForAccount();
    if (keccak256(oldDepositAddress) == keccak256(depositAddress)) revert DepositAddressIsTheSame();
    if (addressFamilyDepositAddressToAccount[familyId][depositAddress] != address(0)) revert FamilyDepositAddressExistsForOtherAccount();

    accountToAddressFamilyDepositAddress[familyId][account] = depositAddress;
    addressFamilyDepositAddressToAccount[familyId][depositAddress] = account;
    if (addressFamilyDepositAddressToAccount[familyId][oldDepositAddress] == account)
      delete addressFamilyDepositAddressToAccount[familyId][oldDepositAddress];

    emit AddressFamilyDepositAddressChanged(familyId, chainId, account, depositAddress, oldDepositAddress);
  }
}
