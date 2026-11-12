// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IGuardRegistry {
  struct Approval {
    uint192 nonceSpace;
    uint256 deadline;
    bytes signature;
  }

  function signerOf(address account) external view returns (address);

  function nonceOf(address account, uint192 nonceSpace) external view returns (uint256);

  function initializeSigner(address signer) external;

  function rotateSigner(address newSigner, Approval calldata approval) external;

  function consumeApproval(address account, address target, bytes4 selector, bytes32 paramsHash, Approval calldata approval) external;
}
