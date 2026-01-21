// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title AutocompoundV3SingleHop.t.sol
 * @notice Ethereum fork test for SwapAdapter (Uniswap V3 single-hop) + xMETRO.autocompound.
 */

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { SwapAdapter } from "../../src/SwapAdapter.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract AutocompoundV3SingleHopForkTest is Test {
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant UNISWAP_V2_ROUTER02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNISWAP_SWAPROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    address internal user = address(0xB0B);

    function test_Autocompound_V3_SingleHop() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing ETH_RPC_URL");

        address routerV2 = vm.envOr("UNISWAP_V2_ROUTER02", UNISWAP_V2_ROUTER02);
        address routerV3 = vm.envOr("UNISWAP_SWAPROUTER02", UNISWAP_SWAPROUTER02);
        address quoterV3 = vm.envOr("UNISWAP_QUOTER_V2", UNISWAP_QUOTER_V2);
        if (quoterV3 == address(0)) vm.skip(true, "missing UNISWAP_QUOTER_V2");
        uint24 fee = uint24(vm.envOr("V3_FEE_SINGLE", uint256(100)));

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

        uint256 pending = xmetro.claimable(user);
        require(pending > 0, "no pending");

        (uint24 selectedFee, uint256 quoteOut) = _quoteAndSelectFee(quoterV3, pending, fee);
        require(quoteOut > 0, "quoteOut=0");

        bytes memory path = abi.encodePacked(MAINNET_USDC, selectedFee, MAINNET_WETH);
        bytes memory swapData = abi.encode(uint8(1), path);

        uint256 minOut = (quoteOut * 90) / 100;
        require(minOut > 0, "minOut=0");

        uint256 beforeShares = xmetro.balanceOf(user);
        vm.prank(user);
        uint256 received = xmetro.autocompound(minOut, swapData);
        uint256 afterShares = xmetro.balanceOf(user);

        assertGt(afterShares, beforeShares, "freeShares should increase");
        assertGe(received, minOut, "received should be >= minOut");
    }

    /**
     * @dev Quote via Quoter and select a workable fee/tickSpacing from common candidates.
     */
    function _quoteAndSelectFee(address quoter, uint256 amountIn, uint24 preferredFee)
        internal
        returns (uint24 fee, uint256 amountOut)
    {
        uint24[5] memory candidates = [preferredFee, uint24(100), uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i = 0; i < candidates.length; i++) {
            uint24 f = candidates[i];
            if (f == 0) continue;

            (bool okSingle, uint256 outSingle) = _tryQuoteExactInputSingle(quoter, MAINNET_USDC, MAINNET_WETH, f, amountIn);
            if (okSingle && outSingle > 0) return (f, outSingle);

            bytes memory path = abi.encodePacked(MAINNET_USDC, f, MAINNET_WETH);
            (bool okPath, uint256 outPath) = _tryQuoteExactInput(quoter, path, amountIn);
            if (okPath && outPath > 0) return (f, outPath);
        }

        vm.skip(true, "quoter failed: bad quoter addr or no pool for provided fee(s)");
        return (0, 0);
    }

    /// @dev Compatibility with Quoter/QuoterV2: quoteExactInput(bytes,uint256) (often non-view; use call).
    function _tryQuoteExactInput(address quoter, bytes memory path, uint256 amountIn)
        internal
        returns (bool ok, uint256 out)
    {
        bytes memory data;
        (ok, data) = quoter.call(abi.encodeWithSignature("quoteExactInput(bytes,uint256)", path, amountIn));
        if (!ok || data.length < 32) return (false, 0);

        out = abi.decode(data, (uint256));
        return (true, out);
    }

    /// @dev Compatibility with QuoterV2: quoteExactInputSingle(address,address,uint24,uint256,uint160).
    function _tryQuoteExactInputSingle(address quoter, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        returns (bool ok, uint256 out)
    {
        bytes memory data;
        (ok, data) = quoter.call(
            abi.encodeWithSignature(
                "quoteExactInputSingle(address,address,uint24,uint256,uint160)", tokenIn, tokenOut, fee, amountIn, 0
            )
        );
        if (!ok || data.length < 32) return (false, 0);
        out = abi.decode(data, (uint256));
        return (true, out);
    }

    function _fundUSDC(address usdc, address to, uint256 amount) internal {
        deal(usdc, to, amount);
        if (IERC20(usdc).balanceOf(to) >= amount) return;

        address whale = vm.envOr("USDC_WHALE", address(0));
        if (whale == address(0)) vm.skip(true, "deal(USDC) failed and missing USDC_WHALE");

        vm.prank(whale);
        IERC20(usdc).transfer(to, amount);
    }
}
