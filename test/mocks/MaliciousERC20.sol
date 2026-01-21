// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC20Mintable } from "./ERC20Mintable.sol";

/**
 * @title MaliciousERC20
 * @notice Malicious ERC20 that attempts to reenter a target during transfer/transferFrom (tests only).
 */
contract MaliciousERC20 is ERC20Mintable {
    address public target;
    bytes public attackData;
    bool public attackEnabled;

    bool public attackAttempted;
    bool public attackSucceeded;
    bool private _attacking;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20Mintable(name_, symbol_, decimals_) {}

    /// @notice Configure the attack target and calldata.
    function setAttack(address target_, bytes calldata attackData_, bool enabled_) external {
        target = target_;
        attackData = attackData_;
        attackEnabled = enabled_;
        attackAttempted = false;
        attackSucceeded = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _maybeAttack();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _maybeAttack();
        return ok;
    }

    function _maybeAttack() internal {
        if (!attackEnabled) return;
        if (msg.sender != target) return;
        if (_attacking) return;

        _attacking = true;
        attackAttempted = true;

        (bool ok,) = target.call(attackData);
        if (ok) attackSucceeded = true;

        _attacking = false;
    }
}
