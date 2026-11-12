// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IDepositBatchEndpoint {
  struct DepositRequest {
    uint16 chainId;
    address zToken;
    bytes sourceAddress;
    bytes depositAddress;
    uint256 zAmount;
    bytes sourceHashTx;
    uint256 sourceHashIndex;
  }

  function reqDepositZToken(DepositRequest calldata request) external returns (uint256 requestId);
}

contract DepositBatchRouter is AccessControlUpgradeable {
  uint256 private constant BITMAP_WORD_SIZE = 256;

  bytes32 public constant EDITOR_ROLE = keccak256("EDITOR_ROLE");
  bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

  IDepositBatchEndpoint public endpoint;

  uint256 public maxBatchSize;

  event DepositBatchProcessed(address indexed caller, bool requireSuccess, uint256 requestsCount, uint256 successCount, uint256[] successBitmap);
  event MaxBatchSizeUpdated(uint256 oldValue, uint256 newValue);

  error InvalidEndpointAddress();
  error InvalidBatchSize();
  error BatchSizeExceeded(uint256 requestsCount, uint256 maxBatchSize_);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function DepositBatchRouterInit(IDepositBatchEndpoint _endpoint, uint256 _maxBatchSize) external initializer {
    if (address(_endpoint) == address(0)) revert InvalidEndpointAddress();
    if (_maxBatchSize == 0) revert InvalidBatchSize();

    __AccessControl_init();

    endpoint = _endpoint;
    maxBatchSize = _maxBatchSize;

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(EDITOR_ROLE, sender_);
    _grantRole(RELAYER_ROLE, sender_);
  }

  function setRelayer(address relayer, bool enabled) external onlyRole(EDITOR_ROLE) {
    if (enabled) {
      grantRole(RELAYER_ROLE, relayer);
    } else {
      revokeRole(RELAYER_ROLE, relayer);
    }
  }

  function setMaxBatchSize(uint256 newMaxBatchSize) external onlyRole(EDITOR_ROLE) {
    if (newMaxBatchSize == 0) revert InvalidBatchSize();

    uint256 oldMaxBatchSize = maxBatchSize;
    maxBatchSize = newMaxBatchSize;
    emit MaxBatchSizeUpdated(oldMaxBatchSize, newMaxBatchSize);
  }

  function reqDepositZTokens(
    IDepositBatchEndpoint.DepositRequest[] calldata depositRequests,
    bool requireSuccess
  ) external onlyRole(RELAYER_ROLE) returns (uint256[] memory successBitmap) {
    uint256 requestsCount = depositRequests.length;
    if (requestsCount == 0) revert InvalidBatchSize();
    if (requestsCount > maxBatchSize) revert BatchSizeExceeded(requestsCount, maxBatchSize);

    uint256 successCount;

    if (!requireSuccess) {
      successBitmap = new uint256[]((requestsCount + BITMAP_WORD_SIZE - 1) / BITMAP_WORD_SIZE);
    }

    for (uint256 i = 0; i < requestsCount; ) {
      IDepositBatchEndpoint.DepositRequest calldata request = depositRequests[i];

      if (requireSuccess) {
        endpoint.reqDepositZToken(request);
        unchecked {
          ++successCount;
        }
      } else {
        (bool success, ) = address(endpoint).call(abi.encodeCall(IDepositBatchEndpoint.reqDepositZToken, (request)));
        if (success) {
          unchecked {
            ++successCount;
          }
          successBitmap[i / BITMAP_WORD_SIZE] |= uint256(1) << (i % BITMAP_WORD_SIZE);
        }
      }

      unchecked {
        ++i;
      }
    }

    if (requireSuccess) {
      successBitmap = new uint256[](0);
    }

    emit DepositBatchProcessed(msg.sender, requireSuccess, requestsCount, successCount, successBitmap);
  }
}
