// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title GasThresholds.t.sol
 * @notice Fork stress test: estimate max batch sizes under a gas cap near the forked chain's block gas limit.
 * @dev Uses low-level calls with `gas: gasCap` to simulate transaction gas limits.
 */

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { xMETRO } from "../../src/xMETRO.sol";

import { ERC20Mintable } from "../mocks/ERC20Mintable.sol";

contract MockSwapAdapter {
    IERC20 public immutable USDC;
    ERC20Mintable public immutable METRO;
    address public immutable xMETRO_ADDR;

    constructor(address usdc, address metro, address xmetro) {
        USDC = IERC20(usdc);
        METRO = ERC20Mintable(metro);
        xMETRO_ADDR = xmetro;
    }

    function swap(uint256 amountIn, uint256 minAmountOut, bytes calldata) external returns (uint256 amountOut) {
        require(msg.sender == xMETRO_ADDR, "MockSwapAdapter: only xMETRO");
        require(amountIn > 0, "MockSwapAdapter: zero amount");

        amountOut = amountIn * 1e12;
        require(amountOut >= minAmountOut, "MockSwapAdapter: slippage");

        USDC.transferFrom(msg.sender, address(this), amountIn);
        METRO.mint(xMETRO_ADDR, amountOut);
        return amountOut;
    }
}

