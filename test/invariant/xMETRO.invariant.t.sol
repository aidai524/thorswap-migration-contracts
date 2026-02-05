// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import { xMETRO } from "../../src/xMETRO.sol";
import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";
import { MockSwapAdapter } from "../mocks/MockSwapAdapter.sol";

contract xMETROHandler is Test {
    xMETRO public immutable xmetro;
    ERC20Mintable public immutable metro;
    ERC20Mintable public immutable usdc;
    MockSwapAdapter public immutable adapter;

    address[] public actors;

    constructor(xMETRO xmetro_, ERC20Mintable metro_, ERC20Mintable usdc_, MockSwapAdapter adapter_, address[] memory actors_)
    {
        xmetro = xmetro_;
        metro = metro_;
        usdc = usdc_;
        adapter = adapter_;
        actors = actors_;
    }

    /* ------------------------------ Time (admin) ------------------------------ */

    function warp(uint256 secondsForward) external {
        uint256 delta = bound(secondsForward, 0, 10 * 365 days);
        vm.warp(block.timestamp + delta);
    }

    /* ------------------------------ Config (owner) ----------------------------- */

    function pause() external {
        if (xmetro.paused()) return;
        xmetro.pause();
    }

    function unpause() external {
        if (!xmetro.paused()) return;
        xmetro.unpause();
    }

    function setSwapAdapter(uint256 seed) external {
        // Toggle between a valid adapter and "disabled" (zero address).
        address next = (seed % 4 == 0) ? address(0) : address(adapter);
        xmetro.setSwapAdapter(next);
    }

    function setRewardDistributor(uint256 seed) external {
        // Keep reward distribution mostly functional, but still exercise disabling.
        address next = (seed % 4 == 0) ? address(0) : address(this);
        xmetro.setRewardDistributor(next);
    }

    function setMigrationEscrow(uint256 seed) external {
        // Keep migration crediting mostly functional, but still exercise disabling.
        address next = (seed % 4 == 0) ? address(0) : address(this);
        xmetro.setMigrationEscrow(next);
    }

    function setDefaultMaxVestingSchedules(uint256 seed) external {
        uint256 v = bound(seed, 1, 200);
        xmetro.setDefaultMaxVestingSchedules(v);
    }

    function setDefaultMaxThorLocks(uint256 seed) external {
        uint256 v = bound(seed, 1, 200);
        xmetro.setDefaultMaxThorLocks(v);
    }

    function setAutoCompoundOperator(uint256 actorSeed, uint256 allowedSeed) external {
        address op = actors[actorSeed % actors.length];
        bool allowed = (allowedSeed % 2 == 0);
        xmetro.setAutoCompoundOperator(op, allowed);
    }

    function setContributor(uint256 actorSeed, uint256 allowedSeed) external {
        address c = actors[actorSeed % actors.length];
        bool allowed = (allowedSeed % 2 == 0);
        xmetro.setContributor(c, allowed);
    }

    function rescueUSDC(uint256 actorSeed, uint256 amountSeed) external {
        uint256 bal = usdc.balanceOf(address(xmetro));
        if (bal == 0) return;

        address to = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, bal);
        xmetro.rescueERC20(address(usdc), to, amount);
    }

    /* ----------------------------- Core user flows ---------------------------- */

    function stake(uint256 actorSeed, uint256 amountSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 100 ether);

        if (metro.balanceOf(actor) < amount) {
            metro.mint(actor, amount);
            vm.prank(actor);
            metro.approve(address(xmetro), type(uint256).max);
        }

        vm.prank(actor);
        xmetro.stake(amount);
    }

    function requestUnstake(uint256 actorSeed, uint256 amountSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        if (xmetro.unstakeRequestCountFree(actor) > 50) return;
        uint256 bal = xmetro.balanceOf(actor);
        if (bal == 0) return;

        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(actor);
        xmetro.requestUnstake(amount);
    }

    function withdraw(uint256 actorSeed, uint256 maxSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];

        uint256 source = maxSeed % 4;

        if (source == 0) {
            uint256 count = xmetro.unstakeRequestCountFree(actor);
            uint256 cursor = xmetro.unstakeCursorFree(actor);
            if (cursor >= count) return;

            xMETRO.UnstakeRequest memory r = xmetro.unstakeRequestFree(actor, cursor);
            if (r.unlockTime > block.timestamp) return;

            uint256 remaining = count - cursor;
            uint256 maxRequests = bound(maxSeed, 0, remaining);

            vm.prank(actor);
            xmetro.withdrawFree(maxRequests);
            return;
        }

        if (source == 1) {
            uint256 count = xmetro.unstakeRequestCountThor(actor);
            uint256 cursor = xmetro.unstakeCursorThor(actor);
            if (cursor >= count) return;

            xMETRO.UnstakeRequest memory r = xmetro.unstakeRequestThor(actor, cursor);
            if (r.unlockTime > block.timestamp) return;

            uint256 remaining = count - cursor;
            uint256 maxRequests = bound(maxSeed, 0, remaining);

            vm.prank(actor);
            xmetro.withdrawThor(maxRequests);
            return;
        }

        if (source == 2) {
            uint256 count = xmetro.unstakeRequestCountYThor(actor);
            uint256 cursor = xmetro.unstakeCursorYThor(actor);
            if (cursor >= count) return;

            xMETRO.UnstakeRequest memory r = xmetro.unstakeRequestYThor(actor, cursor);
            if (r.unlockTime > block.timestamp) return;

            uint256 remaining = count - cursor;
            uint256 maxRequests = bound(maxSeed, 0, remaining);

            vm.prank(actor);
            xmetro.withdrawYThor(maxRequests);
            return;
        }

        // source == 3
        uint256 count = xmetro.unstakeRequestCountContributor(actor);
        uint256 cursor = xmetro.unstakeCursorContributor(actor);
        if (cursor >= count) return;

        xMETRO.UnstakeRequest memory r = xmetro.unstakeRequestContributor(actor, cursor);
        if (r.unlockTime > block.timestamp) return;

        uint256 remaining = count - cursor;
        uint256 maxRequests = bound(maxSeed, 0, remaining);

        vm.prank(actor);
        xmetro.withdrawContributor(maxRequests);
    }

    function depositRewards(uint256 amountSeed) external {
        if (xmetro.paused()) return;
        if (xmetro.rewardDistributor() != address(this)) return;
        if (xmetro.totalShares() == 0) return;

        uint256 amount = bound(amountSeed, 1, 1_000_000 * 1e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(xmetro), amount);
        xmetro.depositRewards(amount);
    }

    function claimRewards(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 pending = xmetro.claimable(actor);
        if (pending == 0) return;
        if (pending > usdc.balanceOf(address(xmetro))) return;

        vm.prank(actor);
        xmetro.claimRewards();
    }

    function enableAutocompound(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        xmetro.enableAutocompound();
    }

    function disableAutocompound(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        xmetro.disableAutocompound();
    }

    function autocompound(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        if (address(xmetro.swapAdapter()) != address(adapter)) return;
        address actor = actors[actorSeed % actors.length];
        uint256 pending = xmetro.claimable(actor);
        if (pending == 0) return;

        // Ensure adapter has enough METRO to transfer back to xMETRO (MockSwapAdapter pays from its balance).
        uint256 expectedOut = (pending * adapter.mul()) / adapter.div();
        if (metro.balanceOf(address(adapter)) < expectedOut) {
            metro.mint(address(adapter), expectedOut);
        }

        vm.prank(actor);
        xmetro.autocompound(0, bytes(""));
    }

    function autocompoundBatch(uint256 nSeed) external {
        if (xmetro.paused()) return;
        if (address(xmetro.swapAdapter()) != address(adapter)) return;
        if (!xmetro.autoCompoundOperators(address(this))) return;
        uint256 n = bound(nSeed, 1, actors.length);

        address[] memory users = new address[](n);
        for (uint256 i = 0; i < n; i++) users[i] = actors[i];

        uint256 totalPending = 0;
        for (uint256 i = 0; i < n; i++) {
            if (!xmetro.autocompoundEnabled(users[i])) continue;
            totalPending += xmetro.claimable(users[i]);
        }
        if (totalPending == 0) return;

        uint256 expectedOut = (totalPending * adapter.mul()) / adapter.div();
        if (metro.balanceOf(address(adapter)) < expectedOut) {
            metro.mint(address(adapter), expectedOut);
        }

        xmetro.autocompoundBatch(users, 0, bytes(""));
    }

    function creditLockedThor(uint256 actorSeed, uint256 amountSeed, uint256 monthsSeed) external {
        if (xmetro.paused()) return;
        if (xmetro.migrationEscrow() != address(this)) return;
        address actor = actors[actorSeed % actors.length];
        if (xmetro.thorLocks3mCount(actor) + xmetro.thorLocks10mCount(actor) > 50) return;
        uint256 amount = bound(amountSeed, 1, 10 ether);
        uint256 lockMonths = (monthsSeed % 2 == 0) ? 3 : 10;
        xmetro.creditLockedTHORFromMigration(actor, amount, lockMonths);
    }

    function creditLockedVesting(uint256 actorSeed, uint256 amountSeed) external {
        if (xmetro.paused()) return;
        if (xmetro.migrationEscrow() != address(this)) return;
        address actor = actors[actorSeed % actors.length];
        if (xmetro.yThorVestingCount(actor) > 50) return;
        uint256 amount = bound(amountSeed, 1, 10 ether);
        xmetro.creditLockedVestingFromMigration(actor, amount);
    }

    function stakeContributor(uint256 actorSeed, uint256 amountSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        if (!xmetro.contributorWhitelist(actor)) return;
        if (xmetro.contributorVestingCount(actor) > 50) return;

        uint256 amount = bound(amountSeed, 1, 10 ether);
        if (metro.balanceOf(actor) < amount) {
            metro.mint(actor, amount);
            vm.prank(actor);
            metro.approve(address(xmetro), type(uint256).max);
        }

        vm.prank(actor);
        (bool ok,) = address(xmetro).call(abi.encodeCall(xMETRO.stakeContributor, (amount, actor)));
        ok;
    }

    function requestWithdrawUnlockedThor(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        (uint256 thorUnlockable,,,) = xmetro.previewWithdrawableNow(actor);
        if (thorUnlockable == 0) return;

        vm.prank(actor);
        (bool ok,) = address(xmetro).call(abi.encodeCall(xMETRO.requestWithdrawUnlockedThor, (uint256(0))));
        ok;
    }

    function requestWithdrawUnlockedYThor(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        (, uint256 yThorUnlockable,,) = xmetro.previewWithdrawableNow(actor);
        if (yThorUnlockable == 0) return;

        uint256 len = xmetro.yThorVestingCount(actor);
        if (len == 0) return;

        vm.prank(actor);
        (bool ok,) = address(xmetro).call(abi.encodeCall(xMETRO.requestWithdrawUnlockedYThor, (len)));
        ok;
    }

    function requestWithdrawUnlockedContributor(uint256 actorSeed) external {
        if (xmetro.paused()) return;
        address actor = actors[actorSeed % actors.length];
        (,, uint256 contribUnlockable,) = xmetro.previewWithdrawableNow(actor);
        if (contribUnlockable == 0) return;

        uint256 len = xmetro.contributorVestingCount(actor);
        if (len == 0) return;

        vm.prank(actor);
        (bool ok,) = address(xmetro).call(abi.encodeCall(xMETRO.requestWithdrawUnlockedContributor, (len)));
        ok;
    }

    /* -------------------------- ERC20 share transfers -------------------------- */

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (xmetro.paused()) return;
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to) return;

        uint256 bal = xmetro.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);

        vm.prank(from);
        xmetro.transfer(to, amount);
    }

    function transferSharesFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        if (xmetro.paused()) return;
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];

        uint256 bal = xmetro.balanceOf(owner);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);

        if (xmetro.allowance(owner, spender) < amount) {
            vm.prank(owner);
            xmetro.approve(spender, type(uint256).max);
        }

        vm.prank(spender);
        xmetro.transferFrom(owner, to, amount);
    }
}

