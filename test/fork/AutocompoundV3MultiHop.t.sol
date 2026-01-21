// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title AutocompoundV3MultiHop.t.sol
 * @notice Ethereum fork test for SwapAdapter (Uniswap V3 multi-hop) + xMETRO.autocompound.
 */

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { SwapAdapter } from "../../src/SwapAdapter.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract AutocompoundV3MultiHopForkTest is Test {
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant UNISWAP_V2_ROUTER02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNISWAP_SWAPROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    address internal user = address(0xB0B);

    function test_Autocompound_V3_MultiHop() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing ETH_RPC_URL");

        address routerV2 = vm.envOr("UNISWAP_V2_ROUTER02", UNISWAP_V2_ROUTER02);
        address routerV3 = vm.envOr("UNISWAP_SWAPROUTER02", UNISWAP_SWAPROUTER02);
        address quoterV3 = vm.envOr("UNISWAP_QUOTER_V2", UNISWAP_QUOTER_V2);
        if (quoterV3 == address(0)) vm.skip(true, "missing UNISWAP_QUOTER_V2");

        address mid = vm.envOr("V3_MID_TOKEN", address(0));
        if (mid == address(0)) vm.skip(true, "missing V3_MID_TOKEN");

        uint24 fee1 = uint24(vm.envOr("V3_FEE_1", uint256(100)));
        uint24 fee2 = uint24(vm.envOr("V3_FEE_2", uint256(100)));

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

        (uint24 selectedFee1, uint24 selectedFee2, uint256 quoteOut) = _quoteAndSelectFees(quoterV3, pending, mid, fee1, fee2);
        require(quoteOut > 0, "quoteOut=0");

        bytes memory path = abi.encodePacked(MAINNET_USDC, selectedFee1, mid, selectedFee2, MAINNET_WETH);
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
     * @dev Multi-hop quote: select a workable fee1/fee2 combination.
     */
    function _quoteAndSelectFees(address quoter, uint256 amountIn, address mid, uint24 preferredFee1, uint24 preferredFee2)
        internal
        returns (uint24 fee1, uint24 fee2, uint256 amountOut)
    {
        uint24[4] memory common = [uint24(100), uint24(500), uint24(3000), uint24(10000)];

        if (preferredFee1 != 0 && preferredFee2 != 0) {
            bytes memory path0 = abi.encodePacked(MAINNET_USDC, preferredFee1, mid, preferredFee2, MAINNET_WETH);
            (bool ok0, uint256 out0) = _tryQuoteExactInput(quoter, path0, amountIn);
            if (ok0 && out0 > 0) return (preferredFee1, preferredFee2, out0);
        }

        for (uint256 i = 0; i < common.length; i++) {
            for (uint256 j = 0; j < common.length; j++) {
                bytes memory path = abi.encodePacked(MAINNET_USDC, common[i], mid, common[j], MAINNET_WETH);
                (bool ok, uint256 out) = _tryQuoteExactInput(quoter, path, amountIn);
                if (ok && out > 0) return (common[i], common[j], out);
            }
        }

        vm.skip(true, "quoter failed: bad quoter addr or no pool for provided MID/fee(s)");
        return (0, 0, 0);
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

    function _fundUSDC(address usdc, address to, uint256 amount) internal {
        deal(usdc, to, amount);
        if (IERC20(usdc).balanceOf(to) >= amount) return;

        address whale = vm.envOr("USDC_WHALE", address(0));
        if (whale == address(0)) vm.skip(true, "deal(USDC) failed and missing USDC_WHALE");

        vm.prank(whale);
        IERC20(usdc).transfer(to, amount);
    }
}
