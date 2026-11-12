// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

contract RepeatCallGuard {
  mapping(address => uint256) internal _lastCallTxs;
  mapping(address => bool) internal _allowRepeatCall;

  /**
   * @dev This empty reserved space is put in place to allow future versions to add new
   * variables without shifting down storage in the inheritance chain.
   * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
   */
  uint256[48] private __gap;

  error RepeatCallNotAllowed();

  // Modifier to ensure non-repeating transactions
  modifier nonRepeat() {
    if (!_allowRepeatCall[msg.sender] && _lastCallTxs[msg.sender] == block.number) revert RepeatCallNotAllowed();
    _lastCallTxs[msg.sender] = block.number;
    _;
  }

  // Function to check if the caller is allowed to repeat the call
  function isAllowedToRepeat(address sender) external view returns (bool) {
    return _allowRepeatCall[sender];
  }
}