contract GasThresholdsForkTest is Test {
    address internal user = address(0xB0B);

    /**
     * @dev Fork a chain (for realistic `block.gaslimit`) and deploy local mock components.
     */
    function _deploy() internal returns (xMETRO xmetro, ERC20Mintable metro, ERC20Mintable usdc) {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing ETH_RPC_URL");
        vm.createSelectFork(rpc);

        metro = new ERC20Mintable("METRO", "METRO", 18);
        usdc = new ERC20Mintable("USDC", "USDC", 6);

        xmetro = new xMETRO(address(this), address(metro), address(usdc), address(0));
        xmetro.setMigrationEscrow(address(this));

        xmetro.setRewardDistributor(address(this));

        vm.deal(user, 100 ether);
    }

    function test_GasThreshold_WithdrawUnlockedYThor_MaxSchedules() public {
        (xMETRO xmetro, ERC20Mintable metro,) = _deploy();

        uint256 len = vm.envOr("VEST_LEN", uint256(10000));
        require(len > 0, "VEST_LEN=0");

        for (uint256 i = 0; i < len; i++) {
            xmetro.creditLockedVestingFromMigration(user, 1 ether);
        }

        vm.warp(block.timestamp + xmetro.YTHOR_CLIFF() + (xmetro.YTHOR_DURATION() / 2));

        uint256 gasCap = vm.envOr("GAS_CAP", block.gaslimit > 500_000 ? block.gaslimit - 500_000 : block.gaslimit);
        console2.log("Fork block.gaslimit", block.gaslimit);
        console2.log("Probe gasCap", gasCap);
        console2.log("Vesting schedules len", len);

        uint256 snap = vm.snapshotState();

        uint256 low = 1;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            vm.revertToState(snap);

            bytes memory data = abi.encodeCall(xMETRO.withdrawUnlockedYThor, (mid));
            vm.prank(user);
            (bool ok,) = address(xmetro).call{ gas: gasCap }(data);

            if (ok) low = mid;
            else high = mid - 1;
        }

        console2.log("Max withdrawUnlockedYThor(maxSchedules) OK =", low);
        if (low == len) console2.log("NOTE: threshold >= len, increase VEST_LEN to find real OOG point");

        assertGt(low, 0, "maxOk=0");
    }

    function test_GasThreshold_WithdrawUnlockedThor_DefaultMax() public {
        (xMETRO xmetro,,) = _deploy();

        uint256 len = vm.envOr("LOCK_LEN", uint256(20000));
        require(len > 0, "LOCK_LEN=0");

        for (uint256 i = 0; i < len; i++) {
            xmetro.creditLockedTHORFromMigration(user, 1 ether, 3);
        }

        vm.warp(block.timestamp + (3 * xmetro.THOR_LOCK_MONTH_SECONDS()) + 1);

        uint256 gasCap = vm.envOr("GAS_CAP", block.gaslimit > 300_0000 ? block.gaslimit - 300_0000 : block.gaslimit);
        console2.log("Fork block.gaslimit", block.gaslimit);
        console2.log("Probe gasCap", gasCap);
        console2.log("THOR locks len", len);

        uint256 snap = vm.snapshotState();

        uint256 low = 1;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            vm.revertToState(snap);

            xmetro.setDefaultMaxThorLocks(mid);

            bytes memory data = abi.encodeCall(xMETRO.withdrawUnlockedThor, (uint256(0)));
            vm.prank(user);
            (bool ok,) = address(xmetro).call{ gas: gasCap }(data);

            if (ok) low = mid;
            else high = mid - 1;
        }

        console2.log("Max defaultMaxThorLocks OK =", low);
        if (low == len) console2.log("NOTE: threshold >= len, increase LOCK_LEN to find real OOG point");

        assertGt(low, 0, "maxOk=0");
    }

    function test_GasThreshold_WithdrawUnlockedContributor_MaxSchedules() public {
        (xMETRO xmetro, ERC20Mintable metro,) = _deploy();

        uint256 len = vm.envOr("CONTRIB_LEN", uint256(10000));
        require(len > 0, "CONTRIB_LEN=0");

        xmetro.setContributor(user, true);

        uint256 total = len * 1 ether;
        metro.mint(user, total);
        vm.prank(user);
        metro.approve(address(xmetro), total);

        for (uint256 i = 0; i < len; i++) {
            vm.prank(user);
            xmetro.stakeContributor(1 ether, user);
        }

        vm.warp(block.timestamp + xmetro.CONTRIBUTOR_CLIFF() + (xmetro.CONTRIBUTOR_DURATION() / 2));

        uint256 gasCap = vm.envOr("GAS_CAP", block.gaslimit > 500_000 ? block.gaslimit - 500_000 : block.gaslimit);
        console2.log("Fork block.gaslimit", block.gaslimit);
        console2.log("Probe gasCap", gasCap);
        console2.log("Contributor schedules len", len);

        uint256 snap = vm.snapshotState();

        uint256 low = 1;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            vm.revertToState(snap);

            bytes memory data = abi.encodeCall(xMETRO.withdrawUnlockedContributor, (mid));
            vm.prank(user);
            (bool ok,) = address(xmetro).call{ gas: gasCap }(data);

            if (ok) low = mid;
            else high = mid - 1;
        }

        console2.log("Max withdrawUnlockedContributor(maxSchedules) OK =", low);
        if (low == len) console2.log("NOTE: threshold >= len, increase CONTRIB_LEN to find real OOG point");

        assertGt(low, 0, "maxOk=0");
    }

    function test_GasThreshold_Withdraw_MaxRequests() public {
        (xMETRO xmetro, ERC20Mintable metro,) = _deploy();

        uint256 len = vm.envOr("REQ_LEN", uint256(20000));
        require(len > 0, "REQ_LEN=0");

        uint256 total = len * 1 ether;
        metro.mint(user, total);
        vm.prank(user);
        metro.approve(address(xmetro), total);
        vm.prank(user);
        xmetro.stake(total);

        for (uint256 i = 0; i < len; i++) {
            vm.prank(user);
            xmetro.requestUnstake(1 ether);
        }

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY() + 1);

        uint256 gasCap = vm.envOr("GAS_CAP", block.gaslimit > 300_0000 ? block.gaslimit - 300_0000 : block.gaslimit);
        console2.log("Fork block.gaslimit", block.gaslimit);
        console2.log("Probe gasCap", gasCap);
        console2.log("Unstake requests len", len);

        uint256 snap = vm.snapshotState();

        uint256 low = 1;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            vm.revertToState(snap);

            bytes memory data = abi.encodeCall(xMETRO.withdraw, (mid));
            vm.prank(user);
            (bool ok,) = address(xmetro).call{ gas: gasCap }(data);

            if (ok) low = mid;
            else high = mid - 1;
        }

        console2.log("Max withdraw(maxRequests) OK =", low);
        if (low == len) console2.log("NOTE: threshold >= len, increase REQ_LEN to find real OOG point");

        assertGt(low, 0, "maxOk=0");
    }

    function test_GasReport_AutocompoundBatchAndClaimableMany_100_200_300() public {
        (xMETRO xmetro, ERC20Mintable metro, ERC20Mintable usdc) = _deploy();

        MockSwapAdapter adapter = new MockSwapAdapter(address(usdc), address(metro), address(xmetro));
        xmetro.setSwapAdapter(address(adapter));

        address operator = address(0xA11CE);
        xmetro.setAutoCompoundOperator(operator, true);

        uint256 maxUsers = 300;
        address[] memory users = new address[](maxUsers);

        for (uint256 i = 0; i < maxUsers; i++) {
            address u = address(uint160(0x10000 + i));
            users[i] = u;

            metro.mint(u, 1 ether);

            vm.startPrank(u);
            metro.approve(address(xmetro), type(uint256).max);
            xmetro.stake(1 ether);
            xmetro.enableAutocompound();
            vm.stopPrank();
        }

        uint256 totalRewards = maxUsers * 1e6;
        usdc.mint(address(this), totalRewards);
        usdc.approve(address(xmetro), totalRewards);
        xmetro.depositRewards(totalRewards);

        uint256 snap = vm.snapshotState();

        _reportClaimableManyGas(xmetro, users, 100);
        _reportAutocompoundBatchGas(xmetro, users, 100, operator);

        vm.revertToState(snap);
        _reportClaimableManyGas(xmetro, users, 200);
        _reportAutocompoundBatchGas(xmetro, users, 200, operator);

        vm.revertToState(snap);
        _reportClaimableManyGas(xmetro, users, 300);
        _reportAutocompoundBatchGas(xmetro, users, 300, operator);
    }

    function _reportClaimableManyGas(xMETRO xmetro, address[] memory users, uint256 n) internal {
        address[] memory batch = new address[](n);
        for (uint256 i = 0; i < n; i++) batch[i] = users[i];

        uint256 gasStart = gasleft();
        (uint256 totalPending,) = xmetro.claimableMany(batch);
        uint256 gasUsed = gasStart - gasleft();

        require(totalPending == n * 1e6, "bad totalPending");
        console2.log(string.concat("GAS_REPORT claimableMany n=", vm.toString(n), " gas=", vm.toString(gasUsed)));
    }

    function _reportAutocompoundBatchGas(xMETRO xmetro, address[] memory users, uint256 n, address operator) internal {
        address[] memory batch = new address[](n);
        for (uint256 i = 0; i < n; i++) batch[i] = users[i];

        uint256 gasStart = gasleft();
        vm.prank(operator);
        xmetro.autocompoundBatch(batch, 0, "");
        uint256 gasUsed = gasStart - gasleft();

        console2.log(string.concat("GAS_REPORT autocompoundBatch n=", vm.toString(n), " gas=", vm.toString(gasUsed)));
    }
}
