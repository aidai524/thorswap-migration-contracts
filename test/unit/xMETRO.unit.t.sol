// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title xMETRO.unit.t.sol
 * @notice Unit tests for xMETRO local business logic (cross-chain is covered in mock tests).
 */

import "forge-std/Test.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { MetroTokenOFT } from "../../src/metro.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";
import { MockSwapAdapter } from "../mocks/MockSwapAdapter.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";

contract xMETROUnitTest is Test {
    MockEndpointV2 internal endpoint;
    ERC20Mintable internal usdc; // rewardToken
    MetroTokenOFT internal metro; // METRO (mintable ERC20 in tests)
    xMETRO internal xmetro;

    address internal owner = address(this);
    /// @dev Test rewardDistributor address (set via makeAddr in setUp).
    address internal distributor;
    address internal userA = address(0xA11CE);
    address internal userB = address(0xB0B);

    function setUp() public {
        vm.deal(userA, 100 ether);
        vm.deal(userB, 100 ether);

        endpoint = new MockEndpointV2();
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), owner);
        metro.setMinter(owner, true);

        xmetro = new xMETRO(owner, address(metro), address(usdc), address(0));
        metro.setMinter(address(xmetro), true);
        xmetro.setMigrationEscrow(owner);

        distributor = makeAddr("distributor");
    }

    function test_Stake_RevertZeroAmount() public {
        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: zero amount"));
        xmetro.stake(0);
    }

    function test_Stake_RevertWhenPaused() public {
        xmetro.pause();

        vm.prank(userA);
        vm.expectRevert();
        xmetro.stake(1 ether);
    }

    function test_Stake_MintsFreeShares_OneToOne() public {
        uint256 amount = 3 ether;

        metro.mint(userA, amount);
        vm.prank(userA);
        metro.approve(address(xmetro), amount);

        uint256 beforeMetro = metro.balanceOf(userA);
        uint256 beforeShares = xmetro.balanceOf(userA);
        uint256 beforeTotalShares = xmetro.totalShares();

        vm.prank(userA);
        uint256 mintedShares = xmetro.stake(amount);

        assertEq(mintedShares, amount);
        assertEq(xmetro.balanceOf(userA) - beforeShares, amount);
        assertEq(beforeMetro - metro.balanceOf(userA), amount);
        assertEq(xmetro.totalShares() - beforeTotalShares, amount);
    }

    function test_RequestUnstake_RevertZeroAmount() public {
        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: zero amount"));
        xmetro.requestUnstake(0);
    }

    function test_RequestUnstake_RevertWhenPaused() public {
        _stake(userA, 1 ether);
        xmetro.pause();

        vm.prank(userA);
        vm.expectRevert();
        xmetro.requestUnstake(1 ether);
    }

    function test_RequestUnstake_BurnsShares_AndPushesQueue() public {
        _stake(userA, 10 ether);

        uint256 beforeShares = xmetro.balanceOf(userA);
        vm.prank(userA);
        xmetro.requestUnstake(4 ether);

        assertEq(xmetro.balanceOf(userA), beforeShares - 4 ether);
        assertEq(xmetro.unstakeRequestCount(userA), 1);

        xMETRO.UnstakeRequest memory r = xmetro.unstakeRequest(userA, 0);
        assertEq(uint256(r.amount), 4 ether);
        assertEq(uint256(r.unlockTime), block.timestamp + xmetro.UNSTAKE_DELAY());
    }

    function test_RequestUnstake_DoesNotAutoUnlockVesting() public {
        xmetro.creditLockedVestingFromMigration(userA, 10 ether);

        vm.warp(block.timestamp + xmetro.YTHOR_CLIFF() + (xmetro.YTHOR_DURATION() / 2));

        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: insufficient free"));
        xmetro.requestUnstake(1 ether);
    }

    function test_Withdraw_MaxRequests_BatchProcessing() public {
        _stake(userA, 10 ether);

        vm.prank(userA);
        xmetro.requestUnstake(2 ether);
        vm.prank(userA);
        xmetro.requestUnstake(3 ether);
        vm.prank(userA);
        xmetro.requestUnstake(5 ether);

        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: nothing to withdraw"));
        xmetro.withdraw(0);

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());

        uint256 before = metro.balanceOf(userA);
        vm.prank(userA);
        uint256 out1 = xmetro.withdraw(2);
        uint256 mid = metro.balanceOf(userA);

        assertEq(out1, 5 ether);
        assertEq(mid - before, 5 ether);

        vm.prank(userA);
        uint256 out2 = xmetro.withdraw(2);
        uint256 afterBal = metro.balanceOf(userA);

        assertEq(out2, 5 ether);
        assertEq(afterBal - mid, 5 ether);
    }

    function test_Withdraw_MaxRequestsZero_ProcessAllAndThenReturnZero() public {
        _stake(userA, 6 ether);

        vm.prank(userA);
        xmetro.requestUnstake(1 ether);
        vm.prank(userA);
        xmetro.requestUnstake(2 ether);
        vm.prank(userA);
        xmetro.requestUnstake(3 ether);

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());

        uint256 beforeBal = metro.balanceOf(userA);
        vm.prank(userA);
        uint256 out = xmetro.withdraw(0);
        uint256 afterBal = metro.balanceOf(userA);

        assertEq(out, 6 ether);
        assertEq(afterBal - beforeBal, 6 ether);

        vm.prank(userA);
        uint256 out2 = xmetro.withdraw(0);
        assertEq(out2, 0);
    }

    function test_Withdraw_StopAtFirstUnmaturedRequest() public {
        _stake(userA, 3 ether);

        vm.prank(userA);
        xmetro.requestUnstake(1 ether);
        uint256 unlock0 = block.timestamp + xmetro.UNSTAKE_DELAY();

        vm.warp(block.timestamp + (xmetro.UNSTAKE_DELAY() / 2));
        vm.prank(userA);
        xmetro.requestUnstake(2 ether);
        uint256 unlock1 = block.timestamp + xmetro.UNSTAKE_DELAY();

        assertGt(unlock1, unlock0);

        vm.warp(unlock0 + 1);
        assertLt(block.timestamp, unlock1);

        uint256 beforeBal = metro.balanceOf(userA);
        vm.prank(userA);
        uint256 out = xmetro.withdraw(0);
        uint256 afterBal = metro.balanceOf(userA);

        assertEq(out, 1 ether);
        assertEq(afterBal - beforeBal, 1 ether);
    }

    function test_DepositRewards_OnlyDistributor() public {
        xmetro.setRewardDistributor(distributor);

        usdc.mint(userA, 1e6);
        vm.prank(userA);
        usdc.approve(address(xmetro), 1e6);

        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: only distributor"));
        xmetro.depositRewards(1e6);
    }

    function test_DepositRewards_RevertWhenNoShares() public {
        xmetro.setRewardDistributor(distributor);

        usdc.mint(distributor, 1e6);
        vm.prank(distributor);
        usdc.approve(address(xmetro), 1e6);

        vm.prank(distributor);
        vm.expectRevert(bytes("xMETRO: no shares"));
        xmetro.depositRewards(1e6);
    }

    function test_DepositRewards_RevertWhenPaused() public {
        _stake(userA, 1 ether);

        xmetro.setRewardDistributor(distributor);
        xmetro.pause();

        usdc.mint(distributor, 1e6);
        vm.prank(distributor);
        usdc.approve(address(xmetro), 1e6);

        vm.prank(distributor);
        vm.expectRevert();
        xmetro.depositRewards(1e6);
    }

    function test_ClaimRewards_RevertWhenPaused() public {
        _stake(userA, 1 ether);
        xmetro.setRewardDistributor(distributor);
        _depositRewards(1e6);

        xmetro.pause();
        vm.prank(userA);
        vm.expectRevert();
        xmetro.claimRewards();
    }

    function test_ClaimableMany_SumsAndMatchesPerUser() public {
        _stake(userA, 1 ether);
        _stake(userB, 3 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        (uint256 totalPending, uint256[] memory pendings) = xmetro.claimableMany(users);

        uint256 pendingA = xmetro.claimable(userA);
        uint256 pendingB = xmetro.claimable(userB);

        assertEq(totalPending, pendingA + pendingB);
        assertEq(pendings.length, users.length);
        assertEq(pendings[0], pendingA);
        assertEq(pendings[1], pendingB);
        assertEq(totalPending, 100 * 1e6);
        assertEq(pendingA, 25 * 1e6);
        assertEq(pendingB, 75 * 1e6);
    }

    function test_Rewards_LockedSharesParticipate_InClaimableAndClaim() public {
        xmetro.creditLockedVestingFromMigration(userA, 10 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);

        assertEq(xmetro.claimable(userA), 100 * 1e6);

        uint256 beforeBal = usdc.balanceOf(userA);
        vm.prank(userA);
        uint256 paid = xmetro.claimRewards();
        uint256 afterBal = usdc.balanceOf(userA);

        assertEq(paid, 100 * 1e6);
        assertEq(afterBal - beforeBal, 100 * 1e6);
        assertEq(xmetro.claimable(userA), 0);
    }

    function test_Autocompound_SelfCompounds() public {
        _stake(userA, 1 ether);

        xmetro.setRewardDistributor(distributor);
        uint256 rewards = 5 * 1e6;
        _depositRewards(rewards);

        MockSwapAdapter adapter = _setMockSwapAdapter(1e12, 1);
        uint256 minOut = rewards * 1e12;
        metro.mint(address(adapter), minOut);

        uint256 beforeUser = xmetro.balanceOf(userA);

        vm.prank(userA);
        uint256 out = xmetro.autocompound(minOut, bytes(""));

        assertEq(out, minOut);
        assertEq(xmetro.balanceOf(userA) - beforeUser, minOut);
        assertEq(xmetro.claimable(userA), 0);
    }

    function test_WithdrawUnlockedYThor_MaxSchedules_LimitsOneRound() public {
        _stake(userA, 1 ether);

        for (uint256 i = 0; i < 5; i++) {
            xmetro.creditLockedVestingFromMigration(userA, 1 ether);
        }
        assertEq(xmetro.yThorVestingCount(userA), 5);

        vm.warp(block.timestamp + xmetro.YTHOR_CLIFF() + (xmetro.YTHOR_DURATION() / 2));

        uint256 beforeMetro = metro.balanceOf(userA);
        vm.prank(userA);
        uint256 unlocked = xmetro.withdrawUnlockedYThor(2);
        uint256 afterMetro = metro.balanceOf(userA);

        assertEq(afterMetro - beforeMetro, unlocked);
        assertGt(unlocked, 0);

        vm.prank(userA);
        uint256 unlocked2 = xmetro.withdrawUnlockedYThor(2);
        assertGt(unlocked2, 0);
    }

    function test_WithdrawUnlockedYThor_DoesNotChangePendingRewards() public {
        xmetro.creditLockedVestingFromMigration(userA, 10 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);

        uint256 pendingBefore = xmetro.claimable(userA);

        vm.warp(block.timestamp + xmetro.YTHOR_CLIFF() + (xmetro.YTHOR_DURATION() / 2));

        uint256 lockedBefore = xmetro.lockedShares(userA);

        vm.prank(userA);
        uint256 unlocked = xmetro.withdrawUnlockedYThor(12);

        assertEq(xmetro.lockedShares(userA), lockedBefore - unlocked);

        uint256 pendingAfter = xmetro.claimable(userA);
        assertApproxEqAbs(pendingAfter, pendingBefore, 1);
    }

    function test_DefaultMaxThorLocks_SetterAndBatchWithdrawUnlocked() public {
        for (uint256 i = 0; i < 5; i++) {
            xmetro.creditLockedTHORFromMigration(userA, 1 ether, 3);
        }
        assertEq(xmetro.thorLocks3mCount(userA), 5);

        vm.expectRevert(bytes("xMETRO: zero max"));
        xmetro.setDefaultMaxThorLocks(0);

        xmetro.setDefaultMaxThorLocks(2);

        vm.warp(block.timestamp + (3 * xmetro.THOR_LOCK_MONTH_SECONDS()) + 1);

        vm.prank(userA);
        uint256 u1 = xmetro.withdrawUnlockedThor(0);
        assertEq(u1, 2 ether);
        assertEq(xmetro.thorLockCursor3m(userA), 2);

        vm.prank(userA);
        uint256 u2 = xmetro.withdrawUnlockedThor(0);
        assertEq(u2, 2 ether);
        assertEq(xmetro.thorLockCursor3m(userA), 4);

        vm.prank(userA);
        uint256 u3 = xmetro.withdrawUnlockedThor(0);
        assertEq(u3, 1 ether);
        assertEq(xmetro.thorLockCursor3m(userA), 5);
    }

    function test_RequestUnstake_DoesNotForfeitEarnedRewards() public {
        _stake(userA, 100 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);
        uint256 pendingBefore = xmetro.claimable(userA);

        vm.prank(userA);
        xmetro.requestUnstake(50 ether);

        uint256 pendingAfter = xmetro.claimable(userA);
        assertEq(pendingAfter, pendingBefore);

        _depositRewards(100 * 1e6);
        uint256 pendingAfter2 = xmetro.claimable(userA);
        assertEq(pendingAfter2, pendingBefore + 100 * 1e6);
    }

    function test_Vesting_LinearRelease_ExactMilestones_AndIncrementalClaimed() public {
        uint256 totalAmount = 40 ether;
        uint256 t0 = block.timestamp;

        xmetro.creditLockedVestingFromMigration(userA, totalAmount);

        uint256 startTime = t0 + xmetro.YTHOR_CLIFF();
        uint256 duration = xmetro.YTHOR_DURATION();
        uint256 endTime = startTime + duration;

        vm.warp(startTime - 1);
        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: nothing unlocked"));
        xmetro.withdrawUnlockedYThor(1);
        assertEq(metro.balanceOf(userA), 0);
        assertEq(xmetro.lockedShares(userA), totalAmount);

        vm.warp(startTime + (duration / 4));
        vm.prank(userA);
        uint256 u1 = xmetro.withdrawUnlockedYThor(1);
        assertEq(u1, totalAmount / 4);
        assertEq(metro.balanceOf(userA), totalAmount / 4);
        assertEq(xmetro.lockedShares(userA), totalAmount - (totalAmount / 4));

        xMETRO.VestingSchedule memory s1 = xmetro.yThorVesting(userA, 0);
        assertEq(uint256(s1.claimed), totalAmount / 4);

        vm.warp(startTime + (duration / 2));
        vm.prank(userA);
        uint256 u2 = xmetro.withdrawUnlockedYThor(1);
        assertEq(u2, totalAmount / 4);
        assertEq(metro.balanceOf(userA), totalAmount / 2);
        assertEq(xmetro.lockedShares(userA), totalAmount / 2);

        xMETRO.VestingSchedule memory s2 = xmetro.yThorVesting(userA, 0);
        assertEq(uint256(s2.claimed), totalAmount / 2);

        vm.warp(endTime);
        vm.prank(userA);
        uint256 u3 = xmetro.withdrawUnlockedYThor(1);
        assertEq(u3, totalAmount / 2);
        assertEq(metro.balanceOf(userA), totalAmount);
        assertEq(xmetro.lockedShares(userA), 0);

        xMETRO.VestingSchedule memory s3 = xmetro.yThorVesting(userA, 0);
        assertEq(uint256(s3.claimed), totalAmount);

        vm.warp(endTime + 1000);
        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: nothing unlocked"));
        xmetro.withdrawUnlockedYThor(1);
    }

    function test_AutocompoundBatch_OnlyOperator() public {
        _stake(userA, 1 ether);
        _stake(userB, 3 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);

        MockSwapAdapter adapter = _setMockSwapAdapter(1e12, 1);
        uint256 totalPending = 100 * 1e6;
        uint256 minOut = totalPending * 1e12;
        metro.mint(address(adapter), minOut);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        vm.prank(userA);
        xmetro.enableAutocompound();
        vm.prank(userB);
        xmetro.enableAutocompound();

        vm.prank(userA);
        vm.expectRevert(bytes("xMETRO: only autocompound operator"));
        xmetro.autocompoundBatch(users, minOut, bytes(""));
    }

    function test_AutocompoundBatch_DistributesProRataByPending() public {
        _stake(userA, 1 ether);
        _stake(userB, 3 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);

        MockSwapAdapter adapter = _setMockSwapAdapter(1e12, 1);
        uint256 totalPending = 100 * 1e6;
        uint256 minOut = totalPending * 1e12;
        metro.mint(address(adapter), minOut);

        address operator = makeAddr("operator");
        xmetro.setAutoCompoundOperator(operator, true);

        vm.prank(userA);
        xmetro.enableAutocompound();
        vm.prank(userB);
        xmetro.enableAutocompound();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        uint256 beforeA = xmetro.balanceOf(userA);
        uint256 beforeB = xmetro.balanceOf(userB);

        vm.prank(operator);
        uint256 out = xmetro.autocompoundBatch(users, minOut, bytes(""));

        assertEq(out, minOut);
        assertEq(xmetro.balanceOf(userA) - beforeA, 25 ether);
        assertEq(xmetro.balanceOf(userB) - beforeB, 75 ether);
        assertEq(xmetro.claimable(userA), 0);
        assertEq(xmetro.claimable(userB), 0);
    }

    function test_AutocompoundBatch_RoundingRemainder_StaysInContract() public {
        _stake(userA, 1 ether);
        _stake(userB, 2 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(3);

        MockSwapAdapter adapter = _setMockSwapAdapter(10, 3);
        metro.mint(address(adapter), 10);

        address operator = makeAddr("operator");
        xmetro.setAutoCompoundOperator(operator, true);

        vm.prank(userA);
        xmetro.enableAutocompound();
        vm.prank(userB);
        xmetro.enableAutocompound();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        uint256 beforeA = xmetro.balanceOf(userA);
        uint256 beforeB = xmetro.balanceOf(userB);
        uint256 supplyBefore = xmetro.totalSupply();
        uint256 metroBefore = metro.balanceOf(address(xmetro));

        vm.prank(operator);
        uint256 out = xmetro.autocompoundBatch(users, 10, bytes(""));

        assertEq(out, 10);

        assertEq(xmetro.balanceOf(userA) - beforeA, 3);
        assertEq(xmetro.balanceOf(userB) - beforeB, 6);
        assertEq(xmetro.totalSupply() - supplyBefore, 9);
        assertEq(metro.balanceOf(address(xmetro)) - metroBefore, 10);
    }

    function test_AutocompoundBatch_SkipsDisabledUsers() public {
        _stake(userA, 1 ether);
        _stake(userB, 3 ether);

        xmetro.setRewardDistributor(distributor);
        _depositRewards(100 * 1e6);

        MockSwapAdapter adapter = _setMockSwapAdapter(1e12, 1);
        uint256 pendingA = xmetro.claimable(userA);
        uint256 pendingB = xmetro.claimable(userB);
        uint256 minOut = pendingA * 1e12;
        metro.mint(address(adapter), minOut);

        address operator = makeAddr("operator");
        xmetro.setAutoCompoundOperator(operator, true);

        vm.prank(userA);
        xmetro.enableAutocompound();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        uint256 beforeA = xmetro.balanceOf(userA);
        uint256 beforeB = xmetro.balanceOf(userB);

        vm.prank(operator);
        uint256 out = xmetro.autocompoundBatch(users, minOut, bytes(""));

        assertEq(out, minOut);
        assertEq(xmetro.balanceOf(userA) - beforeA, 25 ether);
        assertEq(xmetro.balanceOf(userB), beforeB);
        assertEq(xmetro.claimable(userA), 0);
        assertEq(xmetro.claimable(userB), pendingB);
    }

    function test_Contributor_WhitelistAndWithdraw() public {
        address contributor = makeAddr("contributor");

        metro.mint(contributor, 40 ether);
        vm.prank(contributor);
        metro.approve(address(xmetro), 40 ether);

        vm.prank(contributor);
        vm.expectRevert(bytes("xMETRO: not contributor"));
        xmetro.stakeContributor(40 ether);

        xmetro.setContributor(contributor, true);

        uint256 t0 = block.timestamp;
        vm.prank(contributor);
        xmetro.stakeContributor(40 ether);

        assertEq(xmetro.contributorVestingCount(contributor), 1);
        xMETRO.VestingSchedule memory s0 = xmetro.contributorVesting(contributor, 0);
        assertEq(uint256(s0.totalAmount), 40 ether);
        assertEq(uint256(s0.claimed), 0);
        assertEq(uint256(s0.startTime), t0 + xmetro.CONTRIBUTOR_CLIFF());
        assertEq(uint256(s0.duration), xmetro.CONTRIBUTOR_DURATION());
        assertEq(xmetro.lockedShares(contributor), 40 ether);

        vm.warp(uint256(s0.startTime) + (uint256(s0.duration) / 2));

        uint256 beforeMetro = metro.balanceOf(contributor);
        vm.prank(contributor);
        uint256 unlocked = xmetro.withdrawUnlockedContributor(1);
        uint256 afterMetro = metro.balanceOf(contributor);

        assertEq(unlocked, 20 ether);
        assertEq(afterMetro - beforeMetro, 20 ether);
        assertEq(xmetro.lockedShares(contributor), 20 ether);
        xMETRO.VestingSchedule memory s1 = xmetro.contributorVesting(contributor, 0);
        assertEq(uint256(s1.claimed), 20 ether);
    }

    function _stake(address user, uint256 amount) internal {
        metro.mint(user, amount);
        vm.prank(user);
        metro.approve(address(xmetro), amount);
        vm.prank(user);
        xmetro.stake(amount);
    }

    function _setMockSwapAdapter(uint256 mul, uint256 div) internal returns (MockSwapAdapter adapter) {
        adapter = new MockSwapAdapter(address(usdc), address(metro), mul, div);
        adapter.setXMetro(address(xmetro));
        xmetro.setSwapAdapter(address(adapter));
    }

    function _depositRewards(uint256 amount) internal {
        usdc.mint(distributor, amount);
        vm.prank(distributor);
        usdc.approve(address(xmetro), amount);
        vm.prank(distributor);
        xmetro.depositRewards(amount);
    }
}
