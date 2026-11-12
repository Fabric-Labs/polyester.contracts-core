// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract ZipperFactoryChain is AccessControlUpgradeable {
  bytes32 internal constant EDITOR_ROLE = keccak256("EDITOR_ROLE");

  struct ChainConfig {
    string chainName; // Chain name (Ethereum, Bitcoin, Solana, etc.)
    bool isCaseSensitive; // Whether the chain's addresses are case-sensitive
    uint8 minAddressLength; // Minimum valid address length
    uint8 maxAddressLength; // Maximum valid address length
    bool isEnabled; // Whether this chain is currently supported
  }

  // chainConfigs[chainId] = ChainConfig
  mapping(uint16 => ChainConfig) public chainConfigs;
  uint16[] public addedChains;
  // addressFamilyIds[chainId] = shared address family id. 0 means chain-specific keys.
  mapping(uint16 => uint16) public addressFamilyIds;

  event ChainAdded(uint16 indexed chainId, string chainName);
  event ChainUpdated(uint16 indexed chainId, bool isEnabled);
  event ChainEnabled(uint16 indexed chainId, bool isEnabled);
  event AddressFamilyUpdated(uint16 indexed chainId, uint16 indexed oldFamilyId, uint16 indexed newFamilyId);

  error ChainNotFound();
  error InvalidInput();
  error InvalidDecodedInput();
  error AddressTooShort();
  error AddressTooLong();
  error InvalidChainId();
  error EmptyChainName();
  error InvalidMinAddressLength();
  error InvalidAddressLength();
  error InvalidArrayLengths();
  error ChainStatusUnchanged();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperFactoryChainInit() external initializer {
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(EDITOR_ROLE, sender_);
  }

  function encodeAddress(uint16 chainId, string calldata input) external view returns (bytes memory) {
    if (!isChainAdded(chainId)) revert ChainNotFound();
    if (!_isValidInput(input)) revert InvalidInput();
    if (bytes(input).length < chainConfigs[chainId].minAddressLength) revert AddressTooShort();
    if (bytes(input).length > chainConfigs[chainId].maxAddressLength) revert AddressTooLong();

    if (chainConfigs[chainId].isCaseSensitive) {
      return bytes(input);
    } else {
      return bytes(_toLowerCase(input));
    }
  }

  function decodeAddress(uint16 chainId, bytes calldata input) external view returns (string memory) {
    if (!isChainAdded(chainId)) revert ChainNotFound();
    if (input.length < chainConfigs[chainId].minAddressLength) revert AddressTooShort();
    if (input.length > chainConfigs[chainId].maxAddressLength) revert AddressTooLong();

    string memory decode = string(input);
    if (!chainConfigs[chainId].isCaseSensitive) {
      decode = _toLowerCase(decode);
    }
    if (!_isValidInput(decode)) revert InvalidDecodedInput();
    return decode;
  }

  function validateEncodedAddress(uint16 chainId, bytes calldata input) external view returns (bool) {
    if (!isChainAdded(chainId) || input.length < chainConfigs[chainId].minAddressLength || input.length > chainConfigs[chainId].maxAddressLength) {
      return false;
    }

    string memory decode = string(input);
    if (!chainConfigs[chainId].isCaseSensitive) {
      decode = _toLowerCase(decode);
    }

    if (!_isValidInput(decode)) {
      return false;
    }

    if (keccak256(input) == keccak256(bytes(decode))) {
      return true;
    }

    return false;
  }

  function isChainAdded(uint16 chainId) public view returns (bool) {
    return bytes(chainConfigs[chainId].chainName).length > 0;
  }

  function isChainEnabled(uint16 chainId) external view returns (bool) {
    return chainConfigs[chainId].isEnabled;
  }

  function getChainConfig(uint16 chainId) external view returns (ChainConfig memory) {
    return chainConfigs[chainId];
  }

  function totalAddedChains() external view returns (uint256 _total) {
    return addedChains.length;
  }

  function exportAddedChains(uint256 _offset, uint256 _limit) external view returns (uint16[] memory _chainIds, uint256 _nextOffset, uint256 _total) {
    uint256 total = addedChains.length;
    if (_limit == 0) _limit = 1;
    if (_limit > total - _offset) _limit = total - _offset;

    uint16[] memory values_ = new uint16[](_limit);
    for (uint256 i = 0; i < _limit; i++) {
      values_[i] = addedChains[_offset + i];
    }

    return (values_, _offset + _limit, total);
  }

  function upsertChain(uint16 chainId, ChainConfig calldata config) external onlyRole(EDITOR_ROLE) {
    if (chainId == 0) revert InvalidChainId();
    if (bytes(config.chainName).length == 0) revert EmptyChainName();
    if (config.minAddressLength == 0) revert InvalidMinAddressLength();
    if (config.maxAddressLength < config.minAddressLength) revert InvalidAddressLength();

    bool wasAdded = isChainAdded(chainId);
    chainConfigs[chainId] = config;

    if (!wasAdded) {
      addedChains.push(chainId);
      emit ChainAdded(chainId, config.chainName);
    } else {
      emit ChainUpdated(chainId, config.isEnabled);
    }
  }

  function setAddressFamily(uint16 chainId, uint16 familyId) external onlyRole(EDITOR_ROLE) {
    _setAddressFamily(chainId, familyId);
  }

  function setAddressFamilies(uint16[] calldata chainIds, uint16 familyId) external onlyRole(EDITOR_ROLE) {
    if (chainIds.length == 0) revert InvalidArrayLengths();

    for (uint256 i = 0; i < chainIds.length; ) {
      _setAddressFamily(chainIds[i], familyId);

      unchecked {
        ++i;
      }
    }
  }

  function enableChain(uint16 chainId, bool status) external onlyRole(EDITOR_ROLE) {
    if (!isChainAdded(chainId)) revert ChainNotFound();
    if (chainConfigs[chainId].isEnabled == status) revert ChainStatusUnchanged();

    chainConfigs[chainId].isEnabled = status;

    emit ChainEnabled(chainId, status);
  }

  function _setAddressFamily(uint16 chainId, uint16 familyId) private {
    if (!isChainAdded(chainId)) revert ChainNotFound();

    uint16 oldFamilyId = addressFamilyIds[chainId];
    if (oldFamilyId == familyId) {
      return;
    }

    addressFamilyIds[chainId] = familyId;
    emit AddressFamilyUpdated(chainId, oldFamilyId, familyId);
  }

  function _toLowerCase(string memory str) internal pure returns (string memory) {
    bytes memory bStr = bytes(str);
    for (uint256 i = 0; i < bStr.length; i++) {
      if (bStr[i] >= 0x41 && bStr[i] <= 0x5A) {
        bStr[i] = bytes1(uint8(bStr[i]) + 32);
      }
    }
    return string(bStr);
  }

  /// @dev Validates address-like inputs using a strict character whitelist.
  /// - Allowed characters (base format): `0-9`, `A-Z`, `a-z`, `.`, `_`.
  /// - Optional Ripple memo tag format: `{address}:{tag}`.
  ///   - Only one `:` is allowed.
  ///   - `:` cannot be the first or last character.
  ///   - `tag` (after `:`) must be decimal digits only (`0-9`).
  /// This function does not validate chain-specific prefixes, checksums, or encoding rules.
  function _isValidInput(string memory input) internal pure returns (bool) {
    bytes memory b = bytes(input);
    uint256 len = b.length;
    bool afterColon = false;

    for (uint256 i = 0; i < len; ) {
      bytes1 char = b[i];

      if (afterColon) {
        if (!(char >= 0x30 && char <= 0x39)) return false; // 0-9
      } else if (char == 0x3A) {
        if (i == 0 || i == len - 1) return false;
        afterColon = true;
      } else {
        if (
          !(char >= 0x30 && char <= 0x39) && // 0-9
          !(char >= 0x41 && char <= 0x5A) && // A-Z
          !(char >= 0x61 && char <= 0x7A) && // a-z
          !(char == 0x2E || char == 0x5F) // . (dot) or _ (underscore)
        ) {
          return false;
        }
      }

      unchecked {
        ++i;
      }
    }

    return true;
  }
}
