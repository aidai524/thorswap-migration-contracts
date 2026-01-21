// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title xMETRO.fuzz.t.sol
 * @notice Fuzz tests for xMETRO key boundary behaviors.
 */

import "forge-std/Test.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { MetroTokenOFT } from "../../src/metro.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";
import { MockSwapAdapter } from "../mocks/MockSwapAdapter.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";

contract xMETROFuzzTest is Test {
    MockEndpointV2 internal endpoint;
    ERC20Mintable internal usdc; // rewardToken
    MetroTokenOFT internal metro; // METRO (mintable ERC20 in tests)
    xMETRO internal xmetro;

    address internal owner = address(this);
    address internal distributor;
    address internal operator;

    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal userC = makeAddr("userC");

    function setUp() public {
        endpoint = new MockEndpointV2();
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), owner);
        metro.setMinter(owner, true);

        xmetro = new xMETRO(owner, address(metro), address(usdc), address(0));
        metro.setMinter(address(xmetro), true);

        xmetro.setMigrationEscrow(owner);

        distributor = makeAddr("distributor");
        xmetro.setRewardDistributor(distributor);

        operator = makeAddr("operator");
        xmetro.setAutoCompoundOperator(operator, true);
    }

    function testFuzz_AutocompoundBatch_NoOverMint_AndClearsPendings(
        uint96 stakeA,
        uint96 stakeB,
        uint96 stakeC,
        uint64 rewards
    ) public {
        uint256 a = bound(uint256(stakeA), 1 ether, 100_000 ether);
        uint256 b = bound(uint256(stakeB), 1 ether, 100_000 ether);
        uint256 c = bound(uint256(stakeC), 1 ether, 100_000 ether);

        // rewardToken is 6 decimals (USDC-like).
        uint256 rewardAmount = bound(uint256(rewards), 1, 1_000_000_000_000);

        _stake(userA, a);
        _stake(userB, b);
        _stake(userC, c);

        _depositRewards(rewardAmount);

        MockSwapAdapter adapter = _setMockSwapAdapter(1e12, 1);

        vm.prank(userA);
        xmetro.enableAutocompound();
        vm.prank(userB);
        xmetro.enableAutocompound();
        vm.prank(userC);
        xmetro.enableAutocompound();

        // Use a de-duplicated list to compute the exact totalPending expected by `autocompoundBatch`.
        address[] memory unique = new address[](3);
        unique[0] = userA;
        unique[1] = userB;
        unique[2] = userC;
        (uint256 totalPending,) = xmetro.claimableMany(unique);
        vm.assume(totalPending > 0);

        uint256 minOut = totalPending * 1e12;
        metro.mint(address(adapter), minOut);

        // Intentionally include duplicate + zero address to cover edge inputs.
        address[] memory users = new address[](5);
        users[0] = userA;
        users[1] = userB;
        users[2] = userC;
        users[3] = userA;
        users[4] = address(0);

        uint256 supplyBefore = xmetro.totalSupply();
        uint256 metroBefore = metro.balanceOf(address(xmetro));
        uint256 usdcBefore = usdc.balanceOf(address(xmetro));

        vm.prank(operator);
        uint256 out = xmetro.autocompoundBatch(users, minOut, bytes(""));

        uint256 supplyAfter = xmetro.totalSupply();
        uint256 metroAfter = metro.balanceOf(address(xmetro));
        uint256 usdcAfter = usdc.balanceOf(address(xmetro));

        assertEq(out, minOut);
        assertEq(metroAfter - metroBefore, out);
        assertEq(usdcBefore - usdcAfter, totalPending);

        // Due to pro-rata floor division, total minted shares must never exceed received METRO.
        assertLe(supplyAfter - supplyBefore, out);

        // Due to reward debt rounding, claimable can be 0 or a tiny dust value.
        assertLe(xmetro.claimable(userA), 1);
        assertLe(xmetro.claimable(userB), 1);
        assertLe(xmetro.claimable(userC), 1);
    }

    function testFuzz_TransferAndTransferFrom_MoveRewardDebtWithShares(
        uint96 stakeA,
        uint96 stakeB,
        uint64 rewards,
        uint96 transferSeed0,
        uint96 transferSeed1
    ) public {
        uint256 a = bound(uint256(stakeA), 1 ether, 100_000 ether);
        uint256 b = bound(uint256(stakeB), 1 ether, 100_000 ether);
        uint256 rewardAmount = bound(uint256(rewards), 1, 1_000_000_000_000);

        _stake(userA, a);
        _stake(userB, b);
        _depositRewards(rewardAmount);

        uint256 totalBefore = xmetro.claimable(userA) + xmetro.claimable(userB);

        uint256 amt0 = bound(uint256(transferSeed0), 1, xmetro.balanceOf(userA));
        vm.prank(userA);
        xmetro.transfer(userB, amt0);

        uint256 totalAfter0 = xmetro.claimable(userA) + xmetro.claimable(userB);
        assertApproxEqAbs(totalAfter0, totalBefore, 1);

        uint256 balB = xmetro.balanceOf(userB);
        uint256 amt1 = bound(uint256(transferSeed1), 1, balB);
        vm.prank(userB);
        xmetro.approve(userC, amt1);
        vm.prank(userC);
        xmetro.transferFrom(userB, userA, amt1);

        uint256 totalAfter1 = xmetro.claimable(userA) + xmetro.claimable(userB);
        assertApproxEqAbs(totalAfter1, totalBefore, 1);
    }

    function testFuzz_WithdrawUnlockedYThor_RespectsMax(uint8 nSchedulesRaw, uint8 maxSchedulesRaw) public {
        uint256 nSchedules = bound(uint256(nSchedulesRaw), 1, 20);
        uint256 maxSchedules = bound(uint256(maxSchedulesRaw), 0, 20);

        uint256 amountPer = 1 ether;
        for (uint256 i = 0; i < nSchedules; i++) {
            xmetro.creditLockedVestingFromMigration(userA, amountPer);
        }

        uint256 startTime = block.timestamp + xmetro.YTHOR_CLIFF();
        uint256 duration = xmetro.YTHOR_DURATION();
        vm.warp(startTime + (duration / 2));

        uint256 maxEffective = maxSchedules == 0 ? xmetro.defaultMaxVestingSchedules() : maxSchedules;
        if (maxEffective > nSchedules) maxEffective = nSchedules;

        uint256 expected = maxEffective * (amountPer / 2);

        uint256 beforeBal = metro.balanceOf(userA);
        uint256 beforeLocked = xmetro.lockedShares(userA);

        vm.prank(userA);
        uint256 out = xmetro.withdrawUnlockedYThor(maxSchedules);

        assertEq(out, expected);
        assertEq(metro.balanceOf(userA) - beforeBal, out);
        assertEq(xmetro.lockedShares(userA), beforeLocked - out);
    }

    function testFuzz_WithdrawUnlockedContributor_RespectsMax(
        uint8 nSchedulesRaw,
        uint8 maxSchedulesRaw,
        uint96 amountPerRaw
    ) public {
        address contributor = makeAddr("contributor");

        uint256 nSchedules = bound(uint256(nSchedulesRaw), 1, 10);
        uint256 maxSchedules = bound(uint256(maxSchedulesRaw), 0, 10);
        uint256 amountPer = bound(uint256(amountPerRaw), 1 ether, 10 ether);

        xmetro.setContributor(contributor, true);

        uint256 total = nSchedules * amountPer;
        metro.mint(contributor, total);
        vm.prank(contributor);
        metro.approve(address(xmetro), total);

        for (uint256 i = 0; i < nSchedules; i++) {
            vm.prank(contributor);
            xmetro.stakeContributor(amountPer);
        }

        uint256 startTime = block.timestamp + xmetro.CONTRIBUTOR_CLIFF();
        uint256 duration = xmetro.CONTRIBUTOR_DURATION();
        vm.warp(startTime + (duration / 2));

        uint256 maxEffective = maxSchedules == 0 ? xmetro.defaultMaxVestingSchedules() : maxSchedules;
        if (maxEffective > nSchedules) maxEffective = nSchedules;

        uint256 expected = maxEffective * (amountPer / 2);

        uint256 beforeBal = metro.balanceOf(contributor);
        uint256 beforeLocked = xmetro.lockedShares(contributor);

        vm.prank(contributor);
        uint256 out = xmetro.withdrawUnlockedContributor(maxSchedules);

        assertEq(out, expected);
        assertEq(metro.balanceOf(contributor) - beforeBal, out);
        assertEq(xmetro.lockedShares(contributor), beforeLocked - out);
    }

    function testFuzz_Withdraw_RespectsMaxRequests(uint8 nReqRaw, uint8 maxReqRaw) public {
        uint256 nReq = bound(uint256(nReqRaw), 1, 20);
        uint256 maxReq = bound(uint256(maxReqRaw), 0, 20);

        uint256 amountPer = 1 ether;
        _stake(userA, nReq * amountPer);

        for (uint256 i = 0; i < nReq; i++) {
            vm.prank(userA);
            xmetro.requestUnstake(amountPer);
        }

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());

        uint256 maxEffective = maxReq == 0 ? nReq : maxReq;
        if (maxEffective > nReq) maxEffective = nReq;

        uint256 beforeBal = metro.balanceOf(userA);
        vm.prank(userA);
        uint256 out = xmetro.withdraw(maxReq);

        assertEq(out, maxEffective * amountPer);
        assertEq(metro.balanceOf(userA) - beforeBal, out);
        assertEq(xmetro.unstakeCursor(userA), maxEffective);
    }

    function testFuzz_ClaimableMany_DuplicatesAndZero_NoRevert(uint96 stakeA, uint96 stakeB, uint64 rewards) public {
        uint256 a = bound(uint256(stakeA), 1 ether, 100_000 ether);
        uint256 b = bound(uint256(stakeB), 1 ether, 100_000 ether);
        uint256 rewardAmount = bound(uint256(rewards), 1, 1_000_000_000_000);

        _stake(userA, a);
        _stake(userB, b);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(rewardAmount);

        address[] memory users = new address[](5);
        users[0] = userA;
        users[1] = userB;
        users[2] = userA; // duplicate
        users[3] = address(0);
        users[4] = userC; // zero shares

        (uint256 total,) = xmetro.claimableMany(users);

        assertEq(total, xmetro.claimable(userA) + xmetro.claimable(userB) + xmetro.claimable(userA));
    }

    function testFuzz_WithdrawUnlockedThor_RespectsMax(uint8 nLocksRaw, uint8 maxLocksRaw) public {
        uint256 nLocks = bound(uint256(nLocksRaw), 1, 20);
        uint256 maxLocks = bound(uint256(maxLocksRaw), 0, 20);

        uint256 amountPerLock = 1 ether;
        for (uint256 i = 0; i < nLocks; i++) {
            xmetro.creditLockedTHORFromMigration(userA, amountPerLock, 3);
        }

        vm.warp(block.timestamp + uint256(3) * xmetro.THOR_LOCK_MONTH_SECONDS() + 1);

        uint256 maxEffective = maxLocks == 0 ? xmetro.defaultMaxThorLocks() : maxLocks;
        if (maxEffective > nLocks) maxEffective = nLocks;

        uint256 beforeBal = metro.balanceOf(userA);
        uint256 beforeLocked = xmetro.lockedShares(userA);

        vm.prank(userA);
        uint256 out = xmetro.withdrawUnlockedThor(maxLocks);

        assertEq(out, maxEffective * amountPerLock);
        assertEq(metro.balanceOf(userA) - beforeBal, out);
        assertEq(xmetro.lockedShares(userA), beforeLocked - out);
        assertEq(xmetro.thorLockCursor3m(userA), maxEffective);
    }

    function _stake(address user, uint256 amount) internal {
        metro.mint(user, amount);
        vm.prank(user);
        metro.approve(address(xmetro), amount);
        vm.prank(user);
        xmetro.stake(amount);
    }

    function _depositRewards(uint256 amount) internal {
        usdc.mint(distributor, amount);
        vm.prank(distributor);
        usdc.approve(address(xmetro), amount);
        vm.prank(distributor);
        xmetro.depositRewards(amount);
    }

    function _setMockSwapAdapter(uint256 mul, uint256 div) internal returns (MockSwapAdapter adapter) {
        adapter = new MockSwapAdapter(address(usdc), address(metro), mul, div);
        adapter.setXMetro(address(xmetro));
        xmetro.setSwapAdapter(address(adapter));
    }
}
