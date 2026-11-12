// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

library StringLib {
  /**
   * @dev Converts a string to lowercase
   * @param str The string to convert
   * @return The lowercase string
   */
  function toLowerCase(string memory str) internal pure returns (string memory) {
    bytes memory bStr = bytes(str);
    for (uint256 i = 0; i < bStr.length; i++) {
      if (bStr[i] >= 0x41 && bStr[i] <= 0x5A) {
        bStr[i] = bytes1(uint8(bStr[i]) + 32);
      }
    }
    return string(bStr);
  }
}
