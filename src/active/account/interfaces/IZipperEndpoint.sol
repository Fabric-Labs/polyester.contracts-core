// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IZipperEndpoint {
  struct WithdrawRequest {
    uint16 chainId;
    address zToken;
    bytes withdrawDestination;
    uint256 zAmount;
    uint256 maxFee;
  }

  function feeFactory() external view returns (address);

  function reqWithdrawZTokenFrom(
    WithdrawRequest memory request,
    address fromAccount,
    uint8 origin,
    address originContract
  ) external returns (uint256 requestId);
}
