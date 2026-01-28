// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


interface IMetroTokenMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}


interface ISwapAdapter {
    function swap(uint256 amountIn, uint256 minAmountOut, bytes calldata swapData) external returns (uint256 amountOut);
}

contract xMETRO is ERC20, Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;


    uint256 private constant ACC_PRECISION = 1e24;


    uint64 public constant UNSTAKE_DELAY = 14 days;


    uint64 public constant THOR_LOCK_MONTH_SECONDS = 30 days;


    uint64 public constant YTHOR_CLIFF = 4 * 365 days;


    uint64 public constant YTHOR_DURATION = 2 * 365 days;


    uint64 public constant CONTRIBUTOR_CLIFF = 6 * THOR_LOCK_MONTH_SECONDS;


    uint64 public constant CONTRIBUTOR_DURATION = (5 * 365 days) / 2;


    uint256 public defaultMaxVestingSchedules = 50;


    uint256 public defaultMaxThorLocks = 100;


    uint256 public totalLockedShares;


    uint256 public accRewardPerShare;


    /// @notice THOR lock entry: `amount` becomes free after `endTime`.
    struct ThorLock {
        uint128 amount;
        uint64 endTime;
    }

    /// @notice yTHOR vesting schedule entry (cliff handled by `startTime`).
    struct VestingSchedule {
        uint128 totalAmount;
        uint128 claimed;
        uint64 startTime;
        uint64 duration;
    }

    /// @notice Unstake request: burned freeShares re-mints underlying METRO after `unlockTime`.
    struct UnstakeRequest {
        uint128 amount;
        uint64 unlockTime;
    }


    IMetroTokenMintable public immutable METRO;


    IERC20 public immutable rewardToken;

    
    address public rewardDistributor;

    
    ISwapAdapter public swapAdapter;

    
    address public migrationEscrow;

    /// @notice Operators allowed to call `autocompoundBatch`.
    mapping(address => bool) public autoCompoundOperators;

    /// @notice Whether the user has enabled autocompounding.
    mapping(address => bool) public autocompoundEnabled;

    /// @notice Contributor whitelist (only whitelisted addresses can create contributor vesting/lock positions).
    mapping(address => bool) public contributorWhitelist;

    /// @notice user => locked shares (not transferable; used for rewards baseline).
    mapping(address => uint256) public lockedShares;

    /// @dev user => 3-month THOR locks.
    mapping(address => ThorLock[]) private _thorLocks3m;
    /// @dev user => 10-month THOR locks.
    mapping(address => ThorLock[]) private _thorLocks10m;

    /// @notice user => cursor into `_thorLocks3m` for checkpoint processing.
    mapping(address => uint256) public thorLockCursor3m;

    /// @notice user => cursor into `_thorLocks10m` for checkpoint processing.
    mapping(address => uint256) public thorLockCursor10m;

    /// @dev user => yTHOR vesting schedules.
    mapping(address => VestingSchedule[]) private _yThorVests;

    /// @notice user => cursor for batched vesting processing.
    mapping(address => uint256) public yThorVestCursor;

    /// @dev receiver (beneficiary) => contributor-funded vesting schedules (6m cliff + 2.5y linear).
    mapping(address => VestingSchedule[]) private _contributorVests;

    /// @notice receiver (beneficiary) => cursor for batched contributor vesting processing.
    mapping(address => uint256) public contributorVestCursor;

    /// @notice Signed reward debt per user (supports decreasing shares without underflow).
    mapping(address => int256) public rewardDebt;

    /// @dev user => unstake request queue.
    mapping(address => UnstakeRequest[]) private _unstakeRequests;

    /// @notice user => cursor for batched unstake request processing.
    mapping(address => uint256) public unstakeCursor;

    event RewardDistributorUpdated(address indexed distributor);
    event SwapAdapterUpdated(address indexed swapAdapter);
    event DefaultMaxVestingSchedulesUpdated(uint256 maxVestingSchedules);
    event DefaultMaxThorLocksUpdated(uint256 maxThorLocks);

    event MigrationEscrowUpdated(address indexed escrow);

    event LockedTHORCredited(address indexed user, uint256 amount, uint256 lockMonths, uint64 endTime);
    event LockedVestingCredited(address indexed user, uint256 amount, uint64 startTime, uint64 duration);
    event RewardsDeposited(address indexed payer, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    event UnstakeRequested(address indexed user, uint256 amount, uint64 unlockTime);
    event Withdrawn(address indexed user, uint256 amount);

    event AutoCompounded(address indexed user, uint256 usdcIn, uint256 metroOut);

    event AutoCompoundOperatorUpdated(address indexed operator, bool allowed);

  
    event AutocompoundEnabledUpdated(address indexed user, bool enabled);

   
    event AutocompoundBatchExecuted(address indexed operator, uint256 totalUsdcIn, uint256 totalMetroOut);


    event ContributorWhitelistUpdated(address indexed contributor, bool allowed);

   
    event ContributorStaked(address indexed contributor, address indexed receiver, uint256 amount, uint64 startTime, uint64 duration);

   
    event ThorUnlockedWithdrawn(address indexed user, uint256 amount);

    
    event YThorUnlockedWithdrawn(address indexed user, uint256 amount);

    
    event ContributorUnlockedWithdrawn(address indexed user, uint256 amount);

    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(address owner_, address metro_, address rewardToken_, address swapAdapter_) Ownable(owner_) ERC20("xMETRO", "xMETRO") {
        require(metro_ != address(0) && rewardToken_ != address(0), "xMETRO: zero address");
        METRO = IMetroTokenMintable(metro_);
        rewardToken = IERC20(rewardToken_);
        swapAdapter = ISwapAdapter(swapAdapter_);
    }

    modifier onlyMigrationEscrow() {
        require(msg.sender == migrationEscrow, "xMETRO: only migration escrow");
        _;
    }

    /// @notice Stake METRO and receive 1:1 free shares (xMETRO ERC20).
    function stake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 mintedShares) {
        require(amount > 0, "xMETRO: zero amount");

        IERC20(address(METRO)).safeTransferFrom(msg.sender, address(this), amount);

        _mintFreeShares(msg.sender, amount);
        mintedShares = amount;
    }

    /// @notice Request unstake for free shares; burns shares immediately and starts a 14-day cooldown.
    function requestUnstake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "xMETRO: zero amount");

        require(balanceOf(msg.sender) >= amount, "xMETRO: insufficient free");

        _burnFreeShares(msg.sender, amount);

        uint64 unlockTime = uint64(block.timestamp) + UNSTAKE_DELAY;
        _unstakeRequests[msg.sender].push(UnstakeRequest(uint128(amount), unlockTime));

        emit UnstakeRequested(msg.sender, amount, unlockTime);
    }

    /// @notice Withdraw matured unstake requests and receive METRO.
    /// @param maxRequests Max number of matured requests to process (0 = as many as possible).
    function withdraw(uint256 maxRequests) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        UnstakeRequest[] storage requests = _unstakeRequests[msg.sender];
        uint256 cursor = unstakeCursor[msg.sender];
        uint256 len = requests.length;

        if (cursor >= len) return 0;

        uint256 processedCount = 0;
        uint256 totalToSend = 0;

        while (cursor < len) {
            UnstakeRequest memory r = requests[cursor];
            if (r.unlockTime > block.timestamp) break;

            totalToSend += uint256(r.amount);
            cursor++;
            processedCount++;

            if (maxRequests != 0 && processedCount >= maxRequests) break;
        }

        require(totalToSend > 0, "xMETRO: nothing to withdraw");
        unstakeCursor[msg.sender] = cursor;

        IERC20(address(METRO)).safeTransfer(msg.sender, totalToSend);
        emit Withdrawn(msg.sender, totalToSend);

        return totalToSend;
    }

    /// @notice Deposit rewardToken and update `accRewardPerShare` (pro-rata by total shares, incl. locked).
    function depositRewards(uint256 amount) external nonReentrant whenNotPaused {
        require(msg.sender == rewardDistributor, "xMETRO: only distributor");
        require(amount > 0, "xMETRO: zero amount");
        uint256 shares = totalShares();
        require(shares > 0, "xMETRO: no shares");

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        accRewardPerShare = accRewardPerShare + ((amount * ACC_PRECISION) / shares);

        emit RewardsDeposited(msg.sender, amount);
    }

    /// @notice Claim pending rewards in rewardToken.
    function claimRewards() external nonReentrant whenNotPaused returns (uint256 pending) {
        int256 accumulated;
        (pending, accumulated) = _pendingAndAccumulated(msg.sender);
        rewardDebt[msg.sender] = accumulated;

        if (pending > 0) {
            rewardToken.safeTransfer(msg.sender, pending);
        }

        emit RewardClaimed(msg.sender, pending);
        return pending;
    }

    /// @notice Autocompound: swap user's pending rewards (rewardToken) into METRO and mint received amount as free shares.
    /// @param minMetroOut Slippage protection: minimum METRO to receive.
    /// @param swapData Opaque routing data consumed by SwapAdapter.
    function autocompound(uint256 minMetroOut, bytes calldata swapData)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 metroOut)
    {
        return _autocompound(msg.sender, minMetroOut, swapData);
    }


    function enableAutocompound() external whenNotPaused {
        autocompoundEnabled[msg.sender] = true;
        emit AutocompoundEnabledUpdated(msg.sender, true);
    }

   
    function disableAutocompound() external whenNotPaused {
        autocompoundEnabled[msg.sender] = false;
        emit AutocompoundEnabledUpdated(msg.sender, false);
    }

    /**
     * @notice Batch autocompound: aggregate a set of users' pending USDC, swap it into METRO, then mint xMETRO pro-rata by pending.
     * @dev The user list is maintained off-chain by the bot and passed in via calldata; the contract also checks `autocompoundEnabled[user] == true`.
     */
    function autocompoundBatch(address[] calldata users, uint256 minMetroOut, bytes calldata swapData)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 metroOut)
    {
        require(autoCompoundOperators[msg.sender], "xMETRO: only autocompound operator");
        require(address(swapAdapter) != address(0), "xMETRO: adapter not set");
        require(users.length > 0, "xMETRO: empty users");

        uint256 len = users.length;
        uint256[] memory pendings = new uint256[](len);

        uint256 totalPending = 0;


        for (uint256 i = 0; i < len; i++) {
            address user = users[i];
            if (user == address(0)) continue;
            if (!autocompoundEnabled[user]) continue;

            (uint256 pending, int256 accumulated) = _pendingAndAccumulated(user);
            if (pending == 0) continue;

            rewardDebt[user] = accumulated;
            pendings[i] = pending;
            totalPending += pending;
        }

        require(totalPending > 0, "xMETRO: no rewards");


        uint256 metroBefore = METRO.balanceOf(address(this));
        rewardToken.forceApprove(address(swapAdapter), totalPending);
        metroOut = swapAdapter.swap(totalPending, minMetroOut, swapData);
        rewardToken.forceApprove(address(swapAdapter), 0);

        uint256 metroAfter = METRO.balanceOf(address(this));
        uint256 received = metroAfter - metroBefore;
        require(received >= minMetroOut, "xMETRO: slippage");


        for (uint256 i = 0; i < len; i++) {
            uint256 pending = pendings[i];
            if (pending == 0) continue;

            uint256 share = (received * pending) / totalPending;

            if (share > 0) {
                _mintFreeShares(users[i], share);
            }

            emit AutoCompounded(users[i], pending, share);
        }


        emit AutocompoundBatchExecuted(msg.sender, totalPending, received);
        return received;
    }

    /// @dev When free shares move, move the corresponding reward debt to avoid leaking past rewards.
    function transfer(address to, uint256 amount) public override returns (bool) {
        _moveFreeSharesDebt(_msgSender(), to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _moveFreeSharesDebt(from, to, amount);
        return super.transferFrom(from, to, amount);
    }


    function pause() external onlyOwner {
        _pause();
    }

 
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Update swap adapter (set to zero address to disable autocompound).
    function setSwapAdapter(address swapAdapter_) external onlyOwner {
        swapAdapter = ISwapAdapter(swapAdapter_);
        emit SwapAdapterUpdated(swapAdapter_);
    }

    /// @notice Set migration escrow allowed to call `creditLocked*FromMigration` (set to zero to disable).
    function setMigrationEscrow(address escrow) external onlyOwner {
        migrationEscrow = escrow;
        emit MigrationEscrowUpdated(escrow);
    }

    /// @notice Set RewardDistributor (the only caller allowed to `depositRewards`).
    function setRewardDistributor(address distributor) external onlyOwner {
        rewardDistributor = distributor;
        emit RewardDistributorUpdated(distributor);
    }

    /// @notice Set/unset an operator allowed to call `autocompoundBatch`.
    function setAutoCompoundOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "xMETRO: bad operator");
        autoCompoundOperators[operator] = allowed;
        emit AutoCompoundOperatorUpdated(operator, allowed);
    }

    /// @notice Set default max vesting schedules processed per checkpoint call.
    function setDefaultMaxVestingSchedules(uint256 newDefault) external onlyOwner {
        require(newDefault > 0, "xMETRO: zero max");
        defaultMaxVestingSchedules = newDefault;
        emit DefaultMaxVestingSchedulesUpdated(newDefault);
    }

    /// @notice Set default max THOR locks processed per checkpoint call.
    function setDefaultMaxThorLocks(uint256 newDefault) external onlyOwner {
        require(newDefault > 0, "xMETRO: zero max");
        defaultMaxThorLocks = newDefault;
        emit DefaultMaxThorLocksUpdated(newDefault);
    }


    /// @notice Allow or revoke a contributor address (whitelist).
    /// @dev Only whitelisted contributors can call `stakeContributor`.
    function setContributor(address contributor, bool allowed) external onlyOwner {
        require(contributor != address(0), "xMETRO: bad contributor");
        contributorWhitelist[contributor] = allowed;
        emit ContributorWhitelistUpdated(contributor, allowed);
    }


    /// @notice Stake METRO as a contributor and create a locked vesting position (6m cliff + 2.5y linear release).
    /// @param receiver Address credited with the contributor vesting position.
    /// @dev Only callable by `contributorWhitelist[msg.sender] == true`. Funds are pulled from `msg.sender`.
    function stakeContributor(uint256 amount, address receiver) external nonReentrant whenNotPaused {
        require(contributorWhitelist[msg.sender], "xMETRO: not contributor");
        require(amount > 0, "xMETRO: zero amount");
        require(receiver != address(0), "xMETRO: bad receiver");

        IERC20(address(METRO)).safeTransferFrom(msg.sender, address(this), amount);

        uint64 startTime = uint64(block.timestamp) + CONTRIBUTOR_CLIFF;
        uint64 duration = CONTRIBUTOR_DURATION;
        _contributorVests[receiver].push(VestingSchedule(uint128(amount), 0, startTime, duration));

        _increaseLockedShares(receiver, amount);
        emit ContributorStaked(msg.sender, receiver, amount, startTime, duration);
    }


    /// @notice Withdraw currently-unlocked THOR-migration principal (3m + 10m locks) directly as METRO.
    /// @param maxLocks Max number of lock entries to consume per lock array (0 uses `defaultMaxThorLocks`).
    function withdrawUnlockedThor(uint256 maxLocks) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        uint256 max = maxLocks == 0 ? defaultMaxThorLocks : maxLocks;
        require(max > 0, "xMETRO: zero max");

        uint256 unlocked;
        unlocked += _consumeThorLocks(_thorLocks3m[msg.sender], thorLockCursor3m[msg.sender], msg.sender, true, max);
        unlocked += _consumeThorLocks(_thorLocks10m[msg.sender], thorLockCursor10m[msg.sender], msg.sender, false, max);

        require(unlocked > 0, "xMETRO: nothing unlocked");

        _decreaseLockedShares(msg.sender, unlocked);
        IERC20(address(METRO)).safeTransfer(msg.sender, unlocked);
        emit ThorUnlockedWithdrawn(msg.sender, unlocked);
        return unlocked;
    }


    /// @notice Withdraw currently-vested yTHOR-migration principal directly as METRO.
    /// @param maxSchedules Max number of vesting schedules to scan/consume (0 uses `defaultMaxVestingSchedules`).
    function withdrawUnlockedYThor(uint256 maxSchedules) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        uint256 unlocked = _consumeVesting(msg.sender, maxSchedules);
        require(unlocked > 0, "xMETRO: nothing unlocked");

        _decreaseLockedShares(msg.sender, unlocked);
        IERC20(address(METRO)).safeTransfer(msg.sender, unlocked);
        emit YThorUnlockedWithdrawn(msg.sender, unlocked);
        return unlocked;
    }


    /// @notice Withdraw currently-vested contributor principal directly as METRO.
    /// @param maxSchedules Max number of vesting schedules to scan/consume (0 uses `defaultMaxVestingSchedules`).
    function withdrawUnlockedContributor(uint256 maxSchedules)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        uint256 unlocked = _consumeContributorVesting(msg.sender, maxSchedules);
        require(unlocked > 0, "xMETRO: nothing unlocked");

        _decreaseLockedShares(msg.sender, unlocked);
        IERC20(address(METRO)).safeTransfer(msg.sender, unlocked);
        emit ContributorUnlockedWithdrawn(msg.sender, unlocked);
        return unlocked;
    }

    /// @notice Migration flow: mint METRO and credit a locked THOR position (3m/10m).
    function creditLockedTHORFromMigration(address user, uint256 amount, uint256 lockMonths)
        external
        nonReentrant
        whenNotPaused
        onlyMigrationEscrow
    {
        require(user != address(0) && amount > 0, "xMETRO: bad params");
        METRO.mint(address(this), amount);
        _creditLockedTHOR(user, amount, lockMonths);
    }

    /// @notice Migration flow: mint METRO and credit a locked vesting position (yTHOR schedule).
    function creditLockedVestingFromMigration(address user, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyMigrationEscrow
    {
        require(user != address(0) && amount > 0, "xMETRO: bad params");
        METRO.mint(address(this), amount);
        _creditLockedVesting(user, amount);
    }

    /// @notice Rescue tokens (METRO excluded).
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(METRO), "xMETRO: cannot rescue METRO");
        require(to != address(0), "xMETRO: bad to");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @dev Preview: unlockable THOR amount (read-only).
    function _previewThorUnlockable(address user) internal view returns (uint256 unlockable) {
        unlockable += _previewThorUnlockableFor(_thorLocks3m[user], thorLockCursor3m[user]);
        unlockable += _previewThorUnlockableFor(_thorLocks10m[user], thorLockCursor10m[user]);
    }

    /// @dev Preview: unlockable THOR amount for a single lock array (read-only).
    function _previewThorUnlockableFor(ThorLock[] storage locks, uint256 cursor) internal view returns (uint256 unlockable) {
        uint256 len = locks.length;
        if (cursor >= len) return 0;
        for (uint256 i = cursor; i < len; i++) {
            ThorLock memory l = locks[i];
            if (l.endTime > block.timestamp) break;
            unlockable += uint256(l.amount);
        }
    }

    /// @dev Preview: unlockable vesting amount (read-only).
    function _previewVestingUnlockable(address user) internal view returns (uint256 unlockable) {
        VestingSchedule[] storage schedules = _yThorVests[user];
        uint256 len = schedules.length;
        if (len == 0) return 0;
        uint64 ts = uint64(block.timestamp);
        for (uint256 i = 0; i < len; i++) {
            VestingSchedule memory s = schedules[i];
            unlockable += _releasable(s, ts);
        }
    }

    /// @dev Preview: unlockable contributor vesting amount (read-only).
    function _previewContributorUnlockable(address user) internal view returns (uint256 unlockable) {
        VestingSchedule[] storage schedules = _contributorVests[user];
        uint256 len = schedules.length;
        if (len == 0) return 0;
        uint64 ts = uint64(block.timestamp);
        for (uint256 i = 0; i < len; i++) {
            VestingSchedule memory s = schedules[i];
            unlockable += _releasable(s, ts);
        }
    }

    /// @dev Credit a THOR lock (updates lockedShares; does not mint ERC20 shares).
    function _creditLockedTHOR(address user, uint256 amount, uint256 lockMonths) internal {
        require(amount <= type(uint128).max, "xMETRO: amount too large");

        require(lockMonths == 3 || lockMonths == 10, "xMETRO: bad lock months");

        uint64 endTime = uint64(block.timestamp) + uint64(lockMonths) * THOR_LOCK_MONTH_SECONDS;

        if (lockMonths == 3) {
            _thorLocks3m[user].push(ThorLock(uint128(amount), endTime));
        } else {
            _thorLocks10m[user].push(ThorLock(uint128(amount), endTime));
        }

        _increaseLockedShares(user, amount);
        emit LockedTHORCredited(user, amount, lockMonths, endTime);
    }

    /// @dev Credit a vesting schedule (updates lockedShares; does not mint ERC20 shares).
    function _creditLockedVesting(address user, uint256 amount) internal {
        require(amount <= type(uint128).max, "xMETRO: amount too large");

        uint64 startTime = uint64(block.timestamp) + YTHOR_CLIFF;
        uint64 duration = YTHOR_DURATION;

        _yThorVests[user].push(VestingSchedule(uint128(amount), 0, startTime, duration));

        _increaseLockedShares(user, amount);
        emit LockedVestingCredited(user, amount, startTime, duration);
    }

    /// @dev Linear vesting schedule (same math as OZ VestingWallet._vestingSchedule).
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp, uint64 startTime, uint64 duration)
        internal
        pure
        returns (uint256)
    {
        if (timestamp < startTime) return 0;

        uint64 endTime = startTime + duration;
        if (timestamp >= endTime) return totalAllocation;

        return (totalAllocation * (timestamp - startTime)) / duration;
    }

    /// @dev Releasable (vested - claimed) at a given timestamp.
    function _releasable(VestingSchedule memory s, uint64 timestamp) internal pure returns (uint256) {
        uint256 vested = _vestingSchedule(uint256(s.totalAmount), timestamp, s.startTime, s.duration);
        if (vested <= uint256(s.claimed)) return 0;
        return vested - uint256(s.claimed);
    }


    /// @dev Consume matured THOR lock entries up to `maxLocks`.
    function _consumeThorLocks(ThorLock[] storage locks, uint256 cursor, address user, bool is3m, uint256 maxLocks)
        internal
        returns (uint256 unlocked)
    {
        uint256 len = locks.length;
        if (cursor >= len) return 0;

        uint256 processedCount = 0;
        while (cursor < len) {
            ThorLock memory l = locks[cursor];
            if (l.endTime > block.timestamp) break;
            unlocked += uint256(l.amount);
            cursor++;
            processedCount++;
            if (processedCount >= maxLocks) break;
        }

        if (is3m) thorLockCursor3m[user] = cursor;
        else thorLockCursor10m[user] = cursor;
    }

    /// @dev Consume vesting schedules in a round-robin window, capped by `maxVestingSchedules`.
    function _consumeVesting(address user, uint256 maxVestingSchedules) internal returns (uint256 unlocked) {
        VestingSchedule[] storage schedules = _yThorVests[user];
        uint256 len = schedules.length;
        if (len == 0) return 0;

        uint256 max = maxVestingSchedules;
        if (max == 0) max = defaultMaxVestingSchedules;
        if (max == 0 || max > len) max = len;

        uint256 idx = yThorVestCursor[user] % len;
        uint64 ts = uint64(block.timestamp);

        for (uint256 i = 0; i < max; i++) {
            VestingSchedule storage s = schedules[idx];
            uint256 releasable = _releasable(s, ts);
            if (releasable > 0) {
                s.claimed = uint128(uint256(s.claimed) + releasable);
                unlocked += releasable;
            }

            idx = (idx + 1 == len) ? 0 : (idx + 1);
        }

        yThorVestCursor[user] = idx;
    }

    /// @dev Consume contributor vesting schedules in a round-robin window.
    function _consumeContributorVesting(address user, uint256 maxVestingSchedules) internal returns (uint256 unlocked) {
        VestingSchedule[] storage schedules = _contributorVests[user];
        uint256 len = schedules.length;
        if (len == 0) return 0;

        uint256 max = maxVestingSchedules;
        if (max == 0) max = defaultMaxVestingSchedules;
        if (max == 0 || max > len) max = len;

        uint256 idx = contributorVestCursor[user] % len;
        uint64 ts = uint64(block.timestamp);

        for (uint256 i = 0; i < max; i++) {
            VestingSchedule storage s = schedules[idx];
            uint256 releasable = _releasable(s, ts);
            if (releasable > 0) {
                s.claimed = uint128(uint256(s.claimed) + releasable);
                unlocked += releasable;
            }

            idx = (idx + 1 == len) ? 0 : (idx + 1);
        }

        contributorVestCursor[user] = idx;
    }

    /// @dev Compute pending rewards and accumulated value used to update `rewardDebt`.
    function _pendingAndAccumulated(address user) internal view returns (uint256 pending, int256 accumulated) {
        accumulated = int256((totalSharesOf(user) * accRewardPerShare) / ACC_PRECISION);
        int256 debt = rewardDebt[user];
        if (accumulated <= debt) return (0, accumulated);
        pending = uint256(accumulated - debt);
    }

    function _autocompound(address user, uint256 minMetroOut, bytes calldata swapData) internal returns (uint256 metroOut) {
        require(address(swapAdapter) != address(0), "xMETRO: adapter not set");

        int256 accumulated;
        uint256 pending;
        (pending, accumulated) = _pendingAndAccumulated(user);
        require(pending > 0, "xMETRO: no rewards");

        rewardDebt[user] = accumulated;

        uint256 metroBefore = METRO.balanceOf(address(this));
        rewardToken.forceApprove(address(swapAdapter), pending);
        metroOut = swapAdapter.swap(pending, minMetroOut, swapData);
        rewardToken.forceApprove(address(swapAdapter), 0);

        uint256 metroAfter = METRO.balanceOf(address(this));
        uint256 received = metroAfter - metroBefore;
        require(received >= minMetroOut, "xMETRO: slippage");

        _mintFreeShares(user, received);

        emit AutoCompounded(user, pending, received);
        return received;
    }

    /// @dev Debt delta for a shares delta.
    function _debtDelta(uint256 sharesDelta) internal view returns (int256) {
        return int256((sharesDelta * accRewardPerShare) / ACC_PRECISION);
    }

    /// @dev Increase locked shares and update reward debt so new shares do not get past rewards.
    function _increaseLockedShares(address user, uint256 amount) internal {
        lockedShares[user] += amount;
        totalLockedShares += amount;
        rewardDebt[user] += _debtDelta(amount);
    }

    /// @dev Decrease locked shares and update reward debt.
    function _decreaseLockedShares(address user, uint256 amount) internal {
        lockedShares[user] -= amount;
        totalLockedShares -= amount;
        rewardDebt[user] -= _debtDelta(amount);
    }

    /// @dev Mint free shares and update reward debt.
    function _mintFreeShares(address to, uint256 amount) internal {
        rewardDebt[to] += _debtDelta(amount);
        _mint(to, amount);
    }

    /// @dev Burn free shares and update reward debt.
    function _burnFreeShares(address from, uint256 amount) internal {
        rewardDebt[from] -= _debtDelta(amount);
        _burn(from, amount);
    }

    /// @dev Move reward debt when free shares move.
    function _moveFreeSharesDebt(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (from != address(0)) rewardDebt[from] -= _debtDelta(amount);
        if (to != address(0)) rewardDebt[to] += _debtDelta(amount);
    }

    /// @notice Total shares = freeShares(totalSupply) + lockedShares(totalLockedShares).
    function totalShares() public view returns (uint256) {
        return totalSupply() + totalLockedShares;
    }

    /// @notice User total shares = freeShares(balanceOf) + lockedShares.
    function totalSharesOf(address user) public view returns (uint256) {
        return balanceOf(user) + lockedShares[user];
    }

    /// @notice Pending claimable rewards for `user` (view).
    function claimable(address user) external view returns (uint256) {
        (uint256 pending,) = _pendingAndAccumulated(user);
        return pending;
    }

    /// @notice Batch pending claimable rewards (view).
    /// @dev Intended for off-chain callers (e.g., bots) to quote `minMetroOut` for batch autocompound.
    /// @return totalPending Sum of all users' pending rewards.
    /// @return pendings Per-user pending rewards aligned with `users`.
    function claimableMany(address[] calldata users)
        external
        view
        returns (uint256 totalPending, uint256[] memory pendings)
    {
        uint256 len = users.length;
        pendings = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            (uint256 pending,) = _pendingAndAccumulated(users[i]);
            pendings[i] = pending;
            totalPending += pending;
        }
    }

    /// @notice Preview the amount currently unlockable and withdrawable (including THOR/yTHOR/contributor).
    function previewWithdrawableNow(address user)
        external
        view
        returns (uint256 thorUnlockable, uint256 yThorUnlockable, uint256 contributorUnlockable, uint256 totalUnlockable)
    {
        thorUnlockable = _previewThorUnlockable(user);
        yThorUnlockable = _previewVestingUnlockable(user);
        contributorUnlockable = _previewContributorUnlockable(user);
        totalUnlockable = thorUnlockable + yThorUnlockable + contributorUnlockable;
    }

    /// @notice Vesting schedule count.
    function yThorVestingCount(address user) external view returns (uint256) {
        return _yThorVests[user].length;
    }

    /// @notice Vesting schedule by index.
    function yThorVesting(address user, uint256 index) external view returns (VestingSchedule memory) {
        return _yThorVests[user][index];
    }

    /// @notice THOR lock count (3m).
    function thorLocks3mCount(address user) external view returns (uint256) {
        return _thorLocks3m[user].length;
    }

    /// @notice THOR lock count (10m).
    function thorLocks10mCount(address user) external view returns (uint256) {
        return _thorLocks10m[user].length;
    }

    /// @notice THOR lock entry (3m) by index.
    function thorLock3m(address user, uint256 index) external view returns (ThorLock memory) {
        return _thorLocks3m[user][index];
    }

    /// @notice THOR lock entry (10m) by index.
    function thorLock10m(address user, uint256 index) external view returns (ThorLock memory) {
        return _thorLocks10m[user][index];
    }

    /// @notice Unstake request count / entry by index.
    function unstakeRequestCount(address user) external view returns (uint256) {
        return _unstakeRequests[user].length;
    }

    function unstakeRequest(address user, uint256 index) external view returns (UnstakeRequest memory) {
        return _unstakeRequests[user][index];
    }

    /// @notice contributor vesting schedule count.
    function contributorVestingCount(address user) external view returns (uint256) {
        return _contributorVests[user].length;
    }

    /// @notice contributor vesting schedule by index.
    function contributorVesting(address user, uint256 index) external view returns (VestingSchedule memory) {
        return _contributorVests[user][index];
    }
}
