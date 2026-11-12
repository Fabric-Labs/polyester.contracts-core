// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IZipperFactoryFee {
  function getFee(uint16 chainId, address token) external view returns (uint256);
}
