// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ThorMigrationEscrow.unit.t.sol
 * @notice Unit tests for same-chain ThorMigrationEscrow (schedule selection + migration calls).
 */

import "forge-std/Test.sol";

import { ThorMigrationEscrow } from "../../src/ThorMigrationEscrow.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";

contract MockXMetroMigration {
    address public lastThorUser;
    uint256 public lastThorAmount;
    uint256 public lastThorLockMonths;

    address public lastVestingUser;
    uint256 public lastVestingAmount;

    function creditLockedTHORFromMigration(address user, uint256 amount, uint256 lockMonths) external {
        lastThorUser = user;
        lastThorAmount = amount;
        lastThorLockMonths = lockMonths;
    }

    function creditLockedVestingFromMigration(address user, uint256 amount) external {
        lastVestingUser = user;
        lastVestingAmount = amount;
    }
}

contract ThorMigrationEscrowUnitTest is Test {
    ERC20Mintable internal thor;
    ERC20Mintable internal ythor;
    MockXMetroMigration internal xmetro;
    ThorMigrationEscrow internal escrow;

    address internal owner = address(this);
    address internal user = makeAddr("user");

    function setUp() public {
        thor = new ERC20Mintable("THOR", "THOR", 18);
        ythor = new ERC20Mintable("yTHOR", "yTHOR", 18);
        xmetro = new MockXMetroMigration();

        escrow = new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(ythor), block.timestamp);

        escrow.setCaps(50_000_000 ether, 50_000_000 ether);
        escrow.setRatios(1_200_000_000_000_000_000, 1_000_000_000_000_000_000, 1_000_000_000_000_000_000);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        escrow.setYThorLimits(50_000_000 ether, block.timestamp + 365 days);
    }

    function test_SetRatios_BadRatio_Revert() public {
        vm.expectRevert(bytes("ThorEscrow: bad ratio"));
        escrow.setRatios(0, 1e18, 1e18);
    }

    function test_SetRatios_OnlyOwner_AndEmits() public {
        vm.prank(user);
        vm.expectRevert();
        escrow.setRatios(2e18, 1e18, 1e18);

        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.RatiosUpdated(2e18, 1e18, 3e18);
        escrow.setRatios(2e18, 1e18, 3e18);
        assertEq(escrow.ratio10M(), 2e18);
        assertEq(escrow.ratio3M(), 1e18);
        assertEq(escrow.ratioYThor(), 3e18);
    }

    function test_SetDeadlines_OnlyOwner_AndEmits() public {
        uint256 deadline10M = block.timestamp + 11;
        uint256 deadline3M = block.timestamp + 22;

        vm.prank(user);
        vm.expectRevert();
        escrow.setDeadlines(deadline10M, deadline3M);

        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.DeadlinesUpdated(deadline10M, deadline3M);
        escrow.setDeadlines(deadline10M, deadline3M);
        assertEq(escrow.deadline10M(), deadline10M);
        assertEq(escrow.deadline3M(), deadline3M);
    }

    function test_SetMigrationStartTime_OnlyOwner() public {
        uint256 startTimeA = block.timestamp + 123;
        uint256 startTimeB = block.timestamp + 456;

        vm.prank(user);
        vm.expectRevert();
        escrow.setMigrationStartTime(startTimeA);

        escrow.setMigrationStartTime(startTimeB);
        assertEq(escrow.migrationStartTime(), startTimeB);
    }

    function test_SetYThorLimits_OnlyOwner_AndEmits() public {
        uint256 deadlineA = block.timestamp + 123;
        uint256 deadlineB = block.timestamp + 456;

        vm.prank(user);
        vm.expectRevert();
        escrow.setYThorLimits(1 ether, deadlineA);

        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.YThorLimitsUpdated(2 ether, deadlineB);
        escrow.setYThorLimits(2 ether, deadlineB);
        assertEq(escrow.capYThor(), 2 ether);
        assertEq(escrow.deadlineYThor(), deadlineB);
    }

    function test_MigrateYThor_CapNotSet_Revert() public {
        ThorMigrationEscrow e = new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(ythor), block.timestamp);
        e.setRatios(1e18, 1e18, 1e18);
        e.setCaps(1 ether, 1 ether);
        e.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);

        ythor.mint(user, 1 ether);
        vm.prank(user);
        ythor.approve(address(e), 1 ether);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: ythor cap not set"));
        e.migrateYThor(1 ether);
    }

    function test_MigrateYThor_Expired_Revert() public {
        escrow.setYThorLimits(50_000_000 ether, block.timestamp);
        vm.warp(block.timestamp + 1);

        ythor.mint(user, 1 ether);
        vm.prank(user);
        ythor.approve(address(escrow), 1 ether);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: ythor expired"));
        escrow.migrateYThor(1 ether);
    }

    function test_MigrateYThor_CapExceeded_Revert() public {
        escrow.setYThorLimits(1 ether, block.timestamp + 365 days);

        uint256 amountIn = 2 ether; // ratioYThor = 1e18 => mintAmount = 2 ether > cap
        ythor.mint(user, amountIn);
        vm.prank(user);
        ythor.approve(address(escrow), amountIn);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: ythor cap"));
        escrow.migrateYThor(amountIn);
    }

    function test_Pause_Unpause_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        escrow.pause();

        escrow.pause();
        assertTrue(escrow.paused());

        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function test_Migrate_NotStarted_RevertEarly() public {
        escrow.setMigrationStartTime(block.timestamp + 1 days);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: not started"));
        escrow.migrateYThor(1 ether);
    }

    function test_Migrate_ZeroAmount_Revert() public {
        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: zero amount"));
        escrow.migrateThor10m(0);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: zero amount"));
        escrow.migrateThor3m(0);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: zero amount"));
        escrow.migrateYThor(0);
    }

    function test_MigrateThor_Success_TransfersToken_AndCallsXmetro() public {
        escrow.setMigrationStartTime(block.timestamp);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);

        uint256 amountIn = 10 ether;
        thor.mint(user, amountIn);
        vm.prank(user);
        thor.approve(address(escrow), amountIn);

        uint256 expectedMint = (amountIn * escrow.ratio10M()) / 1e18;

        vm.prank(user);
        escrow.migrateThor10m(amountIn);

        assertEq(thor.balanceOf(address(escrow)), amountIn);
        assertEq(escrow.minted10M(), expectedMint);

        assertEq(xmetro.lastThorUser(), user);
        assertEq(xmetro.lastThorAmount(), expectedMint);
        assertEq(xmetro.lastThorLockMonths(), 10);
    }

    function test_MigrateThor10m_RevertThenMigrateThor3m_When10mCapExceeded() public {
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);

        // Make 10m path always exceed cap due to a huge ratio.
        escrow.setRatios(escrow.cap10M() + 1, escrow.ratio3M(), escrow.ratioYThor());

        uint256 amountIn = 1 ether;
        thor.mint(user, amountIn);
        vm.prank(user);
        thor.approve(address(escrow), amountIn);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: 10m cap"));
        escrow.migrateThor10m(amountIn);

        vm.prank(user);
        escrow.migrateThor3m(amountIn);

        assertEq(xmetro.lastThorLockMonths(), 3);
    }

    function test_MigrateThor3m_RevertWhen10mAvailable() public {
        escrow.setMigrationStartTime(block.timestamp);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);

        uint256 amountIn = 1 ether;
        thor.mint(user, amountIn);
        vm.prank(user);
        thor.approve(address(escrow), amountIn);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: 10m available"));
        escrow.migrateThor3m(amountIn);
    }

    function test_MigrateYThor_Success_TransfersToken_AndCallsXmetro() public {
        escrow.setMigrationStartTime(block.timestamp);

        uint256 amountIn = 5 ether;
        ythor.mint(user, amountIn);
        vm.prank(user);
        ythor.approve(address(escrow), amountIn);

        uint256 expectedMint = (amountIn * escrow.ratioYThor()) / 1e18;

        vm.prank(user);
        escrow.migrateYThor(amountIn);

        assertEq(ythor.balanceOf(address(escrow)), amountIn);
        assertEq(xmetro.lastVestingUser(), user);
        assertEq(xmetro.lastVestingAmount(), expectedMint);
    }

    function test_MigrateYThor_ZeroMint_Revert() public {
        escrow.setMigrationStartTime(block.timestamp);
        escrow.setRatios(escrow.ratio10M(), escrow.ratio3M(), 1);

        ythor.mint(user, 1);
        vm.prank(user);
        ythor.approve(address(escrow), 1);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: zero mint"));
        escrow.migrateYThor(1);
    }

    function test_RescueTokens_OnlyOwner_AndBadToRevert() public {
        ERC20Mintable other = new ERC20Mintable("OTHER", "OTHER", 18);
        other.mint(address(escrow), 123);

        vm.prank(user);
        vm.expectRevert();
        escrow.rescueTokens(address(other), user, 1);

        vm.expectRevert(bytes("ThorEscrow: cannot rescue migration tokens"));
        escrow.rescueTokens(address(thor), user, 1);

        vm.expectRevert(bytes("ThorEscrow: cannot rescue migration tokens"));
        escrow.rescueTokens(address(ythor), user, 1);

        vm.expectRevert(bytes("ThorEscrow: bad to"));
        escrow.rescueTokens(address(other), address(0), 1);

        vm.expectEmit(true, true, false, true);
        emit ThorMigrationEscrow.TokensRescued(address(other), user, 23);
        escrow.rescueTokens(address(other), user, 23);
        assertEq(other.balanceOf(user), 23);
    }
}
