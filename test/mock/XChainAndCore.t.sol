// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title XChainAndCore.t.sol
 * @notice Integration test suite for same-chain migration + xMETRO core logic.
 * @dev Kept under the original filename to avoid churn; cross-chain messaging is removed.
 */

import "forge-std/Test.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { ThorMigrationEscrow } from "../../src/ThorMigrationEscrow.sol";
import { RewardDistributor } from "../../src/RewardDistributor.sol";
import { MetroTokenOFT } from "../../src/metro.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";
import { MockSwapAdapter } from "../mocks/MockSwapAdapter.sol";

contract XChainAndCoreTest is Test {
    // Contracts
    xMETRO internal xmetro;
    ThorMigrationEscrow internal escrow;
    RewardDistributor internal distributor;
    MockSwapAdapter internal mockAdapter;
    MetroTokenOFT internal metro;

    // Tokens (test)
    ERC20Mintable internal usdc; // 6 decimals
    ERC20Mintable internal thor; // 18 decimals
    ERC20Mintable internal ythor; // 18 decimals

    // Test accounts
    address internal userA = address(0xA11CE);
    address internal userB = address(0xB0B);

    function setUp() public {
        vm.deal(userA, 100 ether);
        vm.deal(userB, 100 ether);

        usdc = new ERC20Mintable("USDC", "USDC", 6);
        thor = new ERC20Mintable("THOR", "THOR", 18);
        ythor = new ERC20Mintable("yTHOR", "yTHOR", 18);

        MockEndpointV2 endpoint = new MockEndpointV2();

        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), address(this));
        metro.setMinter(address(this), true);

        xmetro = new xMETRO(address(this), address(metro), address(usdc), address(0));
        metro.setMinter(address(xmetro), true);

        mockAdapter = new MockSwapAdapter(address(usdc), address(metro), 1e12, 1);
        mockAdapter.setXMetro(address(xmetro));
        xmetro.setSwapAdapter(address(mockAdapter));

        distributor = new RewardDistributor(address(xmetro), address(usdc), address(this));
        distributor.setOperator(address(this), true);
        xmetro.setRewardDistributor(address(distributor));

        escrow = new ThorMigrationEscrow(address(this), address(xmetro), address(thor), address(ythor), block.timestamp);
        escrow.setCaps(50_000_000 ether, 50_000_000 ether);
        escrow.setRatios(1_200_000_000_000_000_000, 1_000_000_000_000_000_000, 1_000_000_000_000_000_000);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        escrow.setYThorLimits(50_000_000 ether, block.timestamp + 365 days);

        xmetro.setMigrationEscrow(address(escrow));
    }

    function test_MigrateThor_Success_CreditsLockedShares() public {
        uint256 amountIn = 10 ether;

        thor.mint(userA, amountIn);
        vm.prank(userA);
        thor.approve(address(escrow), amountIn);

        uint256 expectedMint = (amountIn * escrow.ratio10M()) / 1e18;

        vm.prank(userA);
        escrow.migrateThor10m(amountIn);

        assertEq(thor.balanceOf(address(escrow)), amountIn);
        assertEq(metro.balanceOf(address(xmetro)), expectedMint);

        assertEq(xmetro.lockedShares(userA), expectedMint);
        assertEq(xmetro.totalLockedShares(), expectedMint);

        assertEq(xmetro.thorLocks10mCount(userA), 1);
        xMETRO.ThorLock memory l = xmetro.thorLock10m(userA, 0);
        assertEq(uint256(l.amount), expectedMint);
        assertGt(uint256(l.endTime), block.timestamp);
    }

    function test_MigrateYThor_Success_VestingRecorded() public {
        uint256 amountIn = 5 ether;

        ythor.mint(userA, amountIn);
        vm.prank(userA);
        ythor.approve(address(escrow), amountIn);

        uint256 expectedMint = (amountIn * escrow.ratioYThor()) / 1e18;
        uint256 ts = block.timestamp;

        vm.prank(userA);
        escrow.migrateYThor(amountIn);

        assertEq(ythor.balanceOf(address(escrow)), amountIn);
        assertEq(metro.balanceOf(address(xmetro)), expectedMint);

        assertEq(xmetro.yThorVestingCount(userA), 1);
        xMETRO.VestingSchedule memory s = xmetro.yThorVesting(userA, 0);
        assertEq(uint256(s.totalAmount), expectedMint);
        assertEq(uint256(s.claimed), 0);
        assertEq(uint256(s.startTime), ts + xmetro.YTHOR_CLIFF());
        assertEq(uint256(s.duration), xmetro.YTHOR_DURATION());
    }

    function test_MigrateThor_RevertWhenXmetroPaused_NoFundsStuck() public {
        xmetro.pause();

        uint256 amountIn = 1 ether;
        thor.mint(userA, amountIn);
        vm.prank(userA);
        thor.approve(address(escrow), amountIn);

        vm.prank(userA);
        vm.expectRevert();
        escrow.migrateThor10m(amountIn);

        assertEq(thor.balanceOf(address(escrow)), 0);
    }
}
