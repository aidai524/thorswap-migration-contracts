// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


interface IxMETRO {
    function depositRewards(uint256 amount) external;
    function rewardToken() external view returns (IERC20);
}

contract RewardDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;


    IxMETRO public immutable xMETRO;

 
    IERC20 public immutable rewardToken;

    /// @notice Operators are allowed to call `distribute` / `distributeFromBalance`.
    mapping(address => bool) public operators;


    event RewardsDistributed(address indexed caller, uint256 amount, uint64 timestamp);

  
    event OperatorUpdated(address indexed operator, bool allowed);


    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(address xMetro_, address rewardToken_, address owner_) Ownable(owner_) {
        require(xMetro_ != address(0), "RewardDistributor: zero xMETRO");
        require(rewardToken_ != address(0), "RewardDistributor: zero rewardToken");
        xMETRO = IxMETRO(xMetro_);
        rewardToken = IERC20(rewardToken_);
    }

    /// @dev Only operators can call.
    modifier onlyOperator() {
        require(operators[msg.sender], "RewardDistributor: only operator");
        _;
    }

    /**
     * @notice Set/unset an operator (onlyOwner).
     */
    function setOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "RewardDistributor: bad operator");
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    /**
     * @notice Distribute rewards by pulling tokens from the caller.
     */
    function distribute(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, "RewardDistributor: zero amount");

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        rewardToken.forceApprove(address(xMETRO), amount);

        xMETRO.depositRewards(amount);

        rewardToken.forceApprove(address(xMETRO), 0);

        emit RewardsDistributed(msg.sender, amount, uint64(block.timestamp));
    }

    /**
     * @notice Distribute rewards using this contract's current balance.
     */
    function distributeFromBalance(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, "RewardDistributor: zero amount");
        require(rewardToken.balanceOf(address(this)) >= amount, "RewardDistributor: insufficient balance");

        rewardToken.forceApprove(address(xMETRO), amount);

        xMETRO.depositRewards(amount);

        rewardToken.forceApprove(address(xMETRO), 0);

        emit RewardsDistributed(msg.sender, amount, uint64(block.timestamp));
    }

    /**
     * @notice Rescue tokens sent to this contract by mistake (onlyOwner).
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "RewardDistributor: bad to");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }
}
