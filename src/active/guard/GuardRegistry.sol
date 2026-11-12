// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./interfaces/IGuardRegistry.sol";

contract GuardRegistry is IGuardRegistry, AccessControl, EIP712 {
  bytes32 public constant AUTHORIZED_CALLER_ROLE = keccak256("AUTHORIZED_CALLER_ROLE");

  bytes32 private constant APPROVAL_TYPEHASH =
    keccak256("Approval(address account,address target,bytes4 selector,bytes32 paramsHash,uint192 nonceSpace,uint256 nonce,uint256 deadline)");

  mapping(address account => address signer) public override signerOf;
  mapping(address account => mapping(uint192 nonceSpace => uint256 nonce)) public override nonceOf;

  error ZeroSigner();
  error SignerAlreadyInitialized();
  error SignerNotInitialized();
  error SignatureExpired();
  error InvalidSignature();
  error InvalidApprovalTarget();
  error SignerUnchanged();
  error SignerCannotBeAccount();

  event SignerInitialized(address indexed account, address indexed signer);
  event SignerRotated(address indexed account, address indexed previousSigner, address indexed newSigner);
  event ApprovalConsumed(
    address indexed account,
    address indexed target,
    bytes4 indexed selector,
    uint192 nonceSpace,
    uint256 nonce,
    bytes32 paramsHash
  );

  constructor() EIP712("GuardRegistry", "1") {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function initializeSigner(address signer) external override {
    if (signer == address(0)) revert ZeroSigner();
    if (signerOf[msg.sender] != address(0)) revert SignerAlreadyInitialized();
    if (signer == msg.sender) revert SignerCannotBeAccount();

    signerOf[msg.sender] = signer;
    emit SignerInitialized(msg.sender, signer);
  }

  /// @dev Rotation approvals use the full external selector, including the Approval tuple in calldata.
  /// @dev NOTE: For rotation approvals, the param hash is keccak256(abi.encode(currentSigner, newSigner))
  /// whereas for regular application approvals, the param hash encodes application/operation-specific parameters.
  function rotateSigner(address newSigner, Approval calldata approval) external override {
    if (newSigner == address(0)) revert ZeroSigner();

    address account = msg.sender;
    address currentSigner = signerOf[account];
    if (currentSigner == address(0)) revert SignerNotInitialized();
    if (newSigner == currentSigner) revert SignerUnchanged();
    if (newSigner == account) revert SignerCannotBeAccount();
    bytes32 paramsHash = keccak256(abi.encode(currentSigner, newSigner));

    uint256 nonce = _consumeApproval(account, address(this), this.rotateSigner.selector, paramsHash, approval);

    signerOf[account] = newSigner;
    emit SignerRotated(account, currentSigner, newSigner);
    emit ApprovalConsumed(account, address(this), this.rotateSigner.selector, approval.nonceSpace, nonce, paramsHash);
  }

  function consumeApproval(
    address account,
    address target,
    bytes4 selector,
    bytes32 paramsHash,
    Approval calldata approval
  ) external override onlyRole(AUTHORIZED_CALLER_ROLE) {
    if (target != msg.sender) revert InvalidApprovalTarget();

    uint256 nonce = _consumeApproval(account, target, selector, paramsHash, approval);

    emit ApprovalConsumed(account, target, selector, approval.nonceSpace, nonce, paramsHash);
  }

  function _consumeApproval(
    address account,
    address target,
    bytes4 selector,
    bytes32 paramsHash,
    Approval calldata approval
  ) internal returns (uint256 nonce) {
    address currentSigner = signerOf[account];
    if (currentSigner == address(0)) revert SignerNotInitialized();

    nonce = nonceOf[account][approval.nonceSpace];
    _assertValidSignature(
      currentSigner,
      _hashApproval(account, target, selector, paramsHash, approval.nonceSpace, nonce, approval.deadline),
      approval.deadline,
      approval.signature
    );
    nonceOf[account][approval.nonceSpace] = nonce + 1;
  }

  function _assertValidSignature(address currentSigner, bytes32 digest, uint256 deadline, bytes calldata signature) internal view {
    if (block.timestamp > deadline) revert SignatureExpired();
    if (!SignatureChecker.isValidSignatureNow(currentSigner, digest, signature)) revert InvalidSignature();
  }

  function _hashApproval(
    address account,
    address target,
    bytes4 selector,
    bytes32 paramsHash,
    uint192 nonceSpace,
    uint256 nonce,
    uint256 deadline
  ) internal view returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(APPROVAL_TYPEHASH, account, target, selector, paramsHash, nonceSpace, nonce, deadline)));
  }
}
