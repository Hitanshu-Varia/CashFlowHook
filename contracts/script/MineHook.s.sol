// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PortfolioMarginHook} from "../src/PortfolioMarginHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Mines a CREATE2 salt whose hook address encodes exactly the two permission flags used.
contract MineHook is Script {
    uint160 internal constant REQUIRED_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant ALL_FLAGS_MASK = (1 << 14) - 1;

    function run() external returns (bytes32 salt, address predicted) {
        address deployer = vm.envOr("HOOK_DEPLOYER", msg.sender);
        address engine = vm.envAddress("ENGINE_ADDR");
        address poolManager = vm.envAddress("POOL_MANAGER_BASE");
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(PortfolioMarginHook).creationCode,
                abi.encode(IPoolManager(poolManager), engine)
            )
        );

        for (uint256 i = 0; i < 1_000_000; i++) {
            salt = bytes32(i);
            predicted = vm.computeCreate2Address(salt, initCodeHash, deployer);
            if ((uint160(predicted) & ALL_FLAGS_MASK) == REQUIRED_FLAGS) {
                console2.log("salt", vm.toString(salt));
                console2.log("predicted hook", predicted);
                vm.createDir("../deploy", true);
                string memory obj = "hook";
                vm.serializeBytes32(obj, "salt", salt);
                string memory json = vm.serializeAddress(obj, "predicted", predicted);
                vm.writeJson(json, "../deploy/hook-salt.json");
                return (salt, predicted);
            }
        }
        revert("no salt found");
    }
}
