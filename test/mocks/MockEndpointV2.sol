// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title MockEndpointV2
 * @notice Minimal endpoint mock for fork tests.
 * @dev Only implements `setDelegate` required by OAppCore constructor flow.
 */
contract MockEndpointV2 {
    address public delegate;

    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }
}
