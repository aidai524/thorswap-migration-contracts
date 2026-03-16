// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import { MetroTokenOFT } from "../../src/metro.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";

contract MetroTokenOFTFuzzTest is Test {
    MockEndpointV2 internal endpoint;
    MetroTokenOFT internal metro;

    address internal owner = address(this);

    function setUp() public {
        endpoint = new MockEndpointV2();
        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), owner);
    }

    function testFuzz_Mint_RespectsMinterAllowlist(address minter, address to, uint256 amount, bool allowed) public {
        vm.assume(minter != address(0));
        vm.assume(to != address(0));
        amount = bound(amount, 1, 1e36);

        if (allowed) {
            metro.setMinter(minter, true);
        }

        if (!allowed) {
            vm.prank(minter);
            vm.expectRevert(bytes("MetroToken: not minter"));
            metro.mint(to, amount);
            return;
        }

        uint256 beforeSupply = metro.totalSupply();
        uint256 beforeBal = metro.balanceOf(to);

        vm.prank(minter);
        metro.mint(to, amount);

        assertEq(metro.totalSupply(), beforeSupply + amount);
        assertEq(metro.balanceOf(to), beforeBal + amount);
    }

    function testFuzz_SetMinter_Toggles(address minter, bool a, bool b) public {
        vm.assume(minter != address(0));

        if (a) {
            metro.setMinter(minter, true);
        }
        assertEq(metro.isMinter(minter), a);

        if (a != b) {
            metro.setMinter(minter, b);
        }
        assertEq(metro.isMinter(minter), b);
    }
}
