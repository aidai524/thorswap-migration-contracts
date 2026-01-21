// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title Deploy.s.sol
 * @notice Single-chain deployment script for Ethereum migration (no cross-chain messaging).
 * @dev Deploys MetroTokenOFT + xMETRO + optional SwapAdapter/RewardDistributor, then ThorMigrationEscrow and wires it
 *      as `xMETRO.migrationEscrow`.
 */

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console2.sol";

import { MetroTokenOFT } from "../src/metro.sol";
import { xMETRO } from "../src/xMETRO.sol";
import { SwapAdapter } from "../src/SwapAdapter.sol";
import { RewardDistributor } from "../src/RewardDistributor.sol";
import { ThorMigrationEscrow } from "../src/ThorMigrationEscrow.sol";

contract Deploy is Script {
    using stdJson for string;

    struct Addresses {
        address metroOFT;
        address xMETRO;
        address swapAdapter;
        address rewardDistributor;
        address escrow;
        address owner;
    }

    function run() external {
        address owner = vm.envAddress("OWNER");
        require(owner != address(0), "Deploy: OWNER=0");

        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address deployer = deployerPk != 0 ? vm.addr(deployerPk) : owner;

        // Core constructor params
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address usdc = vm.envAddress("USDC");
        string memory metroName = vm.envString("METRO_NAME");
        string memory metroSymbol = vm.envString("METRO_SYMBOL");

        // Autocompound infra (SwapAdapter + RewardDistributor).
        address routerV2 = vm.envOr("ROUTER_V2", address(0));
        address routerV3 = vm.envOr("ROUTER_V3", address(0));
        address distributorOperator = vm.envOr("REWARD_DISTRIBUTOR_OPERATOR", address(0));
        address autoCompoundOperator = vm.envOr("AUTO_COMPOUND_OPERATOR", address(0));
        // Comma/whitespace-separated list of contributor addresses.
        string memory contributors = vm.envOr("CONTRIBUTORS", string(""));

        // Migration escrow constructor params
        address thor = vm.envAddress("THOR");
        address yThor = vm.envAddress("YTHOR");
        uint256 migrationStartTime = vm.envUint("MIGRATION_START_TIME");

        // Migration business params
        uint256 cap10M = vm.envUint("CAP_10M");
        uint256 cap3M = vm.envUint("CAP_3M");
        uint256 capYThor = vm.envUint("CAP_YTHOR");
        uint256 ratio10M = vm.envUint("RATIO_10M");
        uint256 ratio3M = vm.envUint("RATIO_3M");
        uint256 ratioYThor = vm.envUint("RATIO_YTHOR");
        uint256 deadline10M = vm.envUint("DEADLINE_10M");
        uint256 deadline3M = vm.envUint("DEADLINE_3M");
        uint256 deadlineYThor = vm.envUint("DEADLINE_YTHOR");

        Addresses memory a;

        if (deployerPk != 0) vm.startBroadcast(deployerPk);
        else vm.startBroadcast();

        MetroTokenOFT metro = new MetroTokenOFT(metroName, metroSymbol, lzEndpoint, deployer);

        xMETRO xmetro = new xMETRO(deployer, address(metro), usdc, address(0));
        metro.setMinter(address(xmetro), true);

        address swapAdapter = address(0);
        address rewardDistributor = address(0);

        if (routerV2 != address(0) && routerV3 != address(0)) {
            SwapAdapter adapter = new SwapAdapter(usdc, address(metro), address(xmetro), routerV2, routerV3, deployer);
            xmetro.setSwapAdapter(address(adapter));
            swapAdapter = address(adapter);

            RewardDistributor distributor = new RewardDistributor(address(xmetro), usdc, deployer);
            if (distributorOperator != address(0)) {
                distributor.setOperator(distributorOperator, true);
            }
            xmetro.setRewardDistributor(address(distributor));
            rewardDistributor = address(distributor);
        }

        if (autoCompoundOperator != address(0)) {
            xmetro.setAutoCompoundOperator(autoCompoundOperator, true);
        }

        if (bytes(contributors).length != 0) {
            address[] memory list = _parseAddressList(contributors);
            for (uint256 i = 0; i < list.length; i++) {
                xmetro.setContributor(list[i], true);
            }
        }

        ThorMigrationEscrow escrow = new ThorMigrationEscrow(deployer, address(xmetro), thor, yThor, migrationStartTime);
        escrow.setCaps(cap10M, cap3M);
        escrow.setRatios(ratio10M, ratio3M, ratioYThor);
        escrow.setDeadlines(deadline10M, deadline3M);
        escrow.setYThorLimits(capYThor, deadlineYThor);
        xmetro.setMigrationEscrow(address(escrow));

        // Final ownership transfer
        metro.setDelegate(owner);
        metro.setMinter(owner, true);
        metro.transferOwnership(owner);
        xmetro.transferOwnership(owner);
        if (swapAdapter != address(0)) SwapAdapter(swapAdapter).transferOwnership(owner);
        if (rewardDistributor != address(0)) RewardDistributor(rewardDistributor).transferOwnership(owner);
        escrow.transferOwnership(owner);

        vm.stopBroadcast();

        a.metroOFT = address(metro);
        a.xMETRO = address(xmetro);
        a.swapAdapter = swapAdapter;
        a.rewardDistributor = rewardDistributor;
        a.escrow = address(escrow);
        a.owner = owner;

        _writeAddresses(_addressesPath(), a);

        console2.log("=== Deployed Contracts ===");
        console2.log("MetroTokenOFT:", a.metroOFT);
        console2.log("xMETRO:", a.xMETRO);
        console2.log("SwapAdapter:", a.swapAdapter);
        console2.log("RewardDistributor:", a.rewardDistributor);
        console2.log("ThorMigrationEscrow:", a.escrow);
        console2.log("Owner:", a.owner);
    }

    function _parseAddressList(string memory list) internal returns (address[] memory addrs) {
        bytes memory b = bytes(list);

        uint256 count = 0;
        bool inToken = false;
        for (uint256 i = 0; i < b.length; i++) {
            if (_isDelimiter(b[i])) {
                if (inToken) {
                    count++;
                    inToken = false;
                }
            } else if (!inToken) {
                inToken = true;
            }
        }
        if (inToken) count++;

        addrs = new address[](count);
        uint256 idx = 0;
        uint256 start = 0;
        inToken = false;

        for (uint256 i = 0; i <= b.length; i++) {
            bool end = (i == b.length);
            if (end || _isDelimiter(b[i])) {
                if (inToken) {
                    addrs[idx++] = vm.parseAddress(_substring(b, start, i));
                    inToken = false;
                }
            } else if (!inToken) {
                inToken = true;
                start = i;
            }
        }

        require(idx == count, "Deploy: bad CONTRIBUTORS");
    }

    function _isDelimiter(bytes1 c) internal pure returns (bool) {
        return c == bytes1(",") || c == bytes1(" ") || c == bytes1("\n") || c == bytes1("\r") || c == bytes1("\t");
    }

    function _substring(bytes memory strBytes, uint256 start, uint256 end) internal pure returns (string memory) {
        require(end >= start, "Deploy: bad slice");
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            out[i] = strBytes[start + i];
        }
        return string(out);
    }

    function _addressesPath() internal pure returns (string memory) {
        return "deployments/addresses.json";
    }

    function _writeAddresses(string memory path, Addresses memory a) internal {
        vm.createDir("deployments", true);

        string memory obj = "addresses";
        string memory json;

        json = vm.serializeAddress(obj, "metroOFT", a.metroOFT);
        json = vm.serializeAddress(obj, "xMETRO", a.xMETRO);
        json = vm.serializeAddress(obj, "swapAdapter", a.swapAdapter);
        json = vm.serializeAddress(obj, "rewardDistributor", a.rewardDistributor);
        json = vm.serializeAddress(obj, "escrow", a.escrow);
        json = vm.serializeAddress(obj, "owner", a.owner);

        vm.writeJson(json, path);
        console2.log("Addresses written to:", path);
    }
}
