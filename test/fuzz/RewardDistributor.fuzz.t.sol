// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { RewardDistributor } from "../../src/RewardDistributor.sol";
import { xMETRO } from "../../src/xMETRO.sol";
import { MetroTokenOFT } from "../../src/metro.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";

contract RewardDistributorFuzzTest is Test {
    MockEndpointV2 internal endpoint;
    ERC20Mintable internal usdc;
    MetroTokenOFT internal metro;
    xMETRO internal xmetro;
    RewardDistributor internal distributor;

    address internal owner = address(this);
    address internal operator = makeAddr("operator");
    address internal user = makeAddr("user");

    function setUp() public {
        endpoint = new MockEndpointV2();
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), owner);

        metro.setMinter(owner, true);

        xmetro = new xMETRO(owner, address(metro), address(usdc), address(0));
        metro.setMinter(address(xmetro), true);

        distributor = new RewardDistributor(address(xmetro), address(usdc), owner);
        distributor.setOperator(operator, true);
        xmetro.setRewardDistributor(address(distributor));

        // Ensure totalShares() > 0 so depositRewards can work.
        metro.mint(user, 10 ether);
        vm.prank(user);
        metro.approve(address(xmetro), 10 ether);
        vm.prank(user);
        xmetro.stake(10 ether);
    }

    function testFuzz_Distribute_Success_AllowanceReset(uint256 amount) public {
        amount = bound(amount, 1, 1e18);

        uint256 beforeAcc = xmetro.accRewardPerShare();
        uint256 totalShares = xmetro.totalShares();

        usdc.mint(operator, amount);
        vm.prank(operator);
        usdc.approve(address(distributor), amount);

        vm.prank(operator);
        distributor.distribute(amount);

        uint256 expectedDelta = (amount * 1e24) / totalShares;
        assertEq(xmetro.accRewardPerShare(), beforeAcc + expectedDelta);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
    }

    function testFuzz_DistributeFromBalance_Success_AllowanceReset(uint256 amount) public {
        amount = bound(amount, 1, 1e18);

        uint256 beforeAcc = xmetro.accRewardPerShare();
        uint256 totalShares = xmetro.totalShares();

        usdc.mint(user, amount);
        vm.prank(user);
        usdc.transfer(address(distributor), amount);

        vm.prank(operator);
        distributor.distributeFromBalance(amount);

        uint256 expectedDelta = (amount * 1e24) / totalShares;
        assertEq(xmetro.accRewardPerShare(), beforeAcc + expectedDelta);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_SetOperator_RejectsZero() public {
        vm.expectRevert(bytes("RewardDistributor: bad operator"));
        distributor.setOperator(address(0), true);
    }

    function testFuzz_SetOperator_Toggles(address op, bool allowed) public {
        vm.assume(op != address(0));
        distributor.setOperator(op, allowed);
        assertEq(distributor.operators(op), allowed);
    }
}
