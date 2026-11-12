// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract ZToken is ERC20Permit, Ownable {
  string public description;

  event DescriptionUpdated(string description);

  constructor(string memory name, string memory symbol, string memory desc) ERC20(name, symbol) ERC20Permit(name) Ownable(msg.sender) {
    description = desc;
  }

  function updateDescription(string calldata newDescription) external onlyOwner {
    description = newDescription;
    emit DescriptionUpdated(newDescription);
  }

  function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
  }

  function burn(uint256 amount) external onlyOwner {
    _burn(msg.sender, amount);
  }
}
