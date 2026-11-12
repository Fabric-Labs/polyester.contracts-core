// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ZipperFactoryChain.sol";
import "./ZipperFactoryKey.sol";
import "./ZipperFactoryToken.sol";
import "./ZipperFactoryFee.sol";
import "./ZipperFactoryVault.sol";
import "./ZipperFactorySubVault.sol";
import "../utils/RepeatCallGuard.sol";

contract ZipperEndpoint is EIP712Upgradeable, RepeatCallGuard, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;

  bytes32 internal constant EDITOR_ROLE = keccak256("EDITOR_ROLE");
  bytes32 internal constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
  bytes32 internal constant VALIDATOR_MANAGER_ROLE = keccak256("VALIDATOR_MANAGER_ROLE");
  bytes32 internal constant VALIDATION_ROUTER_ROLE = keccak256("VALIDATION_ROUTER_ROLE");
  bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 internal constant REFUND_DEPOSIT_ROLE = keccak256("REFUND_DEPOSIT_ROLE");
  bytes32 internal constant REFUND_WITHDRAW_ROLE = keccak256("REFUND_WITHDRAW_ROLE");
  bytes32 internal constant WHITELISTED_AGENT_ROLE = keccak256("WHITELISTED_AGENT_ROLE");
  bytes32 internal constant RECOVERY_MANAGER_ROLE = keccak256("RECOVERY_MANAGER_ROLE");
  bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  uint256 internal constant BITMAP_WORD_SIZE = 256;

  uint8 internal constant PAUSE_REQUEST_DEPOSIT = 1;
  uint8 internal constant PAUSE_REQUEST_WITHDRAW = 2;
  uint8 internal constant PAUSE_VALIDATION = 3;
  uint8 internal constant PAUSE_EXECUTION = 4;
  uint8 internal constant PAUSE_REFUND_DEPOSIT = 5;
  uint8 internal constant PAUSE_REFUND_WITHDRAW = 6;

  uint8 internal constant ZTOKEN_DEPOSIT_DISABLED = 1;
  uint8 internal constant ZTOKEN_WITHDRAWAL_DISABLED = 2;

  uint8 internal constant REQUEST_TYPE_DEPOSIT_ZTOKEN = 1;
  uint8 internal constant REQUEST_TYPE_WITHDRAW_ZTOKEN = 2;

  uint8 public constant WITHDRAW_ORIGIN_ZIPPER_ENDPOINT = 1;

  uint8 internal constant VALIDATION_PENDING = 0;
  uint8 internal constant VALIDATION_APPROVED = 1;
  uint8 internal constant VALIDATION_REJECTED = 2;
  uint16 internal constant VALIDATION_REASON_NONE = 0;

  uint8 internal constant EXECUTION_PENDING = 0;
  uint8 internal constant EXECUTION_PROCESSING = 1;
  uint8 internal constant EXECUTION_DISTRIBUTED = 2;
  uint8 internal constant EXECUTION_REFUNDED = 3;
  uint8 internal constant EXECUTION_FAILED = 4;
  uint8 internal constant EXECUTION_FULFILLING = 5;
  uint8 internal constant EXECUTION_REJECTED = 6;

  struct Request {
    uint16 requestType;
    uint16 chainId;
    bytes payload;
  }

  struct ValidationStatus {
    uint8 status;
    uint256 approveCount;
    uint256 rejectCount;
  }

  struct ExecutionStatus {
    uint8 status;
    bytes destinationHashTx;
  }

  ZipperFactoryChain public chainFactory;
  ZipperFactoryToken public tokenFactory;
  ZipperFactoryKey public keyFactory;
  ZipperFactoryFee public feeFactory;

  // requests[requestId] = Request
  Request[] public requests;
  mapping(uint256 => ValidationStatus) public validationStatuses;
  mapping(uint256 => ExecutionStatus) public executionStatuses;
  mapping(bytes32 => bool) public depositNonces;

  // Validators
  uint256 public validationPendingCount;
  uint256 public validationQuorumThreshold;
  uint256 public validatorCount;
  mapping(address => bool) public validators;
  mapping(uint256 => mapping(address => uint8)) public validatorApprovals;

  // pauseStatus[code] = status
  mapping(uint8 => bool) public pauseStatus;

  // validationQuorums[requestId] = quorum threshold snapshot
  mapping(uint256 => uint256) public validationQuorums;

  // Recovery wallet for failed withdrawal funds
  address public failedWithdrawRecovery;

  // Vault factories
  ZipperFactoryVault public vaultFactory;
  ZipperFactorySubVault public subVaultFactory;

  // Append-only storage; existing validation getters and vote/event formats stay unchanged.
  mapping(uint256 => uint16) public validationReasonCodes;

  struct WithdrawRequest {
    uint16 chainId;
    address zToken;
    bytes withdrawDestination;
    uint256 zAmount;
    uint256 maxFee;
  }

  struct DepositRequest {
    uint16 chainId;
    address zToken;
    bytes sourceAddress;
    bytes depositAddress;
    uint256 zAmount;
    bytes sourceHashTx;
    uint256 sourceHashIndex;
  }

  // prettier-ignore
  event RequestDepositCreated(
    uint256 indexed requestId,
    uint8 indexed requestType,
    uint16 indexed chainId,
    address zToken,
    bytes32 requestHash,
    bytes sourceAddress,
    bytes depositAddress,
    bytes sourceHashTx,
    uint256 sourceHashIndex,
    address account,
    uint256 netZAmount,
    uint256 feeZAmount
  );
  event RequestWithdrawCreated(
    uint256 indexed requestId,
    uint8 indexed origin,
    address indexed originContract,
    uint8 requestType,
    uint16 chainId,
    address zToken,
    address fromAccount,
    bytes withdrawDestination,
    uint256 netZAmount,
    uint256 feeZAmount
  );
  event PauseStatusUpdated(uint8 indexed code, bool status);
  event ValidationQuorumThresholdUpdated(uint256 threshold);
  event ValidationStatusRecorded(uint256 indexed requestId, address indexed validator, uint8 status, uint16 reasonCode);
  event ValidationFinalized(
    uint256 indexed requestId,
    uint8 indexed status,
    uint256 approveCount,
    uint256 rejectCount,
    uint256 quorumThreshold,
    uint16 reasonCode
  );
  event RequestExecuted(uint256 indexed requestId, uint8 indexed status);
  event WithdrawTxHashCommitted(uint256 indexed requestId, bytes destinationHashTx);
  event WithdrawTxHashReplaced(uint256 indexed requestId, bytes oldDestinationHashTx, bytes newDestinationHashTx);
  event RequestExecutionRejected(uint256 indexed requestId, uint16 indexed reasonCode);
  event WithdrawExecutionFailed(uint256 indexed requestId, uint16 indexed reasonCode);
  event DepositRefundFailed(uint256 indexed requestId, uint16 indexed reasonCode);
  event FailedWithdrawRecoveryUpdated(address indexed recovery);
  event RequestExecutionBatchProcessed(
    address indexed caller,
    bool requireSuccess,
    uint256 requestsCount,
    uint256 successCount,
    uint256[] successBitmap
  );
  event RepeatCallAllowedUpdated(address indexed caller, bool allow);

  // ============ ERRORS ============
  error NotValidator();
  error ValidationPaused();
  error ExecutionPaused();
  error DepositRequestPaused();
  error WithdrawRequestPaused();
  error RefundDepositPaused();
  error RefundWithdrawPaused();

  error InvalidValidatorAddress();
  error ValidatorAlreadyExists();
  error ValidatorNotFound();

  error ThresholdSame();
  error InvalidThreshold();

  error InvalidRequestType();
  error RequestAlreadyProcessed();
  error AlreadyApproved();
  error RequestNotApproved();
  error RequestNotRejected();
  error RequestAlreadyExecuted();

  error InvalidDestinationHashTx();
  error DestinationHashTxMismatch();
  error DestinationHashTxAlreadySet();
  error InvalidBatchSize();

  error InvalidChain();
  error InvalidZTokenAddress();
  error InvalidSourceAddress();
  error InvalidDepositAddress();
  error InvalidWithdrawDestination();
  error InvalidFromAccount();
  error InvalidAccount();
  error InvalidCaller();
  error InvalidZAmount();
  error InvalidSourceDepositHash();
  error SourceTokenNotFound();
  error ZTokenDisabled();
  error RequestAlreadyAdded();

  error InvalidRecoveryAddress();
  error DepositAmountTooSmallForFee();
  error WithdrawAmountTooSmallForFee();
  error FeeExceedsMax();
  error InvalidReasonCode();

  modifier onlyValidator() {
    if (!validators[_msgSender()]) revert NotValidator();
    _;
  }

  modifier onlyApprovedRequest(uint256 _requestId) {
    _requireApprovedRequest(_requestId);
    _;
  }

  modifier onlyRejectedRequest(uint256 _requestId) {
    if (validationStatuses[_requestId].status != VALIDATION_REJECTED) revert RequestNotRejected();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperEndpointInit(
    ZipperFactoryChain _chainFactory,
    ZipperFactoryToken _tokenFactory,
    ZipperFactoryKey _keyFactory,
    ZipperFactoryFee _feeFactory
  ) external initializer {
    __EIP712_init("ZipperEndpoint", "1.0.0");
    __ReentrancyGuard_init();
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(RECOVERY_MANAGER_ROLE, sender_);
    _grantRole(EDITOR_ROLE, sender_);
    _grantRole(PAUSER_ROLE, sender_);

    chainFactory = _chainFactory;
    tokenFactory = _tokenFactory;
    keyFactory = _keyFactory;
    feeFactory = _feeFactory;

    failedWithdrawRecovery = sender_;
  }

  function setVaultFactories(ZipperFactoryVault _vaultFactory, ZipperFactorySubVault _subVaultFactory) external onlyRole(EDITOR_ROLE) {
    vaultFactory = _vaultFactory;
    subVaultFactory = _subVaultFactory;
  }

  function setFailedWithdrawRecovery(address recovery) external onlyRole(RECOVERY_MANAGER_ROLE) {
    if (recovery == address(0)) revert InvalidRecoveryAddress();
    failedWithdrawRecovery = recovery;
    emit FailedWithdrawRecoveryUpdated(recovery);
  }

  function totalRequests() external view returns (uint256) {
    return requests.length;
  }

  function pause(uint8 _code, bool _status) external onlyRole(PAUSER_ROLE) {
    pauseStatus[_code] = _status;
    emit PauseStatusUpdated(_code, _status);
  }

  function setAllowRepeatCall(address caller, bool allow) external onlyRole(EDITOR_ROLE) {
    _allowRepeatCall[caller] = allow;
    emit RepeatCallAllowedUpdated(caller, allow);
  }

  // Set validator status without mutating the configured quorum threshold.
  function setValidator(address[] calldata _validators, bool _enabled) external onlyRole(VALIDATOR_MANAGER_ROLE) {
    for (uint256 i = 0; i < _validators.length; ) {
      address _validator = _validators[i];
      if (_validator == address(0)) revert InvalidValidatorAddress();
      if (_enabled) {
        if (validators[_validator]) revert ValidatorAlreadyExists();

        validators[_validator] = true;
        validatorCount += 1;
      } else {
        if (!validators[_validator]) revert ValidatorNotFound();

        validators[_validator] = false;
        validatorCount -= 1;
      }

      unchecked {
        ++i;
      }
    }

    if (validationQuorumThreshold != 0 && validationQuorumThreshold > validatorCount) revert InvalidThreshold();
  }

  // Set quorum threshold explicitly, independent from validator count changes.
  function setValidationQuorumThreshold(uint256 _threshold) external onlyRole(VALIDATOR_MANAGER_ROLE) {
    if (_threshold == validationQuorumThreshold) revert ThresholdSame();
    if (_threshold == 0 || _threshold > validatorCount) revert InvalidThreshold();
    validationQuorumThreshold = _threshold;

    emit ValidationQuorumThresholdUpdated(_threshold);
  }

  function validateRequest(uint256 _requestId, bool _accept, uint16 _reasonCode) external onlyValidator {
    _validateRequest(_msgSender(), _requestId, _accept, _reasonCode);
  }

  function _validateRequest(address validator, uint256 _requestId, bool _accept, uint16 _reasonCode) private {
    if (pauseStatus[PAUSE_VALIDATION]) revert ValidationPaused();
    if (!_isValidRequestId(_requestId)) revert InvalidRequestType();

    ValidationStatus storage requestStatus = validationStatuses[_requestId];
    if (requestStatus.status != VALIDATION_PENDING) revert RequestAlreadyProcessed();
    _applyValidationVote(validator, _requestId, _accept, _reasonCode, _loadValidationQuorum(_requestId), requestStatus);
  }

  function validateRequestByRouter(
    address validator,
    uint256 requestId,
    bool accept,
    uint16 reasonCode
  ) external onlyRole(VALIDATION_ROUTER_ROLE) returns (bool) {
    if (pauseStatus[PAUSE_VALIDATION]) return false;
    if (!_isValidRequestId(requestId)) return false;

    ValidationStatus storage requestStatus = validationStatuses[requestId];
    if (requestStatus.status != VALIDATION_PENDING) return false;
    if (!validators[validator]) return false;
    if ((accept && reasonCode != VALIDATION_REASON_NONE) || (!accept && reasonCode == VALIDATION_REASON_NONE)) return false;
    if (validatorApprovals[requestId][validator] != VALIDATION_PENDING) return false;

    _applyValidationVote(validator, requestId, accept, reasonCode, _loadValidationQuorum(requestId), requestStatus);
    return true;
  }

  function executeRequests(uint256[] calldata requestIds, bool requireSuccess) external nonReentrant onlyRole(EXECUTOR_ROLE) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();

    uint256 requestsCount = requestIds.length;
    uint256 successCount;
    uint256[] memory successBitmap;

    if (!requireSuccess) {
      successBitmap = new uint256[]((requestsCount + BITMAP_WORD_SIZE - 1) / BITMAP_WORD_SIZE);
    }

    for (uint256 i = 0; i < requestsCount; ) {
      uint256 requestId = requestIds[i];

      if (requireSuccess) {
        _executeRequest(requestId);
      } else {
        (bool success, ) = address(this).call(abi.encodeCall(this.executeRequestBatchItem, (requestId)));
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
      successCount = requestsCount;
    }

    emit RequestExecutionBatchProcessed(_msgSender(), requireSuccess, requestsCount, successCount, successBitmap);
  }

  function executeRequestBatchItem(uint256 _requestId) external {
    if (_msgSender() != address(this)) revert InvalidCaller();
    _executeRequest(_requestId);
  }

  function _executeRequest(uint256 _requestId) private onlyApprovedRequest(_requestId) {
    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    if (executionStatus.status != EXECUTION_PENDING) revert RequestAlreadyExecuted();

    Request memory request = requests[_requestId];
    if (request.requestType == REQUEST_TYPE_DEPOSIT_ZTOKEN) {
      (address zToken, , , address account, uint256 zAmount, , ) = abi.decode(
        request.payload,
        (address, bytes, bytes, address, uint256, bytes, uint256)
      );
      (uint256 feeZAmount, address feeRecipient) = feeFactory.settleDepositFee(_requestId);
      if (feeZAmount > 0 && feeRecipient != address(0) && zAmount > feeZAmount) {
        tokenFactory.mintZTokenForRequest(_requestId, request.chainId, zToken, account, zAmount - feeZAmount);
        tokenFactory.mintZTokenDirect(_requestId, request.chainId, zToken, feeRecipient, feeZAmount);
      } else {
        tokenFactory.mintZTokenForRequest(_requestId, request.chainId, zToken, account, zAmount);
      }

      executionStatus.status = EXECUTION_DISTRIBUTED;
    } else if (request.requestType == REQUEST_TYPE_WITHDRAW_ZTOKEN) {
      // Withdrawals are reversible until the destination-chain tx hash is committed. Burning is
      // deferred until fulfillment to support safe refunds on execution-layer failures.
      executionStatus.status = EXECUTION_PROCESSING;
    }

    emit RequestExecuted(_requestId, executionStatus.status);
  }

  /**
   * @dev Commit the destination-chain transaction hash for a withdrawal after the transaction is built/submitted.
   * This makes the bridge state crash-recoverable for off-chain components.
   */
  function commitWithdrawTxHash(uint256 _requestId, bytes calldata _destinationHashTx) external nonReentrant onlyRole(EXECUTOR_ROLE) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();
    if (_destinationHashTx.length == 0) revert InvalidDestinationHashTx();

    _commitWithdrawTxHash(_requestId, _destinationHashTx);
  }

  function commitWithdrawTxHashBatch(
    uint256[] calldata _requestIds,
    bytes calldata _destinationHashTx
  ) external nonReentrant onlyRole(EXECUTOR_ROLE) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();
    if (_destinationHashTx.length == 0) revert InvalidDestinationHashTx();

    uint256 requestsCount = _requestIds.length;
    if (requestsCount == 0) revert InvalidBatchSize();

    for (uint256 i = 0; i < requestsCount; ) {
      _commitWithdrawTxHash(_requestIds[i], _destinationHashTx);

      unchecked {
        ++i;
      }
    }
  }

  function _commitWithdrawTxHash(uint256 _requestId, bytes calldata _destinationHashTx) private {
    _requireApprovedRequest(_requestId);

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];

    if (executionStatus.status == EXECUTION_FULFILLING) {
      if (keccak256(executionStatus.destinationHashTx) != keccak256(_destinationHashTx)) revert DestinationHashTxMismatch();
      return;
    }
    if (executionStatus.status != EXECUTION_PROCESSING) revert RequestAlreadyExecuted();
    if (executionStatus.destinationHashTx.length != 0) revert DestinationHashTxAlreadySet();

    executionStatus.destinationHashTx = _destinationHashTx;
    executionStatus.status = EXECUTION_FULFILLING;

    emit WithdrawTxHashCommitted(_requestId, _destinationHashTx);
    emit RequestExecuted(_requestId, executionStatus.status);
  }

  /**
   * @dev Replace a previously committed destination-chain transaction hash for a withdrawal.
   * This supports transaction replacement/resubmission flows (e.g., EVM replacement-by-fee, RBF).
   */
  function replaceWithdrawTxHash(
    uint256 _requestId,
    bytes calldata _newDestinationHashTx
  ) external nonReentrant onlyRole(EXECUTOR_ROLE) onlyApprovedRequest(_requestId) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();
    if (_newDestinationHashTx.length == 0) revert InvalidDestinationHashTx();

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    if (executionStatus.status != EXECUTION_FULFILLING) revert RequestAlreadyExecuted();

    bytes memory oldDestinationHashTx = executionStatus.destinationHashTx;
    if (keccak256(oldDestinationHashTx) == keccak256(_newDestinationHashTx)) return;

    executionStatus.destinationHashTx = _newDestinationHashTx;

    emit WithdrawTxHashReplaced(_requestId, oldDestinationHashTx, _newDestinationHashTx);
  }

  function fulfillWithdrawRequest(uint256 _requestId, bytes calldata _destinationHashTx) external nonReentrant onlyRole(EXECUTOR_ROLE) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();
    if (_destinationHashTx.length == 0) revert InvalidDestinationHashTx();

    _fulfillWithdrawRequest(_requestId, _destinationHashTx);
  }

  function fulfillWithdrawRequestBatch(
    uint256[] calldata _requestIds,
    bytes calldata _destinationHashTx
  ) external nonReentrant onlyRole(EXECUTOR_ROLE) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();
    if (_destinationHashTx.length == 0) revert InvalidDestinationHashTx();

    uint256 requestsCount = _requestIds.length;
    if (requestsCount == 0) revert InvalidBatchSize();

    for (uint256 i = 0; i < requestsCount; ) {
      _fulfillWithdrawRequest(_requestIds[i], _destinationHashTx);

      unchecked {
        ++i;
      }
    }
  }

  function _fulfillWithdrawRequest(uint256 _requestId, bytes calldata _destinationHashTx) private {
    _requireApprovedRequest(_requestId);

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    if (executionStatus.status == EXECUTION_FULFILLING) {
      if (keccak256(executionStatus.destinationHashTx) != keccak256(_destinationHashTx)) revert DestinationHashTxMismatch();
      (address zToken, , , uint256 zAmount) = abi.decode(request.payload, (address, address, bytes, uint256));
      IERC20(zToken).forceApprove(address(tokenFactory), zAmount);
      tokenFactory.burnZTokenForRequest(_requestId, request.chainId, zToken, address(this), zAmount);

      feeFactory.settleWithdrawFee(_requestId);

      executionStatus.status = EXECUTION_DISTRIBUTED;
    } else {
      revert RequestAlreadyExecuted();
    }

    emit RequestExecuted(_requestId, executionStatus.status);
  }

  function _requireApprovedRequest(uint256 _requestId) private view {
    if (validationStatuses[_requestId].status != VALIDATION_APPROVED) revert RequestNotApproved();
  }

  /**
   * @dev Reject an already-approved request at the execution layer before any irreversible action happens.
   * Withdraw-only: marks the request as rejected; funds remain locked until explicitly refunded.
   * A withdrawal can also be rejected while in EXECUTION_PROCESSING provided no destination tx hash is committed yet.
   */
  function rejectApprovedRequest(
    uint256 _requestId,
    uint16 _reasonCode
  ) external nonReentrant onlyRole(EXECUTOR_ROLE) onlyApprovedRequest(_requestId) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    // solhint-disable-next-line no-empty-blocks
    if (executionStatus.status == EXECUTION_PENDING) {
      // ok
    }
    // solhint-disable-next-line no-empty-blocks
    else if (executionStatus.status == EXECUTION_PROCESSING && executionStatus.destinationHashTx.length == 0) {
      // ok: reversible until destinationHashTx is committed (EXECUTION_FULFILLING)
    } else {
      revert RequestAlreadyExecuted();
    }

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    executionStatus.status = EXECUTION_REJECTED;

    emit RequestExecutionRejected(_requestId, _reasonCode);
    emit RequestExecuted(_requestId, executionStatus.status);
  }

  /**
   * @dev Refund a rejected withdrawal (execution-layer rejection) and mark it as refunded.
   */
  function refundRejectedWithdrawRequest(uint256 _requestId) external nonReentrant onlyRole(REFUND_WITHDRAW_ROLE) onlyApprovedRequest(_requestId) {
    if (pauseStatus[PAUSE_REFUND_WITHDRAW]) revert RefundWithdrawPaused();

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    if (executionStatus.status != EXECUTION_REJECTED) revert RequestNotRejected();

    (address zToken, address fromAccount, , uint256 zAmount) = abi.decode(request.payload, (address, address, bytes, uint256));
    IERC20(zToken).safeTransfer(fromAccount, zAmount);
    feeFactory.settleWithdrawFee(_requestId);

    executionStatus.status = EXECUTION_REFUNDED;

    emit RequestExecuted(_requestId, executionStatus.status);
  }

  /**
   * @dev Mark a withdrawal as failed after execution has started.
   * This is an explicit alternative to using empty hashes as sentinels.
   */
  function failWithdrawRequest(uint256 _requestId, uint16 _reasonCode) external nonReentrant onlyRole(EXECUTOR_ROLE) onlyApprovedRequest(_requestId) {
    if (pauseStatus[PAUSE_EXECUTION]) revert ExecutionPaused();

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    if (executionStatus.status != EXECUTION_PROCESSING && executionStatus.status != EXECUTION_FULFILLING) revert RequestAlreadyExecuted();

    address recovery = failedWithdrawRecovery;
    if (recovery == address(0)) revert InvalidRecoveryAddress();

    (address zToken, , , uint256 zAmount) = abi.decode(request.payload, (address, address, bytes, uint256));
    IERC20(zToken).safeTransfer(recovery, zAmount);

    feeFactory.sweepFailedWithdrawFee(_requestId);

    executionStatus.status = EXECUTION_FAILED;

    emit WithdrawExecutionFailed(_requestId, _reasonCode);
    emit RequestExecuted(_requestId, executionStatus.status);
  }

  function refundDepositRequest(uint256 _requestId, bytes calldata _destinationHashTx) external nonReentrant onlyRole(REFUND_DEPOSIT_ROLE) {
    if (_destinationHashTx.length == 0) revert InvalidDestinationHashTx();

    ExecutionStatus storage executionStatus = _requireDepositRefundable(_requestId);

    executionStatus.status = EXECUTION_REFUNDED;
    executionStatus.destinationHashTx = _destinationHashTx;

    emit RequestExecuted(_requestId, executionStatus.status);
  }

  function failDepositRefundRequest(uint256 _requestId, uint16 _reasonCode) external nonReentrant onlyRole(REFUND_DEPOSIT_ROLE) {
    ExecutionStatus storage executionStatus = _requireDepositRefundable(_requestId);

    executionStatus.status = EXECUTION_FAILED;

    emit DepositRefundFailed(_requestId, _reasonCode);
    emit RequestExecuted(_requestId, executionStatus.status);
  }

  function _requireDepositRefundable(
    uint256 _requestId
  ) private view onlyRejectedRequest(_requestId) returns (ExecutionStatus storage executionStatus) {
    if (pauseStatus[PAUSE_REFUND_DEPOSIT]) revert RefundDepositPaused();

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_DEPOSIT_ZTOKEN) revert InvalidRequestType();

    executionStatus = executionStatuses[_requestId];
    if (executionStatus.status != EXECUTION_PENDING) revert RequestAlreadyExecuted();
  }

  function refundWithdrawRequest(uint256 _requestId) external nonReentrant onlyRole(REFUND_WITHDRAW_ROLE) onlyRejectedRequest(_requestId) {
    if (pauseStatus[PAUSE_REFUND_WITHDRAW]) revert RefundWithdrawPaused();

    Request memory request = requests[_requestId];
    if (request.requestType != REQUEST_TYPE_WITHDRAW_ZTOKEN) revert InvalidRequestType();

    ExecutionStatus storage executionStatus = executionStatuses[_requestId];
    if (executionStatus.status != EXECUTION_PENDING) revert RequestAlreadyExecuted();

    (address zToken, address fromAccount, , uint256 zAmount) = abi.decode(request.payload, (address, address, bytes, uint256));
    IERC20(zToken).safeTransfer(fromAccount, zAmount);
    feeFactory.settleWithdrawFee(_requestId);

    executionStatus.status = EXECUTION_REFUNDED;

    emit RequestExecuted(_requestId, executionStatus.status);
  }

  function reqDepositZToken(DepositRequest memory request) external nonReentrant onlyRole(RELAYER_ROLE) returns (uint256 requestId) {
    if (pauseStatus[PAUSE_REQUEST_DEPOSIT]) revert DepositRequestPaused();
    if (!chainFactory.isChainEnabled(request.chainId)) revert InvalidChain();
    if (request.zToken == address(0)) revert InvalidZTokenAddress();
    if (!chainFactory.validateEncodedAddress(request.chainId, request.sourceAddress)) revert InvalidSourceAddress();
    if (!chainFactory.validateEncodedAddress(request.chainId, request.depositAddress)) revert InvalidDepositAddress();
    if (keccak256(request.sourceAddress) == keccak256(request.depositAddress)) revert InvalidSourceAddress();

    bytes memory srcToken;
    {
      uint8 zTokenPauseFlags;
      (srcToken, zTokenPauseFlags) = tokenFactory.getZTokenConfig(request.chainId, request.zToken);
      if (srcToken.length == 0) revert SourceTokenNotFound();
      if ((zTokenPauseFlags & ZTOKEN_DEPOSIT_DISABLED) != 0) revert ZTokenDisabled();
    }
    if (_isVaultOrSubVault(request.chainId, srcToken, request.depositAddress)) revert InvalidDepositAddress();

    address account = keyFactory.resolveAccount(request.chainId, request.depositAddress);
    if (account == address(0)) revert InvalidAccount();
    if (request.zAmount == 0) revert InvalidZAmount();
    if (request.sourceHashTx.length == 0) revert InvalidSourceDepositHash();

    bytes memory payload = abi.encode(
      request.zToken,
      request.sourceAddress,
      request.depositAddress,
      account,
      request.zAmount,
      request.sourceHashTx,
      request.sourceHashIndex
    );
    bytes32 requestHash = keccak256(abi.encode(REQUEST_TYPE_DEPOSIT_ZTOKEN, request.chainId, payload));
    if (depositNonces[requestHash]) revert RequestAlreadyAdded();
    depositNonces[requestHash] = true;

    requestId = requests.length;
    uint256 feeZAmount = _lockDepositFeeSnapshot(requestId, request.chainId, request.zToken, request.zAmount);

    requests.push(Request({ requestType: REQUEST_TYPE_DEPOSIT_ZTOKEN, chainId: request.chainId, payload: payload }));
    _snapshotValidationQuorum(requestId);
    validationPendingCount += 1;

    _emitRequestDepositCreated(requestId, requestHash, request, account, feeZAmount);
  }

  function _emitRequestDepositCreated(
    uint256 requestId,
    bytes32 requestHash,
    DepositRequest memory request,
    address account,
    uint256 feeZAmount
  ) private {
    emit RequestDepositCreated(
      requestId,
      REQUEST_TYPE_DEPOSIT_ZTOKEN,
      request.chainId,
      request.zToken,
      requestHash,
      request.sourceAddress,
      request.depositAddress,
      request.sourceHashTx,
      request.sourceHashIndex,
      account,
      request.zAmount - feeZAmount,
      feeZAmount
    );
  }

  function reqWithdrawZToken(WithdrawRequest memory request) external nonReentrant nonRepeat returns (uint256 requestId) {
    return _reqWithdrawZToken(request, _msgSender(), WITHDRAW_ORIGIN_ZIPPER_ENDPOINT, address(this));
  }

  function reqWithdrawZTokenFrom(
    WithdrawRequest memory request,
    address fromAccount,
    uint8 origin,
    address originContract
  ) external nonReentrant onlyRole(WHITELISTED_AGENT_ROLE) returns (uint256 requestId) {
    return _reqWithdrawZToken(request, fromAccount, origin, originContract);
  }

  /**
   * @dev Create a withdraw request.
   *
   * Note: `request.zAmount` is the gross amount paid by `msg.sender`.
   * The destination-chain withdraw amount is `request.zAmount - feeZAmount`.
   * In case of a refund, the locked withdraw amount will be sent back to `fromAccount`.
   */
  function _reqWithdrawZToken(
    WithdrawRequest memory request,
    address fromAccount,
    uint8 origin,
    address originContract
  ) private returns (uint256 requestId) {
    if (pauseStatus[PAUSE_REQUEST_WITHDRAW]) revert WithdrawRequestPaused();

    if (!chainFactory.isChainEnabled(request.chainId)) revert InvalidChain();
    if (request.zToken == address(0)) revert InvalidZTokenAddress();
    if (!chainFactory.validateEncodedAddress(request.chainId, request.withdrawDestination)) revert InvalidWithdrawDestination();
    if (request.zAmount == 0) revert InvalidZAmount();
    if (fromAccount == address(0)) revert InvalidFromAccount();
    bytes memory srcToken;
    {
      uint8 zTokenPauseFlags;
      (srcToken, zTokenPauseFlags) = tokenFactory.getZTokenConfig(request.chainId, request.zToken);
      if (srcToken.length == 0) revert SourceTokenNotFound();
      if ((zTokenPauseFlags & ZTOKEN_WITHDRAWAL_DISABLED) != 0) revert ZTokenDisabled();
    }
    if (_isVaultOrSubVault(request.chainId, srcToken, request.withdrawDestination)) revert InvalidWithdrawDestination();

    uint256 feeZAmount = feeFactory.getFee(request.chainId, request.zToken);
    if (feeZAmount > request.maxFee) revert FeeExceedsMax();
    if (request.zAmount <= feeZAmount) revert WithdrawAmountTooSmallForFee();

    uint256 netZAmount = request.zAmount - feeZAmount;
    IERC20(request.zToken).safeTransferFrom(_msgSender(), address(this), netZAmount);

    requests.push(
      Request({
        requestType: REQUEST_TYPE_WITHDRAW_ZTOKEN,
        chainId: request.chainId,
        payload: abi.encode(request.zToken, fromAccount, request.withdrawDestination, netZAmount)
      })
    );

    requestId = requests.length - 1;

    if (feeZAmount > 0) {
      IERC20(request.zToken).safeTransferFrom(_msgSender(), address(feeFactory), feeZAmount);
      feeFactory.lockWithdrawFee(requestId, request.chainId, request.zToken, feeZAmount);
    }

    _snapshotValidationQuorum(requestId);
    validationPendingCount += 1;

    emit RequestWithdrawCreated(
      requestId,
      origin,
      originContract,
      REQUEST_TYPE_WITHDRAW_ZTOKEN,
      request.chainId,
      request.zToken,
      fromAccount,
      request.withdrawDestination,
      netZAmount,
      feeZAmount
    );
  }

  function _isValidRequestId(uint256 _requestId) internal view returns (bool) {
    return
      _requestId < requests.length &&
      (requests[_requestId].requestType == REQUEST_TYPE_DEPOSIT_ZTOKEN || requests[_requestId].requestType == REQUEST_TYPE_WITHDRAW_ZTOKEN);
  }

  function _isVaultOrSubVault(uint16 chainId, bytes memory srcToken, bytes memory destination) private view returns (bool) {
    if (address(vaultFactory) != address(0)) {
      bytes memory vault = vaultFactory.tokenToVault(chainId, srcToken);
      if (vault.length > 0 && keccak256(vault) == keccak256(destination)) return true;
    }

    if (address(subVaultFactory) != address(0) && subVaultFactory.isAllowedVault(chainId, srcToken, destination)) {
      return true;
    }

    return false;
  }

  function _lockDepositFeeSnapshot(uint256 requestId, uint16 chainId, address zToken, uint256 zAmount) private returns (uint256 feeZAmount) {
    feeZAmount = feeFactory.getFee(chainId, zToken);
    if (feeZAmount > 0) {
      if (zAmount <= feeZAmount) revert DepositAmountTooSmallForFee();
      feeFactory.lockDepositFee(requestId, chainId, zToken, feeZAmount);
    }
  }

  function _snapshotValidationQuorum(uint256 requestId) private {
    uint256 quorumThreshold = validationQuorumThreshold;
    if (quorumThreshold == 0 || quorumThreshold > validatorCount) revert InvalidThreshold();
    validationQuorums[requestId] = quorumThreshold;
  }

  function _loadValidationQuorum(uint256 requestId) private view returns (uint256 quorumThreshold) {
    quorumThreshold = validationQuorums[requestId];
    if (quorumThreshold == 0) revert InvalidThreshold();
  }

  function _applyValidationVote(
    address validator,
    uint256 requestId,
    bool accept,
    uint16 reasonCode,
    uint256 quorumThreshold,
    ValidationStatus storage requestStatus
  ) private {
    if (validatorApprovals[requestId][validator] != VALIDATION_PENDING) revert AlreadyApproved();

    if (accept) {
      if (reasonCode != VALIDATION_REASON_NONE) revert InvalidReasonCode();
      validatorApprovals[requestId][validator] = VALIDATION_APPROVED;
      requestStatus.approveCount += 1;
    } else {
      if (reasonCode == VALIDATION_REASON_NONE) revert InvalidReasonCode();
      validatorApprovals[requestId][validator] = VALIDATION_REJECTED;
      requestStatus.rejectCount += 1;
    }

    // Reject if 1/3 rejected
    if (requestStatus.rejectCount * 3 >= quorumThreshold) {
      requestStatus.status = VALIDATION_REJECTED;
    }
    // Approve if 2/3 approved
    else if (requestStatus.approveCount * 3 >= quorumThreshold * 2) {
      requestStatus.status = VALIDATION_APPROVED;
    }

    // Update validation pending count
    if (requestStatus.status != VALIDATION_PENDING) {
      validationPendingCount -= 1;
      validationReasonCodes[requestId] = reasonCode;
    }

    uint16 emittedReasonCode = accept ? VALIDATION_REASON_NONE : reasonCode;
    emit ValidationStatusRecorded(requestId, validator, validatorApprovals[requestId][validator], emittedReasonCode);

    if (requestStatus.status != VALIDATION_PENDING) {
      emit ValidationFinalized(
        requestId,
        requestStatus.status,
        requestStatus.approveCount,
        requestStatus.rejectCount,
        quorumThreshold,
        emittedReasonCode
      );
    }
  }
}
