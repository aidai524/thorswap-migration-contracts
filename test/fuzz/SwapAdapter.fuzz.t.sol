// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SwapAdapter, IV3SwapRouter } from "../../src/SwapAdapter.sol";
import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";

contract SwapAdapterFuzzTest is Test {
    address internal xmetro = makeAddr("xMETRO");
    address internal owner = address(this);

    ERC20Mintable internal usdc;
    ERC20Mintable internal metro;

    SwapAdapter internal adapter;
    FuzzRouterV2 internal routerV2;
    FuzzRouterV3 internal routerV3;

    uint8 internal constant DEX_V2 = 0;
    uint8 internal constant DEX_V3 = 1;

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new ERC20Mintable("METRO", "METRO", 18);

        routerV2 = new FuzzRouterV2(address(usdc), address(metro));
        routerV3 = new FuzzRouterV3(address(usdc), address(metro));

        adapter = new SwapAdapter(address(usdc), address(metro), xmetro, address(routerV2), address(routerV3), owner);

        vm.prank(xmetro);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function testFuzz_Swap_V2_Success_AllowanceReset(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e18);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(metro);
        bytes memory swapData = abi.encode(uint8(DEX_V2), abi.encode(path));

        usdc.mint(xmetro, amountIn);

        vm.prank(xmetro);
        uint256 out = adapter.swap(amountIn, amountIn * 2, swapData);

        assertEq(out, amountIn * 2);
        assertEq(metro.balanceOf(xmetro), amountIn * 2);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
    }

    function testFuzz_Swap_V3_Success_AllowanceReset(uint256 amountIn, uint24 fee) public {
        amountIn = bound(amountIn, 1, 1e18);

        bytes memory path = abi.encodePacked(address(usdc), fee, address(metro));
        bytes memory swapData = abi.encode(uint8(DEX_V3), path);

        usdc.mint(xmetro, amountIn);

        vm.prank(xmetro);
        uint256 out = adapter.swap(amountIn, amountIn * 2, swapData);

        assertEq(out, amountIn * 2);
        assertEq(metro.balanceOf(xmetro), amountIn * 2);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(routerV3)), 0);
    }

    function testFuzz_Swap_BadDexType_Revert(uint256 amountIn, uint8 dexType) public {
        amountIn = bound(amountIn, 1, 1e18);
        vm.assume(dexType != DEX_V2 && dexType != DEX_V3);

        usdc.mint(xmetro, amountIn);

        vm.prank(xmetro);
        vm.expectRevert(bytes("SwapAdapter: bad dexType"));
        adapter.swap(amountIn, 0, abi.encode(dexType, bytes("")));
    }

    function testFuzz_Swap_V3_BadPath_Revert(uint256 amountIn, uint256 badLen) public {
        amountIn = bound(amountIn, 1, 1e18);
        badLen = bound(badLen, 0, 200);

        bytes memory badPath = new bytes(badLen);
        bytes memory swapData = abi.encode(uint8(DEX_V3), badPath);

        usdc.mint(xmetro, amountIn);

        vm.prank(xmetro);
        vm.expectRevert();
        adapter.swap(amountIn, 0, swapData);
    }
}

contract FuzzRouterV2 {
    IERC20 internal inToken;
    ERC20Mintable internal outToken;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(inToken.transferFrom(msg.sender, address(this), amountIn), "transferFrom failed");
        outToken.mint(to, amountIn * 2);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 2;
    }
}

contract FuzzRouterV3 {
    IERC20 internal inToken;
    ERC20Mintable internal outToken;

    constructor(address inToken_, address outToken_) {
        inToken = IERC20(inToken_);
        outToken = ERC20Mintable(outToken_);
    }

    function exactInput(IV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        require(inToken.transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");
        amountOut = params.amountIn * 2;
        outToken.mint(params.recipient, amountOut);
    }
}

