// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IUAssetReceiver {
  /**
   * @dev Deposits Unified Assets into the route receiver contract on behalf of a bridge request.
   *      Should validate and credit the account in the route receiver contract.
   * @param requestId The Zipper request ID that triggered the deposit
   * @param account The account to credit
   * @param uAssetId The Unified Asset Id to deposit
   * @param uAmount The Unified Amount to deposit
   * @return finalRouteReceiver The contract address where the routed deposit ended
   */
  function depositForRequest(uint256 requestId, address account, bytes32 uAssetId, uint256 uAmount) external returns (address finalRouteReceiver);
}
