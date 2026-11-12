// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ZipperFactoryChain.sol";

contract ZipperFactoryFee is AccessControlUpgradeable {
  bytes32 internal constant EDITOR_ROLE = keccak256("EDITOR_ROLE");
  bytes32 internal constant ENDPOINT_ROLE = keccak256("ENDPOINT_ROLE");
  bytes32 internal constant FEE_UPDATER_ROLE = keccak256("FEE_UPDATER_ROLE");
  bytes32 internal constant RECOVERY_MANAGER_ROLE = keccak256("RECOVERY_MANAGER_ROLE");

  uint8 internal constant FEE_STATUS_NONE = 0;
  uint8 internal constant FEE_STATUS_LOCKED = 1;
  uint8 internal constant FEE_STATUS_SETTLED = 2;
  uint8 internal constant FEE_STATUS_FAILED_SWEEP = 3;

  struct FeeState {
    address feeToken;
    uint256 feeZAmount;
    address feeRecipient;
    uint8 status;
  }

  ZipperFactoryChain public chain;

  // feeRecipients[chainId] = fee recipient for deposit and withdrawal fees
  mapping(uint16 => address) public feeRecipients;
  // withdrawFees[requestId] = escrow state for withdraw request fee
  mapping(uint256 => FeeState) public withdrawFees;
  // depositFees[requestId] = locked fee snapshot for deposit request
  mapping(uint256 => FeeState) public depositFees;
  // failedPayoutBalances[token] = accumulated payout amounts that failed to transfer
  mapping(address => uint256) public failedPayoutBalances;

  // Recovery wallet for failed withdrawal fee
  address public failedWithdrawRecovery;

  // baseFees[chainId][zToken] = fee amount (smallest units) for deposit and withdrawal
  mapping(uint16 => mapping(address => uint256)) public baseFees;

  address public defaultFeeRecipient;

  event FeeRecipientUpdated(uint16 indexed chainId, address indexed feeRecipient);
  event DefaultFeeRecipientUpdated(address indexed feeRecipient);
  event EndpointUpdated(address indexed endpoint, bool enabled);
  event FailedWithdrawRecoveryUpdated(address indexed recovery);
  event WithdrawFeeLocked(uint256 indexed requestId, uint16 indexed chainId, address indexed feeToken, uint256 feeZAmount, address feeRecipient);
  event WithdrawFeeSettled(uint256 indexed requestId, address indexed feeToken, uint256 feeZAmount, address indexed feeRecipient);
  event DepositFeeLocked(uint256 indexed requestId, uint16 indexed chainId, address indexed feeToken, uint256 feeZAmount, address feeRecipient);
  event DepositFeeSettled(uint256 indexed requestId, address indexed feeToken, uint256 feeZAmount, address indexed feeRecipient);
  event WithdrawFeeFailedSwept(uint256 indexed requestId, address indexed feeToken, uint256 feeZAmount, address indexed recovery);
  event WithdrawFeePayoutFailed(uint256 indexed requestId, address indexed feeToken, uint256 feeZAmount, address indexed payoutTarget);
  event PendingPayoutResolved(address indexed token, address indexed to, uint256 amount, address indexed resolver);
  event BaseFeeUpdated(uint16 indexed chainId, address indexed token, uint256 fee);

  error InvalidChain();
  error InvalidFeeRecipientAddress();
  error InvalidEndpointAddress();
  error InvalidRecoveryAddress();
  error FeeRecipientNotInitialized();
  error InvalidFeeTokenAddress();
  error InvalidResolveAddress();
  error InvalidResolveAmount();
  error ResolvePayoutTransferFailed();
  error FeeAlreadyLocked();
  error ArrayLengthMismatch();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperFactoryFeeInit(ZipperFactoryChain _chain) external initializer {
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(RECOVERY_MANAGER_ROLE, sender_);
    _grantRole(EDITOR_ROLE, sender_);
    _grantRole(FEE_UPDATER_ROLE, sender_);

    chain = _chain;
    failedWithdrawRecovery = sender_;
    defaultFeeRecipient = sender_;
  }

  function getFee(uint16 chainId, address token) external view returns (uint256) {
    return baseFees[chainId][token];
  }

  function setFeeRecipient(uint16 chainId, address feeRecipient) external onlyRole(EDITOR_ROLE) {
    if (!chain.isChainEnabled(chainId)) revert InvalidChain();
    if (feeRecipient == address(0)) revert InvalidFeeRecipientAddress();

    feeRecipients[chainId] = feeRecipient;
    emit FeeRecipientUpdated(chainId, feeRecipient);
  }

  function setDefaultFeeRecipient(address feeRecipient) external onlyRole(EDITOR_ROLE) {
    if (feeRecipient == address(0)) revert InvalidFeeRecipientAddress();
    defaultFeeRecipient = feeRecipient;
    emit DefaultFeeRecipientUpdated(feeRecipient);
  }

  function setEndpoint(address endpoint, bool enabled) external onlyRole(EDITOR_ROLE) {
    if (endpoint == address(0)) revert InvalidEndpointAddress();
    if (enabled) {
      _grantRole(ENDPOINT_ROLE, endpoint);
    } else {
      _revokeRole(ENDPOINT_ROLE, endpoint);
    }

    emit EndpointUpdated(endpoint, enabled);
  }

  function setFailedWithdrawRecovery(address recovery) external onlyRole(RECOVERY_MANAGER_ROLE) {
    if (recovery == address(0)) revert InvalidRecoveryAddress();
    failedWithdrawRecovery = recovery;
    emit FailedWithdrawRecoveryUpdated(recovery);
  }

  function setBaseFeesBatch(uint16[] calldata chainIds, address[] calldata tokens, uint256[] calldata fees) external onlyRole(FEE_UPDATER_ROLE) {
    uint256 len = chainIds.length;
    if (len != tokens.length || len != fees.length) revert ArrayLengthMismatch();

    for (uint256 i = 0; i < len; ) {
      uint16 cid = chainIds[i];
      address t = tokens[i];
      baseFees[cid][t] = fees[i];
      emit BaseFeeUpdated(cid, t, fees[i]);
      unchecked {
        ++i;
      }
    }
  }

  function lockWithdrawFee(uint256 requestId, uint16 chainId, address feeToken, uint256 feeZAmount) external onlyRole(ENDPOINT_ROLE) returns (bool) {
    return _lockFee(withdrawFees[requestId], requestId, chainId, feeToken, feeZAmount, true);
  }

  function lockDepositFee(uint256 requestId, uint16 chainId, address feeToken, uint256 feeZAmount) external onlyRole(ENDPOINT_ROLE) returns (bool) {
    return _lockFee(depositFees[requestId], requestId, chainId, feeToken, feeZAmount, false);
  }

  function settleWithdrawFee(uint256 requestId) external onlyRole(ENDPOINT_ROLE) returns (bool) {
    FeeState storage feeState = withdrawFees[requestId];
    if (feeState.status == FEE_STATUS_LOCKED) {
      address feeToken = feeState.feeToken;
      uint256 feeZAmount = feeState.feeZAmount;
      address feeRecipient = feeState.feeRecipient;
      if (!_tryTransfer(feeToken, feeRecipient, feeZAmount)) {
        failedPayoutBalances[feeToken] += feeZAmount;
        emit WithdrawFeePayoutFailed(requestId, feeToken, feeZAmount, feeRecipient);
        return false;
      }

      feeState.status = FEE_STATUS_SETTLED;
      emit WithdrawFeeSettled(requestId, feeToken, feeZAmount, feeRecipient);
      return true;
    }
    return false;
  }

  function settleDepositFee(uint256 requestId) external onlyRole(ENDPOINT_ROLE) returns (uint256 feeZAmount, address feeRecipient) {
    FeeState storage feeState = depositFees[requestId];
    if (feeState.status == FEE_STATUS_LOCKED) {
      feeState.status = FEE_STATUS_SETTLED;
      emit DepositFeeSettled(requestId, feeState.feeToken, feeState.feeZAmount, feeState.feeRecipient);
      return (feeState.feeZAmount, feeState.feeRecipient);
    }
    return (0, address(0));
  }

  function sweepFailedWithdrawFee(uint256 requestId) external onlyRole(ENDPOINT_ROLE) returns (bool) {
    FeeState storage feeState = withdrawFees[requestId];
    if (feeState.status == FEE_STATUS_LOCKED) {
      address recovery = failedWithdrawRecovery;
      if (recovery == address(0)) revert InvalidRecoveryAddress();

      address feeToken = feeState.feeToken;
      uint256 feeZAmount = feeState.feeZAmount;
      if (!_tryTransfer(feeToken, recovery, feeZAmount)) {
        failedPayoutBalances[feeToken] += feeZAmount;
        emit WithdrawFeePayoutFailed(requestId, feeToken, feeZAmount, recovery);
        return false;
      }

      feeState.status = FEE_STATUS_FAILED_SWEEP;
      emit WithdrawFeeFailedSwept(requestId, feeToken, feeZAmount, recovery);
      return true;
    }
    return false;
  }

  function resolvePendingPayout(address token, address to, uint256 amount) external onlyRole(RECOVERY_MANAGER_ROLE) {
    if (to == address(0)) revert InvalidResolveAddress();
    if (amount == 0) revert InvalidResolveAmount();

    uint256 pendingAmount = failedPayoutBalances[token];
    if (amount > pendingAmount) revert InvalidResolveAmount();

    failedPayoutBalances[token] = pendingAmount - amount;
    if (!_tryTransfer(token, to, amount)) revert ResolvePayoutTransferFailed();

    emit PendingPayoutResolved(token, to, amount, _msgSender());
  }

  function _lockFee(
    FeeState storage feeState,
    uint256 requestId,
    uint16 chainId,
    address feeToken,
    uint256 feeZAmount,
    bool isWithdraw
  ) private returns (bool) {
    if (feeZAmount == 0) return false;
    if (feeState.status != FEE_STATUS_NONE) revert FeeAlreadyLocked();

    address feeRecipient = _resolveFeeRecipient(chainId);
    if (feeRecipient == address(0)) revert FeeRecipientNotInitialized();
    if (feeToken == address(0)) revert InvalidFeeTokenAddress();

    feeState.feeToken = feeToken;
    feeState.feeZAmount = feeZAmount;
    feeState.feeRecipient = feeRecipient;
    feeState.status = FEE_STATUS_LOCKED;

    if (isWithdraw) {
      emit WithdrawFeeLocked(requestId, chainId, feeToken, feeZAmount, feeRecipient);
    } else {
      emit DepositFeeLocked(requestId, chainId, feeToken, feeZAmount, feeRecipient);
    }
    return true;
  }

  function _resolveFeeRecipient(uint16 chainId) private view returns (address) {
    address feeRecipient = feeRecipients[chainId];
    if (feeRecipient != address(0)) return feeRecipient;
    return defaultFeeRecipient;
  }

  function _tryTransfer(address feeToken, address to, uint256 value) private returns (bool) {
    if (value == 0) return true;
    (bool success, bytes memory data) = feeToken.call(abi.encodeCall(IERC20.transfer, (to, value)));
    return success && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
  }
}
