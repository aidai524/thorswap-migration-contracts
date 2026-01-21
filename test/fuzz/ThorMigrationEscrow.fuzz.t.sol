// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ThorMigrationEscrow.fuzz.t.sol
 * @notice Fuzz tests for ThorMigrationEscrow (10m/3m split entrypoints + deadline/startTime guards).
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

contract ThorMigrationEscrowFuzzTest is Test {
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

        escrow.setCaps(1_000_000 ether, 1_000_000 ether);
        escrow.setRatios(1e18, 1e18, 1e18);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        escrow.setYThorLimits(1_000_000 ether, block.timestamp + 365 days);
    }

    function testFuzz_Constructor_RevertWhenPastStartTime() public {
        vm.expectRevert(bytes("ThorEscrow: bad start time"));
        new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(ythor), block.timestamp - 1);
    }

    function testFuzz_SetMigrationStartTime_RevertWhenPast() public {
        vm.expectRevert(bytes("ThorEscrow: bad start time"));
        escrow.setMigrationStartTime(block.timestamp - 1);
    }

    function testFuzz_SetDeadlines_RevertWhenPast() public {
        vm.expectRevert(bytes("ThorEscrow: bad deadline"));
        escrow.setDeadlines(block.timestamp - 1, block.timestamp);
    }

    function testFuzz_SetYThorLimits_RevertWhenPastDeadline(uint256 capSeed) public {
        uint256 cap = bound(capSeed, 1, 1_000_000 ether);
        vm.expectRevert(bytes("ThorEscrow: bad deadline"));
        escrow.setYThorLimits(cap, block.timestamp - 1);
    }

    function testFuzz_MigrateThor3m_RevertWhen10mAvailable(uint96 amountInRaw) public {
        uint256 amountIn = bound(uint256(amountInRaw), 1, 100 ether);

        thor.mint(user, amountIn);
        vm.prank(user);
        thor.approve(address(escrow), amountIn);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: 10m available"));
        escrow.migrateThor3m(amountIn);
    }

    function testFuzz_MigrateThor10m_RevertThen3m_Succeeds_When10mCapExceeded(uint96 amountInRaw) public {
        uint256 amountIn = bound(uint256(amountInRaw), 2, 100 ether);

        // Cap 10m so this amount will exceed it (ratio10M = 1e18 => mint10 == amountIn).
        escrow.setCaps(1, escrow.cap3M());
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);

        thor.mint(user, amountIn);
        vm.prank(user);
        thor.approve(address(escrow), amountIn);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: 10m cap"));
        escrow.migrateThor10m(amountIn);

        vm.prank(user);
        escrow.migrateThor3m(amountIn);

        assertEq(xmetro.lastThorUser(), user);
        assertEq(xmetro.lastThorLockMonths(), 3);
    }

    function testFuzz_MigrateThor10m_Succeeds_AndUses10m(uint96 amountInRaw) public {
        uint256 amountIn = bound(uint256(amountInRaw), 1, 100 ether);

        thor.mint(user, amountIn);
        vm.prank(user);
        thor.approve(address(escrow), amountIn);

        uint256 expectedMint = (amountIn * escrow.ratio10M()) / 1e18;

        vm.prank(user);
        escrow.migrateThor10m(amountIn);

        assertEq(xmetro.lastThorUser(), user);
        assertEq(xmetro.lastThorAmount(), expectedMint);
        assertEq(xmetro.lastThorLockMonths(), 10);
        assertEq(escrow.minted10M(), expectedMint);
    }

    function testFuzz_MigrateYThor_Succeeds_AndMints(uint96 amountInRaw) public {
        uint256 amountIn = bound(uint256(amountInRaw), 1, 100 ether);

        ythor.mint(user, amountIn);
        vm.prank(user);
        ythor.approve(address(escrow), amountIn);

        uint256 expectedMint = (amountIn * escrow.ratioYThor()) / 1e18;

        vm.prank(user);
        escrow.migrateYThor(amountIn);

        assertEq(xmetro.lastVestingUser(), user);
        assertEq(xmetro.lastVestingAmount(), expectedMint);
        assertEq(escrow.mintedYThor(), expectedMint);
    }
}

