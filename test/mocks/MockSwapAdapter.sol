// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockSwapAdapter
 * @notice Mock swap adapter: no real swap, sends output back to xMETRO at a fixed rate (tests only).
 */
contract MockSwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice Input token (rewardToken, e.g. USDC).
    IERC20 public immutable tokenIn;

    /// @notice Output token (METRO or a fork substitute).
    IERC20 public immutable tokenOut;

    /// @notice Allowed caller for `swap`.
    address public xMETRO;

    /// @notice Fixed rate: amountOut = amountIn * mul / div.
    uint256 public mul;
    uint256 public div;

    constructor(address tokenIn_, address tokenOut_, uint256 mul_, uint256 div_) {
        require(tokenIn_ != address(0) && tokenOut_ != address(0), "MockAdapter: zero token");
        require(div_ != 0, "MockAdapter: div=0");
        tokenIn = IERC20(tokenIn_);
        tokenOut = IERC20(tokenOut_);
        mul = mul_;
        div = div_;
    }

    /// @notice Set xMETRO address (to avoid circular deployment).
    function setXMetro(address xMetro_) external {
        xMETRO = xMetro_;
    }

    /// @notice Update fixed rate.
    function setRate(uint256 mul_, uint256 div_) external {
        require(div_ != 0, "MockAdapter: div=0");
        mul = mul_;
        div = div_;
    }

    /**
     * @notice Swap interface used by xMETRO.autocompound in tests.
     */
    function swap(uint256 amountIn, uint256 minAmountOut, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        require(msg.sender == xMETRO, "MockAdapter: only xMETRO");
        require(amountIn > 0, "MockAdapter: zero amount");

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = (amountIn * mul) / div;
        require(amountOut >= minAmountOut, "MockAdapter: slippage");

        tokenOut.safeTransfer(xMETRO, amountOut);
        return amountOut;
    }
}
