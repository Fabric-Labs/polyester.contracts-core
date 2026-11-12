// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IProgramReceiver {
  /// @notice Called when Zipped Tokens are minted for an account
  /// @param requestId The Zipper request ID that triggered the mint
  /// @param chainId The chain ID of the token
  /// @param zToken The address of the Zipped Token
  /// @param creditedAccount The account that receives the credited Zipped Amount
  /// @param zAmount The Zipped Amount minted
  /// @return accepted true if the minting was successful, false otherwise
  /// @return finalRouteReceiver The contract address where the routed deposit ended
  function onTokensMinted(
    uint256 requestId,
    uint16 chainId,
    address zToken,
    address creditedAccount,
    uint256 zAmount
  ) external returns (bool accepted, address finalRouteReceiver);
}
