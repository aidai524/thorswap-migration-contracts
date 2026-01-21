// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title AutocompoundV2.t.sol
 * @notice Ethereum fork test for SwapAdapter (Uniswap V2) + xMETRO.autocompound using real mainnet liquidity.
 */

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { SwapAdapter } from "../../src/SwapAdapter.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

/// @notice Quote interface for Uniswap V2 swaps.
interface IUniswapV2Router02Quote {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

contract AutocompoundV2ForkTest is Test {
    // Ethereum mainnet addresses.
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant UNISWAP_V2_ROUTER02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNISWAP_SWAPROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    address internal user = address(0xB0B);

    function test_Autocompound_V2_USDC_to_WETH() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing ETH_RPC_URL");

        address routerV2 = vm.envOr("UNISWAP_V2_ROUTER02", UNISWAP_V2_ROUTER02);
        address routerV3 = vm.envOr("UNISWAP_SWAPROUTER02", UNISWAP_SWAPROUTER02);

        vm.createSelectFork(rpc);

        xMETRO xmetro = new xMETRO(address(this), MAINNET_WETH, MAINNET_USDC, address(0));
        xmetro.setRewardDistributor(address(this));

        SwapAdapter adapter =
            new SwapAdapter(MAINNET_USDC, MAINNET_WETH, address(xmetro), routerV2, routerV3, address(this));
        xmetro.setSwapAdapter(address(adapter));

        vm.deal(user, 10 ether);
        vm.prank(user);
        IWETH(MAINNET_WETH).deposit{ value: 10 ether }();
        vm.prank(user);
        IERC20(MAINNET_WETH).approve(address(xmetro), type(uint256).max);
        vm.prank(user);
        xmetro.stake(5 ether);

        uint256 rewards = 100 * 1e6;
        _fundUSDC(MAINNET_USDC, address(this), rewards);
        IERC20(MAINNET_USDC).approve(address(xmetro), rewards);
        xmetro.depositRewards(rewards);

        address[] memory path = new address[](2);
        path[0] = MAINNET_USDC;
        path[1] = MAINNET_WETH;
        bytes memory swapData = abi.encode(uint8(0), abi.encode(path));

        uint256 pending = xmetro.claimable(user);
        require(pending > 0, "no pending");

        uint256 quoteOut;
        try IUniswapV2Router02Quote(routerV2).getAmountsOut(pending, path) returns (uint256[] memory amts) {
            quoteOut = amts[amts.length - 1];
        } catch {
            vm.skip(true, "routerV2 missing getAmountsOut");
        }

        uint256 minOut = (quoteOut * 90) / 100;
        require(minOut > 0, "minOut=0");

        uint256 beforeShares = xmetro.balanceOf(user);
        uint256 beforeWeth = IERC20(MAINNET_WETH).balanceOf(address(xmetro));
        vm.prank(user);
        uint256 received = xmetro.autocompound(minOut, swapData);
        uint256 afterShares = xmetro.balanceOf(user);
        uint256 afterWeth = IERC20(MAINNET_WETH).balanceOf(address(xmetro));

        assertGt(afterShares, beforeShares, "freeShares should increase");
        assertGt(afterWeth, beforeWeth, "xMETRO METRO balance should increase");
        assertGe(received, minOut, "received should be >= minOut");
    }

    /// @dev Fund USDC to `to` (prefer `deal`, fallback to whale transfer if configured).
    function _fundUSDC(address usdc, address to, uint256 amount) internal {
        deal(usdc, to, amount);
        if (IERC20(usdc).balanceOf(to) >= amount) return;

        address whale = vm.envOr("USDC_WHALE", address(0));
        if (whale == address(0)) vm.skip(true, "deal(USDC) failed and missing USDC_WHALE");

        vm.prank(whale);
        IERC20(usdc).transfer(to, amount);
    }
}
