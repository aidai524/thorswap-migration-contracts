// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MaliciousSwapAdapter
 * @notice Malicious swap adapter that tries to reenter xMETRO during swap (tests only).
 */
contract MaliciousSwapAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;

    address public immutable xMETRO;

    /// @notice Output multiplier for simulation.
    uint256 public mul;
    uint256 public div;

    /// @notice Reentrancy attack config.
    bytes public attackData;
    bool public attackEnabled;
    bool public attackAttempted;
    bool public attackSucceeded;
    bool private _attacking;

    constructor(address tokenIn_, address tokenOut_, address xMETRO_, uint256 mul_, uint256 div_) {
        require(tokenIn_ != address(0) && tokenOut_ != address(0), "Bad token");
        require(xMETRO_ != address(0), "Bad xMETRO");
        require(div_ != 0, "div=0");
        tokenIn = IERC20(tokenIn_);
        tokenOut = IERC20(tokenOut_);
        xMETRO = xMETRO_;
        mul = mul_;
        div = div_;
    }

    function setAttack(bytes calldata attackData_, bool enabled_) external {
        attackData = attackData_;
        attackEnabled = enabled_;
        attackAttempted = false;
        attackSucceeded = false;
    }

    function swap(uint256 amountIn, uint256 minAmountOut, bytes calldata) external returns (uint256 amountOut) {
        require(msg.sender == xMETRO, "only xMETRO");
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        _maybeAttack();

        amountOut = (amountIn * mul) / div;
        require(amountOut >= minAmountOut, "slippage");
        tokenOut.safeTransfer(xMETRO, amountOut);
        return amountOut;
    }

    function _maybeAttack() internal {
        if (!attackEnabled) return;
        if (_attacking) return;
        _attacking = true;
        attackAttempted = true;
        (bool ok,) = xMETRO.call(attackData);
        if (ok) attackSucceeded = true;
        _attacking = false;
    }
}