contract xMETROInvariantTest is StdInvariant, Test {
    xMETRO internal xmetro;
    ERC20Mintable internal metro;
    ERC20Mintable internal usdc;
    MockSwapAdapter internal adapter;
    xMETROHandler internal handler;

    address[] internal actors;

    function setUp() public {
        metro = new ERC20Mintable("METRO", "METRO", 18);
        usdc = new ERC20Mintable("USDC", "USDC", 6);

        xmetro = new xMETRO(address(this), address(metro), address(usdc), address(0));

        adapter = new MockSwapAdapter(address(usdc), address(metro), 1e12, 1);
        adapter.setXMetro(address(xmetro));
        xmetro.setSwapAdapter(address(adapter));

        // Create a small fixed actor set.
        actors = new address[](5);
        for (uint256 i = 0; i < actors.length; i++) {
            address a = address(uint160(0x10000 + i));
            actors[i] = a;
            vm.deal(a, 10 ether);
            metro.mint(a, 1_000 ether);
            vm.prank(a);
            metro.approve(address(xmetro), type(uint256).max);
        }

        handler = new xMETROHandler(xmetro, metro, usdc, adapter, actors);

        // Hand over ownership to the handler so the state-machine can exercise owner-only config paths.
        xmetro.transferOwnership(address(handler));

        vm.startPrank(address(handler));
        xmetro.setMigrationEscrow(address(handler));
        xmetro.setRewardDistributor(address(handler));
        xmetro.setAutoCompoundOperator(address(handler), true);
        xmetro.setContributor(actors[0], true);
        vm.stopPrank();

        // Fund adapter to avoid swap failing due to insufficient tokenOut.
        metro.mint(address(adapter), 10_000_000 ether);

        bytes4[] memory selectors = new bytes4[](28);
        selectors[0] = xMETROHandler.warp.selector;
        selectors[1] = xMETROHandler.pause.selector;
        selectors[2] = xMETROHandler.unpause.selector;
        selectors[3] = xMETROHandler.setSwapAdapter.selector;
        selectors[4] = xMETROHandler.setRewardDistributor.selector;
        selectors[5] = xMETROHandler.setMigrationEscrow.selector;
        selectors[6] = xMETROHandler.setDefaultMaxVestingSchedules.selector;
        selectors[7] = xMETROHandler.setDefaultMaxThorLocks.selector;
        selectors[8] = xMETROHandler.setAutoCompoundOperator.selector;
        selectors[9] = xMETROHandler.setContributor.selector;
        selectors[10] = xMETROHandler.rescueUSDC.selector;

        selectors[11] = xMETROHandler.stake.selector;
        selectors[12] = xMETROHandler.requestUnstake.selector;
        selectors[13] = xMETROHandler.withdraw.selector;
        selectors[14] = xMETROHandler.depositRewards.selector;
        selectors[15] = xMETROHandler.claimRewards.selector;

        selectors[16] = xMETROHandler.enableAutocompound.selector;
        selectors[17] = xMETROHandler.disableAutocompound.selector;
        selectors[18] = xMETROHandler.autocompound.selector;
        selectors[19] = xMETROHandler.autocompoundBatch.selector;

        selectors[20] = xMETROHandler.creditLockedThor.selector;
        selectors[21] = xMETROHandler.creditLockedVesting.selector;
        selectors[22] = xMETROHandler.stakeContributor.selector;
        selectors[23] = xMETROHandler.requestWithdrawUnlockedThor.selector;
        selectors[24] = xMETROHandler.requestWithdrawUnlockedYThor.selector;
        selectors[25] = xMETROHandler.requestWithdrawUnlockedContributor.selector;

        selectors[26] = xMETROHandler.transferShares.selector;
        selectors[27] = xMETROHandler.transferSharesFrom.selector;

        // Target the handler with a curated selector set to keep the state-machine stable.
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_TotalSharesMatchesIdentity() public view {
        assertEq(xmetro.totalShares(), xmetro.totalSupply() + xmetro.totalLockedShares());

        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            assertEq(xmetro.totalSharesOf(a), xmetro.balanceOf(a) + xmetro.lockedShares(a));
        }
    }

    function invariant_TotalLockedSharesMatchesSumOfActors() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += xmetro.lockedShares(actors[i]);
        }
        assertEq(sum, xmetro.totalLockedShares());
    }

    function invariant_MetroBalanceCoversTotalShares() public view {
        assertGe(metro.balanceOf(address(xmetro)), xmetro.totalShares());
    }
}
