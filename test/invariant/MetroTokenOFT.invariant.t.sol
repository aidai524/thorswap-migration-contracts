// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import { MetroTokenOFT } from "../../src/metro.sol";
import { MockEndpointV2 } from "../mocks/MockEndpointV2.sol";

contract MetroTokenOFTInvariantTest is StdInvariant, Test {
    MetroTokenOFT internal metro;
    MetroTokenOFTHandler internal handler;

    function setUp() public {
        MockEndpointV2 endpoint = new MockEndpointV2();
        metro = new MetroTokenOFT("METRO", "METRO", address(endpoint), address(this));

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        actors[3] = makeAddr("actor3");

        handler = new MetroTokenOFTHandler(metro, actors);
        metro.transferOwnership(address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.setMinter.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.transferTokens.selector;
        selectors[3] = handler.transferFromTokens.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_TotalSupplyEqualsSumOfActors() public view {
        uint256 total;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            total += metro.balanceOf(handler.actorAt(i));
        }
        assertEq(metro.totalSupply(), total);
    }
}

contract MetroTokenOFTHandler is Test {
    MetroTokenOFT internal metro;
    address[] internal actors;

    mapping(address => bool) internal isMinter;

    constructor(MetroTokenOFT metro_, address[] memory actors_) {
        metro = metro_;
        actors = actors_;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function setMinter(uint8 minterIndex, bool allowed) external {
        address minter = actors[uint256(minterIndex) % actors.length];
        metro.setMinter(minter, allowed);
        isMinter[minter] = allowed;
    }

    function mint(uint8 minterIndex, uint8 toIndex, uint256 amount) external {
        amount = bound(amount, 0, 1e24);

        address minter = actors[uint256(minterIndex) % actors.length];
        if (!isMinter[minter]) return;

        address to = actors[uint256(toIndex) % actors.length];

        vm.prank(minter);
        metro.mint(to, amount);
    }

    function transferTokens(uint8 fromIndex, uint8 toIndex, uint256 amount) external {
        address from = actors[uint256(fromIndex) % actors.length];
        address to = actors[uint256(toIndex) % actors.length];
        if (from == to) return;

        uint256 bal = metro.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);

        vm.prank(from);
        metro.transfer(to, amount);
    }

    function transferFromTokens(uint8 ownerIndex, uint8 spenderIndex, uint8 toIndex, uint256 amount) external {
        address tokenOwner = actors[uint256(ownerIndex) % actors.length];
        address spender = actors[uint256(spenderIndex) % actors.length];
        address to = actors[uint256(toIndex) % actors.length];

        uint256 bal = metro.balanceOf(tokenOwner);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);

        vm.prank(tokenOwner);
        metro.approve(spender, amount);

        vm.prank(spender);
        metro.transferFrom(tokenOwner, to, amount);
    }
}
