// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IxMETROMigration {
    function creditLockedTHORFromMigration(address user, uint256 amount, uint256 lockMonths) external;
    function creditLockedVestingFromMigration(address user, uint256 amount) external;
}

contract ThorMigrationEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;


    IxMETROMigration public immutable xMETRO;


    IERC20 public immutable thorToken;


    IERC20 public immutable yThorToken;


    uint256 public migrationStartTime;


    uint256 public cap10M;


    uint256 public cap3M;


    uint256 public minted10M;


    uint256 public minted3M;


    uint256 public capYThor;


    uint256 public mintedYThor;


    uint256 public deadline10M;


    uint256 public deadline3M;


    uint256 public deadlineYThor;


    uint256 public ratio10M;


    uint256 public ratio3M;


    uint256 public ratioYThor;

    event MigratedThor(
        address indexed user,
        uint256 amountIn,
        uint256 mintAmount,
        uint256 lockMonths
    );

    event MigratedYThor(address indexed user, uint256 amountIn, uint256 mintAmount);

    event DeadlinesUpdated(uint256 deadline10M, uint256 deadline3M);
    event RatiosUpdated(uint256 ratio10M, uint256 ratio3M, uint256 ratioYThor);
    event CapsUpdated(uint256 cap10M, uint256 cap3M);
    event MigrationStartTimeUpdated(uint256 migrationStartTime);
    event YThorLimitsUpdated(uint256 capYThor, uint256 deadlineYThor);

    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address owner_,
        address xMETRO_,
        address thor_,
        address yThor_,
        uint256 migrationStartTime_
    ) Ownable(owner_) {
        require(xMETRO_ != address(0), "ThorEscrow: zero xMETRO");
        require(thor_ != address(0) && yThor_ != address(0), "ThorEscrow: zero token");
        require(migrationStartTime_ >= block.timestamp, "ThorEscrow: bad start time");
        xMETRO = IxMETROMigration(xMETRO_);
        thorToken = IERC20(thor_);
        yThorToken = IERC20(yThor_);
        migrationStartTime = migrationStartTime_;
    }

    /**
     * @notice Migrate THOR using the 10-month bucket.
     * @dev Reverts if the 10m bucket is not available (expired or cap exceeded).
     */
    function migrateThor10m(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, "ThorEscrow: not started");
        require(amountIn > 0, "ThorEscrow: zero amount");

        require(cap10M != 0 && cap3M != 0, "ThorEscrow: caps not set");
        require(block.timestamp <= deadline10M, "ThorEscrow: 10m expired");

        uint256 mintAmount = (amountIn * ratio10M) / 1e18;
        require(mintAmount > 0, "ThorEscrow: zero mint");
        require(minted10M + mintAmount <= cap10M, "ThorEscrow: 10m cap");

        minted10M += mintAmount;

        thorToken.safeTransferFrom(msg.sender, address(this), amountIn);

        xMETRO.creditLockedTHORFromMigration(msg.sender, mintAmount, 10);

        emit MigratedThor(msg.sender, amountIn, mintAmount, 10);
    }

    /**
     * @notice Migrate THOR using the 3-month bucket.
     * @dev Only allowed when the 10m bucket is not available for this `amountIn` (expired or cap exceeded).
     */
    function migrateThor3m(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, "ThorEscrow: not started");
        require(amountIn > 0, "ThorEscrow: zero amount");

        require(cap10M != 0 && cap3M != 0, "ThorEscrow: caps not set");

        uint256 potentialMint10 = (amountIn * ratio10M) / 1e18;
        bool tenAvailable = (block.timestamp <= deadline10M) && (minted10M + potentialMint10 <= cap10M);
        require(!tenAvailable, "ThorEscrow: 10m available");

        require(block.timestamp <= deadline3M, "ThorEscrow: 3m expired");

        uint256 mintAmount = (amountIn * ratio3M) / 1e18;
        require(mintAmount > 0, "ThorEscrow: zero mint");
        require(minted3M + mintAmount <= cap3M, "ThorEscrow: 3m cap");

        minted3M += mintAmount;

        thorToken.safeTransferFrom(msg.sender, address(this), amountIn);

        xMETRO.creditLockedTHORFromMigration(msg.sender, mintAmount, 3);

        emit MigratedThor(msg.sender, amountIn, mintAmount, 3);
    }

    /**
     * @notice Migrate yTHOR (credits a vesting schedule in xMETRO).
     */
    function migrateYThor(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, "ThorEscrow: not started");
        require(amountIn > 0, "ThorEscrow: zero amount");

        require(capYThor != 0, "ThorEscrow: ythor cap not set");
        require(block.timestamp <= deadlineYThor, "ThorEscrow: ythor expired");

        uint256 mintAmount = (amountIn * ratioYThor) / 1e18;
        require(mintAmount > 0, "ThorEscrow: zero mint");

        require(mintedYThor + mintAmount <= capYThor, "ThorEscrow: ythor cap");
        mintedYThor += mintAmount;

        yThorToken.safeTransferFrom(msg.sender, address(this), amountIn);

        xMETRO.creditLockedVestingFromMigration(msg.sender, mintAmount);

        emit MigratedYThor(msg.sender, amountIn, mintAmount);
    }

    /// @notice Set migration start time (onlyOwner).
    function setMigrationStartTime(uint256 newStartTime) external onlyOwner {
        require(newStartTime >= block.timestamp, "ThorEscrow: bad start time");
        migrationStartTime = newStartTime;
        emit MigrationStartTimeUpdated(newStartTime);
    }

    /// @notice Set THOR bucket deadlines (onlyOwner).
    function setDeadlines(uint256 newDeadline10M, uint256 newDeadline3M) external onlyOwner {
        require(newDeadline10M >= block.timestamp && newDeadline3M >= block.timestamp, "ThorEscrow: bad deadline");
        deadline10M = newDeadline10M;
        deadline3M = newDeadline3M;
        emit DeadlinesUpdated(newDeadline10M, newDeadline3M);
    }

    /// @notice Set ratios (onlyOwner, 1e18 scaled).
    function setRatios(uint256 newRatio10M, uint256 newRatio3M, uint256 newRatioYThor) external onlyOwner {
        require(newRatio10M > 0 && newRatio3M > 0 && newRatioYThor > 0, "ThorEscrow: bad ratio");
        ratio10M = newRatio10M;
        ratio3M = newRatio3M;
        ratioYThor = newRatioYThor;
        emit RatiosUpdated(newRatio10M, newRatio3M, newRatioYThor);
    }

    /// @notice Set mint caps (onlyOwner, denominated in minted METRO).
    function setCaps(uint256 newCap10M, uint256 newCap3M) external onlyOwner {
        require(newCap10M > 0 && newCap3M > 0, "ThorEscrow: bad cap");
        cap10M = newCap10M;
        cap3M = newCap3M;
        emit CapsUpdated(newCap10M, newCap3M);
    }

    /// @notice Set yTHOR mint cap + deadline (onlyOwner; cap denominated in minted METRO).
    function setYThorLimits(uint256 newCapYThor, uint256 newDeadlineYThor) external onlyOwner {
        require(newCapYThor > 0, "ThorEscrow: bad cap");
        require(newDeadlineYThor >= block.timestamp, "ThorEscrow: bad deadline");
        capYThor = newCapYThor;
        deadlineYThor = newDeadlineYThor;
        emit YThorLimitsUpdated(newCapYThor, newDeadlineYThor);
    }

    /// @notice Pause/unpause (onlyOwner).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Rescue tokens sent to this contract by mistake (onlyOwner).
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(thorToken) && token != address(yThorToken), "ThorEscrow: cannot rescue migration tokens");
        require(to != address(0), "ThorEscrow: bad to");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

}
