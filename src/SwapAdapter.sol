// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal Uniswap V2 Router02 interface.
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Minimal Uniswap V3 swap router interface (SwapRouter02-compatible).
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

contract SwapAdapter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice DEX type: Uniswap V2.
    uint8 public constant DEX_V2 = 0;

    /// @notice DEX type: Uniswap V3.
    uint8 public constant DEX_V3 = 1;


    IERC20 public immutable USDC;


    IERC20 public immutable METRO;


    address public immutable xMETRO;

    /// @notice Uniswap V2 router.
    address public immutable routerV2;

    /// @notice Uniswap V3 router.
    address public immutable routerV3;


    event Swapped(uint256 amountIn, uint256 amountOut, uint8 dexType);


    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address usdc_,
        address metro_,
        address xMetro_,
        address routerV2_,
        address routerV3_,
        address owner_
    ) Ownable(owner_) {
        require(usdc_ != address(0) && metro_ != address(0) && xMetro_ != address(0), "SwapAdapter: zero addr");
        require(routerV2_ != address(0) && routerV3_ != address(0), "SwapAdapter: zero router");

        USDC = IERC20(usdc_);
        METRO = IERC20(metro_);
        xMETRO = xMetro_;
        routerV2 = routerV2_;
        routerV3 = routerV3_;
    }

    /// @dev Only xMETRO can call.
    modifier onlyXMetro() {
        require(msg.sender == xMETRO, "SwapAdapter: only xMETRO");
        _;
    }

    /**
     * @notice Execute a swap from USDC -> METRO and send the output to xMETRO.
     * @param swapData abi.encode(uint8 dexType, bytes pathData)
     * - dexType=0: Uniswap V2 (pathData = abi.encode(address[] path))
     * - dexType=1: Uniswap V3 (pathData = packed path bytes)
     * @dev Security relies on balance-delta check on xMETRO.
     */
    function swap(uint256 amountIn, uint256 minAmountOut, bytes calldata swapData)
        external
        onlyXMetro
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "SwapAdapter: zero amount");

        uint256 balanceBefore = METRO.balanceOf(xMETRO);

        USDC.safeTransferFrom(msg.sender, address(this), amountIn);

        (uint8 dexType, bytes memory pathData) = abi.decode(swapData, (uint8, bytes));

        if (dexType == DEX_V2) {
            _swapV2(amountIn, pathData);
        } else if (dexType == DEX_V3) {
            _swapV3(amountIn, pathData);
        } else {
            revert("SwapAdapter: bad dexType");
        }

        uint256 balanceAfter = METRO.balanceOf(xMETRO);
        uint256 received = balanceAfter - balanceBefore;
        require(received >= minAmountOut, "SwapAdapter: slippage");

        emit Swapped(amountIn, received, dexType);
        return received;
    }

    /// @notice Pause swaps.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause swaps.
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Rescue tokens sent to this contract by mistake (onlyOwner).
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "SwapAdapter: bad to");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @dev Uniswap V2 swap: pathData = abi.encode(address[] path).
    function _swapV2(uint256 amountIn, bytes memory pathData) internal {
        address[] memory path = abi.decode(pathData, (address[]));
        require(path.length >= 2, "SwapAdapter: bad path");

        require(path[0] == address(USDC), "SwapAdapter: bad path in");
        require(path[path.length - 1] == address(METRO), "SwapAdapter: bad path out");

        USDC.forceApprove(routerV2, amountIn);

        IUniswapV2Router02(routerV2).swapExactTokensForTokens(
            amountIn,
            0,
            path,
            xMETRO,
            block.timestamp
        );

        USDC.forceApprove(routerV2, 0);
    }

    /// @dev Uniswap V3 swap: pathData = packed path bytes.
    function _swapV3(uint256 amountIn, bytes memory pathData) internal {
        require(pathData.length >= 43, "SwapAdapter: bad path");
        require((pathData.length - 20) % 23 == 0, "SwapAdapter: bad path len");

        require(_firstToken(pathData) == address(USDC), "SwapAdapter: bad path in");
        require(_lastToken(pathData) == address(METRO), "SwapAdapter: bad path out");

        USDC.forceApprove(routerV3, amountIn);

        IV3SwapRouter.ExactInputParams memory paramsNoDeadline = IV3SwapRouter.ExactInputParams({
            path: pathData,
            recipient: xMETRO,
            amountIn: amountIn,
            amountOutMinimum: 0
        });
        try IV3SwapRouter(routerV3).exactInput(paramsNoDeadline) returns (uint256) { }
        catch {
            revert("SwapAdapter: v3 swap failed");
        }

        USDC.forceApprove(routerV3, 0);
    }

    /// @dev Read the first token of a packed path (first 20 bytes).
    function _firstToken(bytes memory path) internal pure returns (address token) {
        assembly {
            token := shr(96, mload(add(path, 32)))
        }
    }

    /// @dev Read the last token of a packed path (last 20 bytes).
    function _lastToken(bytes memory path) internal pure returns (address token) {
        uint256 len = path.length;
        assembly {
            token := shr(96, mload(add(add(path, 32), sub(len, 20))))
        }
    }
}
