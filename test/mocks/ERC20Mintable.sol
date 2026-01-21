// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Mintable
 * @notice Mintable ERC20 for tests (custom decimals).
 * @dev Test-only.
 */
contract ERC20Mintable is ERC20 {
    /// @dev Custom decimals.
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Test mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
