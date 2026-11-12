// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

library MathLib {
  /**
   * @dev Converts an amount from one token to another considering their decimal places
   * @param amount The amount of the first token (with full decimals)
   * @param decimalsIn The number of decimal places for the first token
   * @param decimalsOut The number of decimal places for the second token
   * @return amountOut The equivalent amount of the second token (with full decimals) truncated to `decimalsOut`
   * @return normalizedAmountIn The input amount normalized to the maximum amount representable after conversion
   *
   * This function handles decimal conversion by:
   * - Scaling down if the first token has more decimals
   * - Scaling up if the second token has more decimals
   * - Returning both the converted amount and the truncated input amount to limit rounding side-effects
   */
  function convertDecimals(
    uint256 amount,
    uint8 decimalsIn,
    uint8 decimalsOut
  ) internal pure returns (uint256 amountOut, uint256 normalizedAmountIn) {
    if (decimalsIn > decimalsOut) {
      // Scale down: divide by the difference in decimal places which could lead to precision loss
      uint256 scaleDown = 10 ** (decimalsIn - decimalsOut);
      amountOut = amount / scaleDown;
      normalizedAmountIn = amountOut * scaleDown;
    } else if (decimalsOut > decimalsIn) {
      // Scale up: multiply by the difference in decimal places
      uint256 scaleUp = 10 ** (decimalsOut - decimalsIn);
      amountOut = amount * scaleUp;
      normalizedAmountIn = amount;
    } else {
      // Same decimals: no conversion needed
      amountOut = amount;
      normalizedAmountIn = amount;
    }
  }
}
