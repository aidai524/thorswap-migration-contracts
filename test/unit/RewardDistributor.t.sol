// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title RewardDistributor.t.sol
 * @notice Unit tests for RewardDistributor.
 */

import "forge-std/Test.sol";

import { RewardDistributor } from "../../src/RewardDistributor.sol";
import { xMETRO } from "../../src/xMETRO.sol";
import { MetroTokenOFT } from "../../src/metro.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";

contract RewardDistributorTest is Test {
    MockEndpointV2 internal endpoint;
    ERC20Mintable internal usdc;
    MetroTokenOFT internal metro;
    xMETRO internal xmetro;
    RewardDistributor internal distributor;

    address internal owner = address(this);
    address internal user = address(0xBEEF);

    function setUp() public {
        endpoint = new MockEndpointV2();
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), owner);
        metro.setMinter(owner, true);

        xmetro = new xMETRO(owner, address(metro), address(usdc), address(0));
        metro.setMinter(address(xmetro), true);

        distributor = new RewardDistributor(address(xmetro), address(usdc), owner);
        distributor.setOperator(owner, true);
        xmetro.setRewardDistributor(address(distributor));

        metro.mint(user, 10 ether);
        vm.prank(user);
        metro.approve(address(xmetro), 10 ether);
        vm.prank(user);
        xmetro.stake(10 ether);
    }

    function test_Distribute_OnlyOperator() public {
        uint256 amount = 100 * 1e6;

        vm.prank(user);
        vm.expectRevert(bytes("RewardDistributor: only operator"));
        distributor.distribute(amount);

        usdc.mint(owner, amount);
        usdc.approve(address(distributor), amount);
        distributor.distribute(amount);
        assertEq(xmetro.accRewardPerShare(), 1e24 * amount / xmetro.totalShares());
    }

    function test_RescueTokens_OnlyOwner() public {
        usdc.mint(address(distributor), 1 * 1e6);

        vm.prank(user);
        vm.expectRevert();
        distributor.rescueTokens(address(usdc), user, 1);

        distributor.rescueTokens(address(usdc), user, 1 * 1e6);
        assertEq(usdc.balanceOf(user), 1 * 1e6);
    }

    function test_DistributeFromBalance_UserDepositsThenOperatorDistribute() public {
        uint256 amount = 100 * 1e6;

        usdc.mint(user, amount);
        vm.prank(user);
        usdc.transfer(address(distributor), amount);
        assertEq(usdc.balanceOf(address(distributor)), amount);

        distributor.distributeFromBalance(amount);

        assertEq(usdc.balanceOf(address(xmetro)), amount);
        assertEq(xmetro.accRewardPerShare(), 1e24 * amount / xmetro.totalShares());

        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_DistributeFromBalance_InsufficientBalance_Revert() public {
        uint256 amount = 1 * 1e6;

        vm.expectRevert(bytes("RewardDistributor: insufficient balance"));
        distributor.distributeFromBalance(amount);
    }
}
